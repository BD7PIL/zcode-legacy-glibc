#!/usr/bin/env bash
#
# bootstrap-source-server.sh - install the official ZCode source-server tree on a host that
# cannot run it, by driving the desktop's own updater under a glibc-2.17 node.
#
# The desktop's bootstrap (upload -> extract -> `$EXTRACT/bin/zcode update --from-archive ...`)
# dies on EL7 because the bundled node requires glibc 2.28. The `update` step itself is pure JS,
# so the recipe is: extract the archive, swap the glibc-217 node into the staged tree, run the
# official updater (it writes current.json, install.json and releases/<id>/), then let apply.sh
# swap the remaining binaries inside the installed release dir.
#
# Usage:
#   bootstrap-source-server.sh --zcode-version 3.16.3 --node /path/to/legacy-node
#
# Env:
#   ZCL_SOURCE_CDN   release CDN base (default overseas, domestic mirror as fallback)
#   ZCODE_RUNTIME_ROOT / ZCL_STATE_DIR as in apply.sh
#
set -euo pipefail

RUNTIME_ROOT="${ZCODE_RUNTIME_ROOT:-$HOME/.zcode/server}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=layout.sh
. "$SCRIPT_DIR/layout.sh"

ZCODE_VERSION=""
NODE_SRC=""
CDN_LIST=(
  "${ZCL_SOURCE_CDN:-https://cdn-zcode.z.ai/zcode/electron/releases}"
  "https://cdn.codegeex.cn/zcode/electron/releases"
)

log()  { echo "  [INFO]  $*"; }
err()  { echo "  [ERROR] $*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: bootstrap-source-server.sh --zcode-version VER --node PATH [--cdn BASE]

  --zcode-version VER   Source-server release to install (e.g. 3.16.3).
  --node PATH           glibc-217 node binary from a bundle (drives the official updater).
  --cdn BASE            Release CDN base (default: overseas CDN, domestic mirror as fallback).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --zcode-version) ZCODE_VERSION="${2:-}"; shift 2 ;;
    --node)          NODE_SRC="${2:-}"; shift 2 ;;
    --cdn)           CDN_LIST=("${2:-}"); shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done
[ -n "$ZCODE_VERSION" ] || { usage; die "--zcode-version is required"; }
[ -f "$NODE_SRC" ] || die "--node must point at a glibc-217 node binary"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------------- fetch release manifest + archive
fetch() {  # url -> out file; tries each CDN in order
  local path="$1" out="$2" base url
  for base in "${CDN_LIST[@]}"; do
    url="${base%/}/${path}"
    log "GET $url"
    if curl -fsSL --max-time 600 --retry 2 -o "$out" "$url"; then
      return 0
    fi
    rm -f "$out"
  done
  die "download failed: $path"
}

MANIFEST="$WORK/source-server-release.json"
fetch "$ZCODE_VERSION/source-server-release.json" "$MANIFEST"

