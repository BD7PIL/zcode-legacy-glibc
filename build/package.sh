#!/usr/bin/env bash
#
# package.sh - assemble a release bundle: artifacts + manifest.json + SHA256SUMS + tarball.
#
# Two sources are supported:
#
#   --from-runtime            copy what is currently installed in $ZCODE_RUNTIME_ROOT
#                             (either layout; used to snapshot a working host into an
#                             offline cache bundle)
#   --from-artifacts DIR      use node/, pty.node, bfs, ugrep [koffi.node] from build/*.sh
#
# Version fields are the strings the desktop records, not necessarily the upstream
# versions; the upstream version is recorded separately for honesty.
#
set -euo pipefail

RUNTIME_ROOT="${ZCODE_RUNTIME_ROOT:-$HOME/.zcode/server}"
OUT_DIR="$(pwd)/dist"
SOURCE=""
FROM_ARTIFACTS=""
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/layout.sh
. "$SCRIPT_DIR/../scripts/layout.sh"

ZCODE_VERSION="${ZCL_ZCODE_VERSION:-3.16.3}"
NODE_VERSION="${NODE_VERSION:-v22.16.0}"
NODE_UPSTREAM="${NODE_UPSTREAM:-22.16.0}"
NODE_PTY_VERSION="${NODE_PTY_VERSION:-v1.1.0}"
NODE_PTY_UPSTREAM="${NODE_PTY_UPSTREAM:-1.1.0}"
KOFFI_VERSION="${KOFFI_VERSION:-v2.15.6}"
KOFFI_UPSTREAM="${KOFFI_UPSTREAM:-2.15.6}"
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
    --koffi-version)  KOFFI_VERSION="${2:-}"; shift 2 ;;
    --bfs-version)    BFS_VERSION="${2:-}"; shift 2 ;;
    --ugrep-version)  UGREP_VERSION="${2:-}"; shift 2 ;;
    -h|--help)        sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$SOURCE" ] || die "choose --from-runtime or --from-artifacts DIR"

STAGE="$WORK_DIR/stage"
mkdir -p "$STAGE"

if [ "$SOURCE" = runtime ]; then
  LAYOUT="$(runtime_layout "$RUNTIME_ROOT")"
  [ "$LAYOUT" != "none" ] || die "no runtime found at $RUNTIME_ROOT"
  log "packaging from runtime ($LAYOUT layout)"
  for comp in node-runtime node-pty bfs ugrep koffi; do
    src="$(component_path "$RUNTIME_ROOT" "$LAYOUT" "$comp")"
    case "$comp" in
      node-runtime) out="node" ;;
      node-pty)     out="pty.node" ;;
      koffi)        out="koffi.node" ;;
      *)            out="$comp" ;;
    esac
    if [ ! -f "${src:-}" ]; then
      if [ "$comp" = "koffi" ]; then
        log "no koffi replacement installed - skipping"
        continue
      fi
      die "missing $comp at ${src:-<no target>}"
    fi
    install -m 0755 "$src" "$STAGE/$out"
  done
else
  [ -d "$FROM_ARTIFACTS" ] || die "artifact dir not found: $FROM_ARTIFACTS"
  for f in node pty.node bfs ugrep; do
    [ -f "$FROM_ARTIFACTS/$f" ] || die "missing artifact: $FROM_ARTIFACTS/$f"
    install -m 0755 "$FROM_ARTIFACTS/$f" "$STAGE/$f"
  done
  if [ -f "$FROM_ARTIFACTS/koffi.node" ]; then
    install -m 0755 "$FROM_ARTIFACTS/koffi.node" "$STAGE/koffi.node"
  else
    log "no koffi.node in artifacts - bundle will not carry a koffi replacement"
  fi
fi

mkdir -p "$OUT_DIR"
TAG="v${ZCODE_VERSION}-${NODE_VERSION#v}"
TARBALL="$OUT_DIR/zcode-legacy-glibc-${TAG}.tar.gz"

# The bundle ships the kit's own scripts so a device never needs the git repo.
log "staging kit scripts"
mkdir -p "$STAGE/scripts"
for s in "$SCRIPT_DIR/../scripts/"*.sh; do
  install -m 0755 "$s" "$STAGE/scripts/$(basename "$s")"
done

log "writing manifest"
{
  echo "{"
  echo "  \"name\": \"zcode-legacy-glibc\","
  echo "  \"zcodeVersion\": \"$ZCODE_VERSION\","
  echo "  \"platformArch\": \"linux-x64\","
  echo "  \"glibcCeiling\": \"2.17\","
  echo "  \"builtAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"components\": ["
  echo "    {\"id\": \"node-runtime\", \"version\": \"$NODE_VERSION\", \"upstream\": \"node $NODE_UPSTREAM glibc-217\", \"path\": \"node\", \"target\": \"runtime/node\"},"
  echo "    {\"id\": \"node-pty\", \"version\": \"$NODE_PTY_VERSION\", \"upstream\": \"node-pty $NODE_PTY_UPSTREAM\", \"path\": \"pty.node\", \"target\": \"runtime/node_modules/node-pty/prebuilds/linux-x64/pty.node\"},"
  if [ -f "$STAGE/koffi.node" ]; then
    echo "    {\"id\": \"koffi\", \"version\": \"$KOFFI_VERSION\", \"upstream\": \"koffi $KOFFI_UPSTREAM rebuilt\", \"path\": \"koffi.node\", \"target\": \"runtime/node_modules/koffi/build/koffi/linux_x64/koffi.node\"},"
  fi
  echo "    {\"id\": \"bfs\", \"version\": \"$BFS_VERSION\", \"upstream\": \"bfs $BFS_UPSTREAM\", \"path\": \"bfs\", \"target\": \"runtime/tools/bfs/bfs\"},"
  echo "    {\"id\": \"ugrep\", \"version\": \"$UGREP_VERSION\", \"upstream\": \"ugrep $UGREP_UPSTREAM\", \"path\": \"ugrep\", \"target\": \"runtime/tools/ugrep/ugrep\"}"
  echo "  ]"
  echo "}"
} > "$STAGE/manifest.json"

log "writing SHA256SUMS"
sums=(node pty.node bfs ugrep manifest.json)
[ -f "$STAGE/koffi.node" ] && sums+=(koffi.node)
( cd "$STAGE" && sha256sum "${sums[@]}" > SHA256SUMS )

log "creating $TARBALL"
tar czf "$TARBALL" -C "$STAGE" .
sha256sum "$TARBALL" | awk '{print $1}' > "$TARBALL.sha256"

log "bundle: $(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"
log "state dir hint: copy it into ~/.zcode/legacy-glibc/cache/ for offline re-apply"
echo "$TARBALL"
