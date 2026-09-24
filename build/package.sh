#!/usr/bin/env bash
#
# package.sh - assemble a release bundle: artifacts + manifest.json + SHA256SUMS + tarball.
#
# Two sources are supported:
#
#   --from-runtime            copy what is currently installed in $ZCODE_RUNTIME_ROOT
#                             (used to snapshot a working host into an offline cache bundle)
#   --from-artifacts DIR      use node/, pty.node, bfs, ugrep produced by build/*.sh
#
# Version fields are the strings ZCode records in its markers, not necessarily the upstream
# versions; the upstream version is recorded separately for honesty.
#
set -euo pipefail

RUNTIME_ROOT="${ZCODE_RUNTIME_ROOT:-$HOME/.zcode/server}"
OUT_DIR="$(pwd)/dist"
SOURCE=""
FROM_ARTIFACTS=""
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

ZCODE_VERSION="${ZCL_ZCODE_VERSION:-3.14.3}"
NODE_VERSION="${NODE_VERSION:-v22.16.0}"
NODE_UPSTREAM="${NODE_UPSTREAM:-22.16.0}"
NODE_PTY_VERSION="${NODE_PTY_VERSION:-v1.2.0-beta.10}"
NODE_PTY_UPSTREAM="${NODE_PTY_UPSTREAM:-1.2.0-beta.10}"
BFS_VERSION="${BFS_VERSION:-v4.1.1-2}"
BFS_UPSTREAM="${BFS_UPSTREAM:-4.1.1}"
UGREP_VERSION="${UGREP_VERSION:-v7.8.4-1}"
UGREP_UPSTREAM="${UGREP_UPSTREAM:-7.8.4}"

log() { echo "  [INFO]  $*"; }
die() { echo "  [ERROR] $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from-runtime)   SOURCE=runtime; shift ;;
    --from-artifacts) SOURCE=artifacts; FROM_ARTIFACTS="${2:-}"; shift 2 ;;
    --out)            OUT_DIR="${2:-}"; shift 2 ;;
    --zcode-version)  ZCODE_VERSION="${2:-}"; shift 2 ;;
    --node-version)   NODE_VERSION="${2:-}"; shift 2 ;;
    --node-pty-version) NODE_PTY_VERSION="${2:-}"; shift 2 ;;
    --bfs-version)    BFS_VERSION="${2:-}"; shift 2 ;;
    --ugrep-version)  UGREP_VERSION="${2:-}"; shift 2 ;;
    -h|--help)        sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$SOURCE" ] || die "choose --from-runtime or --from-artifacts DIR"

STAGE="$WORK_DIR/stage"
mkdir -p "$STAGE"

if [ "$SOURCE" = runtime ]; then
  [ -x "$RUNTIME_ROOT/node" ] || die "missing $RUNTIME_ROOT/node"
  install -m 0755 "$RUNTIME_ROOT/node" "$STAGE/node"
  install -m 0755 "$RUNTIME_ROOT/build/Release/pty.node" "$STAGE/pty.node"
  install -m 0755 "$RUNTIME_ROOT/tools/bfs/bfs" "$STAGE/bfs"
  install -m 0755 "$RUNTIME_ROOT/tools/ugrep/ugrep" "$STAGE/ugrep"
else
  [ -d "$FROM_ARTIFACTS" ] || die "artifact dir not found: $FROM_ARTIFACTS"
  for f in node pty.node bfs ugrep; do
    [ -f "$FROM_ARTIFACTS/$f" ] || die "missing artifact: $FROM_ARTIFACTS/$f"
    install -m 0755 "$FROM_ARTIFACTS/$f" "$STAGE/$f"
  done
fi

mkdir -p "$OUT_DIR"
TAG="v${ZCODE_VERSION}-${NODE_VERSION#v}"
TARBALL="$OUT_DIR/zcode-legacy-glibc-${TAG}.tar.gz"

log "writing manifest"
{
  echo "{"
  echo "  \"name\": \"zcode-legacy-glibc\","
  echo "  \"zcodeVersion\": \"$ZCODE_VERSION\","
  echo "  \"platformArch\": \"linux-x64\","
  echo "  \"glibcCeiling\": \"2.17\","
  echo "  \"builtAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"components\": ["
  echo "    {\"id\": \"node-runtime\", \"version\": \"$NODE_VERSION\", \"upstream\": \"node $NODE_UPSTREAM glibc-217\", \"path\": \"node\", \"target\": \"node\"},"
  echo "    {\"id\": \"node-pty\", \"version\": \"$NODE_PTY_VERSION\", \"upstream\": \"node-pty $NODE_PTY_UPSTREAM\", \"path\": \"pty.node\", \"target\": \"build/Release/pty.node\"},"
  echo "    {\"id\": \"bfs\", \"version\": \"$BFS_VERSION\", \"upstream\": \"bfs $BFS_UPSTREAM\", \"path\": \"bfs\", \"target\": \"tools/bfs/bfs\"},"
  echo "    {\"id\": \"ugrep\", \"version\": \"$UGREP_VERSION\", \"upstream\": \"ugrep $UGREP_UPSTREAM\", \"path\": \"ugrep\", \"target\": \"tools/ugrep/ugrep\"}"
  echo "  ]"
  echo "}"
} > "$STAGE/manifest.json"

log "writing SHA256SUMS"
( cd "$STAGE" && sha256sum node pty.node bfs ugrep manifest.json > SHA256SUMS )

log "creating $TARBALL"
tar czf "$TARBALL" -C "$STAGE" .
sha256sum "$TARBALL" | awk '{print $1}' > "$TARBALL.sha256"

log "bundle: $(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"
log "state dir hint: copy it into ~/.zcode/legacy-glibc/cache/ for offline re-apply"
echo "$TARBALL"
