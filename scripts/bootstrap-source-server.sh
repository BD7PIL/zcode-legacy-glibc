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
log "running official updater under the glibc-217 node"
"$EXTRACT/bin/zcode" update --from-archive "$ARCHIVE" --server-root "$RUNTIME_ROOT" --json --progress > "$WORK/update.json" 2>"$WORK/update.err" \
  || { tail -5 "$WORK/update.err" >&2; die "official update step failed (see above)"; }
tail -1 "$WORK/update.json"

[ -f "$RUNTIME_ROOT/current.json" ] || die "updater wrote no current.json - aborting"
log "bootstrapped: $(json_field "$RUNTIME_ROOT/current.json" releaseId)"
