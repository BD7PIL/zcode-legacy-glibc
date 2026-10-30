#!/usr/bin/env bash
#
# discover-source-server.sh - find ZCode source-server releases newer than what this repo built.
#
# The ZCode CDN exposes one manifest per desktop version - `<CDN>/<ver>/source-server-release.json` -
# and no "latest" endpoint, so discovery probes forward from a known version and stops at a
# bounded horizon (~same-minor patches, three minors, a major). For the newest hit it downloads
# the archive and reads the real component versions out of it - never guesses.
#
# Usage: discover-source-server.sh [--from VER] [--max-probes N]
#
# Stdout: KEY=VALUE lines (NEW_VERSION / NEW_NODE / NEW_NODE_PTY / NEW_KOFFI / NEW_BFS /
# NEW_UGREP), empty when nothing newer exists. Logs go to stderr.
#
set -euo pipefail

CDN_LIST=(
  "${ZCL_SOURCE_CDN:-https://cdn-zcode.z.ai/zcode/electron/releases}"
  "https://cdn.codegeex.cn/zcode/electron/releases"
)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=layout.sh
. "$SCRIPT_DIR/layout.sh"
BASELINE="${ZCL_BASELINE_ZCODE:-3.16.3}"
MAX_PROBES=90
FROM=""
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { echo "  [INFO] $*" >&2; }
die() { echo "  [ERROR] $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from)       FROM="${2:-}"; shift 2 ;;
    --max-probes) MAX_PROBES="${2:-}"; shift 2 ;;
    -h|--help)    sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# --------------------------------------------------------------------------- candidates
LAST="${FROM:-$BASELINE}"
if [ -z "$FROM" ]; then
  # newest v<zcode>-<node> release tag in this repo, when run from a checkout
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    tag="$(git tag --list 'v*-*' --sort=-v:refname | head -n1 || true)"
    if [ -n "$tag" ]; then
      LAST="${tag#v}"; LAST="${LAST%%-*}"
    fi
  fi
fi
IFS=. read -r A B C <<<"$LAST"
[ -n "${A:-}" ] && [ -n "${B:-}" ] && [ -n "${C:-}" ] || die "cannot parse baseline version: $LAST"
log "probing forward from $LAST (horizon $MAX_PROBES candidates)"

CANDIDATES=""
for ((c = C + 1; c <= C + 15; c++)); do CANDIDATES+="$A.$B.$c"$'\n'; done
for ((b = B + 1; b <= B + 3; b++)); do
  for ((c = 0; c <= 15; c++)); do CANDIDATES+="$A.$b.$c"$'\n'; done
done
for ((b = 0; b <= 2; b++)); do
  for ((c = 0; c <= 5; c++)); do CANDIDATES+="$((A + 1)).$b.$c"$'\n'; done
done
CANDIDATES="$(sort -Vu <<<"$CANDIDATES" | head -n "$MAX_PROBES")"

# --------------------------------------------------------------------------- probe
fetch_code() {  # path -> HTTP code (first CDN that answers)
  local path="$1" base url code
  for base in "${CDN_LIST[@]}"; do
    url="${base%/}/${path}"
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 --retry 1 "$url" || echo 000)"
    [ "$code" != "000" ] && { echo "$code"; return; }
  done
  echo 000
}

NEWEST=""
while IFS= read -r v; do
  [ -n "$v" ] || continue
  code="$(fetch_code "$v/source-server-release.json")"
  if [ "$code" = "200" ]; then
    log "hit: $v"
    NEWEST="$v"
  fi
done <<<"$CANDIDATES"

[ -n "$NEWEST" ] || { log "no source-server release newer than $LAST"; exit 0; }
log "newest source-server release: $NEWEST"

# --------------------------------------------------------------------------- read real component versions
ARCHIVE_NAME="zcode-server-linux-x64.tar.gz"
ARCHIVE=""
for base in "${CDN_LIST[@]}"; do
  if curl -fsSL --max-time 600 --retry 2 -o "$WORK/$ARCHIVE_NAME" "${base%/}/$NEWEST/$ARCHIVE_NAME"; then
    ARCHIVE="$WORK/$ARCHIVE_NAME"
    break
  fi
done
[ -n "$ARCHIVE" ] || die "cannot download $NEWEST/$ARCHIVE_NAME"

jv() {  # tar-member key -> first string value
  tar -xzOf "$ARCHIVE" "$1" 2>/dev/null \
    | sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}
NEW_NODE="$(jv zcode-server-linux-x64/manifest.json nodeVersion)"
NEW_NODE_PTY="$(jv zcode-server-linux-x64/runtime/node_modules/node-pty/package.json version)"
NEW_KOFFI="$(jv zcode-server-linux-x64/runtime/node_modules/koffi/package.json version)"
NEW_BFS="$(tar -xzOf "$ARCHIVE" zcode-server-linux-x64/runtime/tools/bfs/SOURCES.json 2>/dev/null | tool_version - bfs)"
NEW_UGREP="$(tar -xzOf "$ARCHIVE" zcode-server-linux-x64/runtime/tools/ugrep/SOURCES.json 2>/dev/null | tool_version - ugrep)"

[ -n "$NEW_NODE" ] || die "no nodeVersion in $NEWEST manifest"
for kv in NEW_NODE_PTY NEW_KOFFI NEW_BFS NEW_UGREP; do
  [ -n "${!kv:-}" ] || die "$kv not found in $NEWEST archive"
done

echo "NEW_VERSION=$NEWEST"
echo "NEW_NODE=$NEW_NODE"
echo "NEW_NODE_PTY=$NEW_NODE_PTY"
echo "NEW_KOFFI=$NEW_KOFFI"
echo "NEW_BFS=$NEW_BFS"
echo "NEW_UGREP=$NEW_UGREP"
