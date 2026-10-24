#!/usr/bin/env bash
#
# apply.sh - install glibc-2.17 compatible binaries into the ZCode remote runtime.
#
# Two runtime layouts are supported:
#
#   new  "source server" (desktop >= 3.16): the desktop installs versioned releases under
#        $ROOT/releases/<releaseId>/ and dispatches via $ROOT/bin/zcode -> current.json.
#        The desktop verifies component sha256 only while it installs its own archive;
#        afterwards it only reads current.json (version/archiveSha256) and run/status.json.
#        So: install the official tree once, then swap binaries inside the release dir.
#
#   old  "component assets" (desktop <= 3.15): the desktop decides what to (re)deploy by
#        comparing version strings in $ROOT/.asset-components/*.json and tools/*/.version
#        markers - it never hashes these components. So: back up and overwrite the binaries,
#        and never write the marker files.
#
# In both layouts a bundle is only applied when its versions match what the installed tree
# declares; --force overrides. When no tree exists at all (fresh legacy host), apply.sh
# bootstraps the official source-server tree from the release CDN first (see
# bootstrap-source-server.sh) and then applies the bundle.
#
set -euo pipefail

RUNTIME_ROOT="${ZCODE_RUNTIME_ROOT:-$HOME/.zcode/server}"
STATE_DIR="${ZCL_STATE_DIR:-$HOME/.zcode/legacy-glibc}"
CACHE_DIR="$STATE_DIR/cache"
BACKUP_SUFFIX=".official-glibc228.bak"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=layout.sh
. "$SCRIPT_DIR/layout.sh"

BUNDLE=""
CHECK_ONLY=0
RUN_VERIFY=1
FORCE=0

log()  { echo "  [INFO]  $*"; }
warn() { echo "  [WARN]  $*"; }
err()  { echo "  [ERROR] $*" >&2; }
die()  { err "$*"; exit 1; }

# strip leading v and trailing kit build suffix: "v4.1.1-2" -> "4.1.1"
upstream_ver() { sed -e 's/^v//' -e 's/-[0-9]*$//' <<<"$1"; }

usage() {
  cat <<'EOF'
Usage: apply.sh [options]

  --bundle PATH   Bundle tarball (or an unpacked bundle directory) to apply.
  --cache         Use the newest bundle in ~/.zcode/legacy-glibc/cache (default).
  --check         Report what would change, install nothing.
  --no-verify     Skip verify.sh after installing.
  --force         Apply even if versions do not match the installed tree.
  -h, --help      Show this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bundle)    BUNDLE="${2:-}"; [ -n "$BUNDLE" ] || die "--bundle needs a path"; shift 2 ;;
    --cache)     BUNDLE=""; shift ;;
    --check)     CHECK_ONLY=1; shift ;;
    --no-verify) RUN_VERIFY=0; shift ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "unknown argument: $1" ;;
  esac
done

# --------------------------------------------------------------------------- bundle resolution
if [ -z "$BUNDLE" ]; then
  if [ -d "$CACHE_DIR" ]; then
    BUNDLE="$(find "$CACHE_DIR" -maxdepth 1 -name 'zcode-legacy-glibc-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)"
  fi
  [ -n "${BUNDLE:-}" ] || die "no bundle in $CACHE_DIR - pass --bundle PATH or copy a release tarball there"
fi
[ -e "$BUNDLE" ] || die "bundle not found: $BUNDLE"
log "bundle: $BUNDLE"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

case "$BUNDLE" in
  *.tar.gz|*.tgz) tar xzf "$BUNDLE" -C "$TMP_DIR"; BUNDLE_ROOT="$TMP_DIR" ;;
  *)              BUNDLE_ROOT="$BUNDLE" ;;
esac
[ -f "$BUNDLE_ROOT/manifest.json" ] || die "manifest.json missing in bundle"

# --------------------------------------------------------------------------- manifest parsing
# The bundle manifest keeps one component per line, so plain sed is enough (no python/jq needed):
#   {"id": "node-pty", "version": "v1.2.0-beta.10", "path": "pty.node", "target": "build/Release/pty.node"}
manifest_components() {
  sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$BUNDLE_ROOT/manifest.json"
}
manifest_field() {  # id field
  local id="$1" field="$2"
  sed -n '/"id"[[:space:]]*:[[:space:]]*"'"$id"'"/p' "$BUNDLE_ROOT/manifest.json" \
    | sed -n 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}
manifest_top() {  # field of the top-level object
  json_field "$BUNDLE_ROOT/manifest.json" "$1"
}