# linux-x64 archive entry: fileName + sha256
ARCHIVE_NAME="$(grep -A6 '"target": "linux-x64"' "$MANIFEST" | grep -oE '"fileName": "[^"]*"' | head -n1 | sed 's/.*: "//; s/"//')"
ARCHIVE_SHA="$(grep -A8 '"target": "linux-x64"' "$MANIFEST" | grep -oE '"sha256": "[^"]*"' | head -n1 | sed 's/.*: "//; s/"//')"
[ -n "$ARCHIVE_NAME" ] && [ -n "$ARCHIVE_SHA" ] || die "no linux-x64 archive in $MANIFEST"

ARCHIVE="$WORK/$ARCHIVE_NAME"
fetch "$ZCODE_VERSION/$ARCHIVE_NAME" "$ARCHIVE"
echo "$ARCHIVE_SHA  $ARCHIVE" | sha256sum -c - >/dev/null \
  || die "archive sha256 mismatch (expected $ARCHIVE_SHA)"
log "archive verified: $ARCHIVE_NAME ($(du -h "$ARCHIVE" | cut -f1))"

# --------------------------------------------------------------------------- stage + run official updater under legacy node
EXTRACT="$WORK/extract"
mkdir -p "$EXTRACT"
tar -xzf "$ARCHIVE" -C "$EXTRACT" --strip-components=1
[ -f "$EXTRACT/bin/zcode" ] || die "staged archive has no bin/zcode - unexpected archive layout"

install -m 0755 "$NODE_SRC" "$EXTRACT/runtime/node"

# Since 3.17.1 the updater ends with a "restart" phase: it launches the NEW release's server
# core and waits for state "ready" (waitForUpdateReady). The new release ships the official
# glibc-2.28 node, which dies instantly on this host -> "Server Core failed while applying
# update". The release dir name is deterministic (<version>-linux-x64-<first 12 of archive
# sha256>), so a watchtower keeps the legacy node in place inside the new release dir while
# the updater runs, beating the smoke-start to the punch.
SHA12="$(sha256sum "$ARCHIVE" | cut -c1-12)"
NEW_RUNTIME="$RUNTIME_ROOT/releases/$ZCODE_VERSION-linux-x64-$SHA12/runtime"
WATCHTOWER=""
( while [ ! -f "$WORK/updater.done" ]; do
    if [ -d "$NEW_RUNTIME" ]; then
      cp -f "$NODE_SRC" "$NEW_RUNTIME/node.wt" 2>/dev/null \
        && mv -f "$NEW_RUNTIME/node.wt" "$NEW_RUNTIME/node" 2>/dev/null || true
    fi
    sleep 0.3
  done ) &
WATCHTOWER=$!
trap 'touch "$WORK/updater.done"; [ -n "${WATCHTOWER:-}" ] && kill "$WATCHTOWER" 2>/dev/null; rm -rf "$WORK"' EXIT

log "running official updater under the glibc-217 node"
set +e
"$EXTRACT/bin/zcode" update --from-archive "$ARCHIVE" --server-root "$RUNTIME_ROOT" --json --progress > "$WORK/update.json" 2>"$WORK/update.err"
RC=$?
set -e
touch "$WORK/updater.done" 2>/dev/null || true
[ -n "$WATCHTOWER" ] && kill "$WATCHTOWER" 2>/dev/null || true

if [ $RC -ne 0 ]; then
  # The restart phase (3.17.1+) launches the new core and waits for "ready"; on a fast disk the
  # watchtower can lose that race ("Server Core failed while applying update"). By then the
  # extract+verify phases have completed - the release tree on disk is complete and
  # hash-verified, only the identity files were rolled back. current.json is fully derivable
  # (the releaseId convention is <version>-linux-x64-<first 12 of archive sha256>, proven by
  # 3.16.3 and 3.17.1), so finish the transaction by hand rather than re-rolling the race.
  if grep -q '"phase":"restart"' "$WORK/update.json" 2>/dev/null; then
    log "updater failed at the restart phase - completing the transaction by hand"
    RD="$RUNTIME_ROOT/releases/$ZCODE_VERSION-linux-x64-$SHA12"
    for f in runtime/server-cli.js runtime/server-core.js runtime/zcode.cjs runtime/node; do
      [ -f "$RD/$f" ] || die "release tree incomplete at $RD/$f - cannot complete by hand"
    done
    install -m 0755 "$NODE_SRC" "$RD/runtime/node"
    if [ ! -f "$RUNTIME_ROOT/install.json" ]; then
      printf '{\n  "product": "zcode-server",\n  "schemaVersion": 1,\n  "canonicalServerRoot": "%s",\n  "installationId": "%s",\n  "installedAt": %s\n}\n' \
        "$RUNTIME_ROOT" "$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen)" "$(date +%s000)" \
        > "$RUNTIME_ROOT/install.json"
    fi
    awk 'BEGIN{on=0} /^  "components":/{on=1} on{print} on&&/^\  \]/{exit}' "$EXTRACT/manifest.json" > "$WORK/components.json"
    {
      printf '{\n'
      printf '  "version": "%s",\n' "$ZCODE_VERSION"
      printf '  "releaseDir": "%s",\n' "$RD"
      printf '  "nodeVersion": "%s",\n' "$(json_field "$EXTRACT/manifest.json" nodeVersion)"
      printf '  "releaseId": "%s-linux-x64-%s",\n' "$ZCODE_VERSION" "$SHA12"
      printf '  "appVersion": "%s",\n' "$ZCODE_VERSION"
      printf '  "target": "%s",\n' "$(json_field "$EXTRACT/manifest.json" target)"
      printf '  "archiveSha256": "%s",\n' "$ARCHIVE_SHA"
      printf '  "components": '
      cat "$WORK/components.json"
      printf '\n}\n'
    } > "$RUNTIME_ROOT/current.json"
    log "identity written by hand: $(json_field "$RUNTIME_ROOT/current.json" releaseId)"
  else
    tail -5 "$WORK/update.err" >&2
    die "official update step failed (exit $RC; see above)"
  fi
fi
tail -1 "$WORK/update.json" 2>/dev/null || true

[ -f "$RUNTIME_ROOT/current.json" ] || die "updater wrote no current.json - aborting"
log "bootstrapped: $(json_field "$RUNTIME_ROOT/current.json" releaseId)"
