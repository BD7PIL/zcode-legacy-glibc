#!/usr/bin/env bash
#
# apply.sh - install glibc-2.17 compatible binaries into the ZCode remote runtime.
#
# The ZCode desktop decides whether to (re)deploy a component by comparing the version string
# stored in a marker file (".asset-components/<id>.json" or "tools/<tool>/.version") with the
# version it expects from its asset manifest. It does not hash the binaries for the components
# this kit replaces. Therefore:
#
#   * we back up and overwrite the binaries,
#   * we never write the marker files,
#   * a bundle is only applied when its versions match the markers the desktop recorded.
#
set -euo pipefail

RUNTIME_ROOT="${ZCODE_RUNTIME_ROOT:-$HOME/.zcode/server}"
STATE_DIR="${ZCL_STATE_DIR:-$HOME/.zcode/legacy-glibc}"
CACHE_DIR="$STATE_DIR/cache"
BACKUP_SUFFIX=".official-glibc228.bak"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BUNDLE=""
CHECK_ONLY=0
RUN_VERIFY=1
FORCE=0

log()  { echo "  [INFO]  $*"; }
warn() { echo "  [WARN]  $*"; }
err()  { echo "  [ERROR] $*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: apply.sh [options]

  --bundle PATH   Bundle tarball (or an unpacked bundle directory) to apply.
  --cache         Use the newest bundle in ~/.zcode/legacy-glibc/cache (default).
  --check         Report what would change, install nothing.
  --no-verify     Skip verify.sh after installing.
  --force         Apply even if versions do not match the markers.
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

[ -d "$RUNTIME_ROOT" ] || die "ZCode runtime not found: $RUNTIME_ROOT (connect once from the desktop, or set ZCODE_RUNTIME_ROOT)"

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
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$BUNDLE_ROOT/manifest.json" | head -n1
}

# --------------------------------------------------------------------------- expectations
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

# --------------------------------------------------------------------------- plan
declare -a PLAN_ID=() PLAN_SRC=() PLAN_DST=() PLAN_VER=()
MISMATCH=0

while IFS= read -r comp; do
  [ -n "$comp" ] || continue
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

# --------------------------------------------------------------------------- markers untouched?
for id in node-runtime node-pty bfs ripgrep ugrep; do
  marker="$(expect_marker "$id")"
  [ -f "$marker" ] || continue
  log "marker kept: $marker = $(expected_version "$id")"
done

# --------------------------------------------------------------------------- state + verify
mkdir -p "$STATE_DIR"
{
  echo "ZCL_APPLIED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "ZCL_BUNDLE=$BUNDLE"
  echo "ZCL_ZCODE_VERSION=$(manifest_top zcodeVersion)"
  echo "ZCL_NODE_VERSION=$(manifest_field node-runtime version)"
  echo "ZCL_NODE_PTY_VERSION=$(manifest_field node-pty version)"
  echo "ZCL_BFS_VERSION=$(manifest_field bfs version)"
  echo "ZCL_UGREP_VERSION=$(manifest_field ugrep version)"
} > "$STATE_DIR/state.env"
log "state written: $STATE_DIR/state.env"

if [ "$RUN_VERIFY" -eq 1 ]; then
  log "running verify.sh"
  bash "$SCRIPT_DIR/verify.sh"
fi