BUNDLE_ZCODE="$(manifest_top zcodeVersion)"
[ -n "$BUNDLE_ZCODE" ] || die "bundle manifest has no zcodeVersion"
BUNDLE_NODE="$(manifest_field node-runtime version)"
[ -n "$BUNDLE_NODE" ] || die "bundle manifest has no node-runtime entry"
BUNDLE_NODE_SRC="$BUNDLE_ROOT/node"
[ -f "$BUNDLE_NODE_SRC" ] || die "bundle is missing the node binary"

# --------------------------------------------------------------------------- fresh host?
LAYOUT="$(runtime_layout "$RUNTIME_ROOT")"

if [ "$LAYOUT" = "none" ]; then
  if [ "$CHECK_ONLY" -eq 1 ]; then
    log "check mode: no runtime at $RUNTIME_ROOT; bootstrap would install ZCode Server $BUNDLE_ZCODE from the release CDN"
    exit 0
  fi
  log "no runtime found at $RUNTIME_ROOT - bootstrapping official source-server $BUNDLE_ZCODE from the CDN"
  bash "$SCRIPT_DIR/bootstrap-source-server.sh" \
    --zcode-version "$BUNDLE_ZCODE" --node "$BUNDLE_NODE_SRC"
  LAYOUT="$(runtime_layout "$RUNTIME_ROOT")"
  [ "$LAYOUT" = "new" ] || die "bootstrap did not produce a source-server tree at $RUNTIME_ROOT"
fi

# --------------------------------------------------------------------------- expectations
declare -a PLAN_ID=() PLAN_SRC=() PLAN_DST=() PLAN_VER=()
MISMATCH=0

gate() {  # component installed_version bundle_version [why]
  local id="$1" installed="$2" bundled="$3" why="${4:-}"
  if [ -n "$installed" ] && [ "$installed" != "$bundled" ]; then
    err "$id: tree has $installed, bundle provides $bundled ${why}"
    MISMATCH=1
  fi
}

if [ "$LAYOUT" = "new" ]; then
  # ------------------------------------------------------------- new layout (source server)
  RD="$(release_dir "$RUNTIME_ROOT")"
  [ -n "$RD" ] || die "current.json has no releaseDir"
  log "layout: source-server ($RD)"

  TREE_VERSION="$(json_field "$RUNTIME_ROOT/current.json" version)"
  TREE_NODE="$(json_field "$RUNTIME_ROOT/current.json" nodeVersion)"
  TREE_PTY="$(json_field "$RD/runtime/node_modules/node-pty/package.json" version 2>/dev/null || true)"
  TREE_KOFFI="$(json_field "$RD/runtime/node_modules/koffi/package.json" version 2>/dev/null || true)"

  gate "zcode-server" "$TREE_VERSION" "$BUNDLE_ZCODE" "(the desktop reinstalled a different release - rebuild the bundle for it)"
  gate "node-runtime" "${TREE_NODE#v}" "${BUNDLE_NODE#v}" "(rebuild with the node version current.json declares)"
  gate "node-pty"     "$(upstream_ver "$TREE_PTY")" "$(upstream_ver "$(manifest_field node-pty version)")" "(ABI risk - rebuild node-pty for this version, or pass --force)"

  # per-tool versions live in SOURCES.json keyed by toolId (the file lists all three tools)
  for comp in bfs ugrep; do
    tree_v="$(tool_version "$RD/runtime/tools/$comp/SOURCES.json" "$comp")"
    bundle_v="$(upstream_ver "$(manifest_field "$comp" version)")"
    gate "$comp" "$tree_v" "$bundle_v" "(rebuild $comp $tree_v, or pass --force)"
  done

  # plan: everything the bundle ships and this layout knows a target for
  while IFS= read -r comp; do
    [ -n "$comp" ] || continue
    src_rel="$(manifest_field "$comp" path)"
    ver="$(manifest_field "$comp" version)"
    src="$BUNDLE_ROOT/$src_rel"
    dst="$(component_path "$RUNTIME_ROOT" new "$comp")"
    if [ -z "$dst" ]; then
      log "skipping $comp: no target in this layout"
      continue
    fi
    if [ "$comp" = "koffi" ] && [ ! -d "$RD/runtime/node_modules/koffi" ]; then
      log "skipping $comp: koffi module not present in this runtime"
      continue
    fi
    if [ "$comp" = "koffi" ] && [ ! -f "$src" ]; then
      warn "bundle has no koffi.node - official koffi needs glibc 2.28, TUI-dependent features may degrade on this host"
      continue
    fi
    [ -f "$src" ] || { warn "bundle is missing $src_rel, skipping $comp"; continue; }
    PLAN_ID+=("$comp"); PLAN_SRC+=("$src"); PLAN_DST+=("$dst"); PLAN_VER+=("$ver")
  done < <(manifest_components)

else
  # ------------------------------------------------------------- old layout (component assets)
  log "layout: component assets"
  expect_marker() {  # id -> marker path
    case "$1" in
      node-runtime) echo "$RUNTIME_ROOT/.asset-components/node-runtime.json" ;;
      node-pty)     echo "$RUNTIME_ROOT/.asset-components/node-pty.json" ;;
      bfs)          echo "$RUNTIME_ROOT/tools/bfs/.version" ;;
      ripgrep)      echo "$RUNTIME_ROOT/tools/ripgrep/.version" ;;
      ugrep)        echo "$RUNTIME_ROOT/tools/ugrep/.version" ;;
      *)            echo "" ;;
    esac
  }
  expected_version() {  # id -> version the desktop expects on this host
    local marker; marker="$(expect_marker "$1")"
    [ -f "$marker" ] || { echo ""; return; }
    case "$1" in
      bfs|ripgrep|ugrep) tr -d ' \t\r\n' < "$marker" ;;
      *) sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$marker" | head -n1 ;;
    esac
  }

  while IFS= read -r comp; do
    [ -n "$comp" ] || continue
    [ "$comp" = "koffi" ] && { log "skipping koffi: not part of the component-assets layout"; continue; }
    src_rel="$(manifest_field "$comp" path)"
    dst_rel="$(manifest_field "$comp" target)"
    ver="$(manifest_field "$comp" version)"
    [ -n "$src_rel" ] && [ -n "$dst_rel" ] || { warn "manifest entry incomplete for $comp, skipping"; continue; }
    src="$BUNDLE_ROOT/$src_rel"; dst="$RUNTIME_ROOT/$dst_rel"
    [ -f "$src" ] || { warn "bundle is missing $src_rel, skipping $comp"; continue; }

    expected="$(expected_version "$comp")"
    if [ -n "$expected" ] && [ "$expected" != "$ver" ]; then
      err "$comp: desktop expects $expected, bundle provides $ver"
      MISMATCH=1
    fi
    PLAN_ID+=("$comp"); PLAN_SRC+=("$src"); PLAN_DST+=("$dst"); PLAN_VER+=("$ver")
  done < <(manifest_components)
fi

[ "${#PLAN_SRC[@]}" -gt 0 ] || die "nothing to apply in this bundle"
if [ "$MISMATCH" -eq 1 ] && [ "$FORCE" -eq 0 ]; then
  die "version mismatch (see above) - run the 'Build legacy runtime bundle' action for these versions, or pass --force"
fi

# --------------------------------------------------------------------------- apply
for i in "${!PLAN_SRC[@]}"; do
  id="${PLAN_ID[$i]}"; src="${PLAN_SRC[$i]}"; dst="${PLAN_DST[$i]}"; ver="${PLAN_VER[$i]}"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    log "would install $id ($ver) -> $dst"
    continue
  fi
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ] && [ ! -f "$dst$BACKUP_SUFFIX" ]; then
    cp -p "$dst" "$dst$BACKUP_SUFFIX"
    log "backed up $dst$BACKUP_SUFFIX"
  fi
  install -m 0755 "$src" "$dst"
  log "installed $id ($ver) -> $dst"
done

if [ "$CHECK_ONLY" -eq 1 ]; then
  log "check mode: nothing was modified"
  exit 0
fi

# --------------------------------------------------------------------------- state + verify
mkdir -p "$STATE_DIR"
{
  echo "ZCL_APPLIED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "ZCL_BUNDLE=$BUNDLE"
  echo "ZCL_LAYOUT=$LAYOUT"
  echo "ZCL_ZCODE_VERSION=$BUNDLE_ZCODE"
  echo "ZCL_NODE_VERSION=$BUNDLE_NODE"
  echo "ZCL_NODE_PTY_VERSION=$(manifest_field node-pty version)"
  echo "ZCL_KOFFI_VERSION=$(manifest_field koffi version)"
  echo "ZCL_BFS_VERSION=$(manifest_field bfs version)"
  echo "ZCL_UGREP_VERSION=$(manifest_field ugrep version)"
} > "$STATE_DIR/state.env"
log "state written: $STATE_DIR/state.env"

if [ "$RUN_VERIFY" -eq 1 ]; then
  log "running verify.sh"
  bash "$SCRIPT_DIR/verify.sh"
fi
