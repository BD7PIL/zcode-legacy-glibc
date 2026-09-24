#!/usr/bin/env bash
#
# build-bfs.sh - build bfs for the glibc-2.17 target.
#
# Env:
#   BFS_VERSION  default 4.1.1 (must match what ZCode's manifest declares)
#   OUT_DIR      default ./out-bfs
#
set -euo pipefail

BFS_VERSION="${BFS_VERSION:-4.1.1}"
OUT_DIR="${OUT_DIR:-$(pwd)/out-bfs}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"

log() { echo "  [INFO]  $*"; }
die() { echo "  [ERROR] $*" >&2; exit 1; }

if [ -z "${CC:-}" ] && [ -x /opt/rh/devtoolset-11/root/usr/bin/gcc ]; then
  export CC=/opt/rh/devtoolset-11/root/usr/bin/gcc
fi

log "fetching bfs $BFS_VERSION"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
curl -fsSL -o bfs.tar.gz "https://codeload.github.com/tavianator/bfs/tar.gz/refs/tags/${BFS_VERSION}" || die "download failed"
tar xzf bfs.tar.gz
cd "bfs-${BFS_VERSION}"

log "configure + make"
./configure --prefix="$WORK_DIR/bfs-prefix" >/dev/null 2>&1 || die "configure failed"
make -j"$(nproc 2>/dev/null || echo 2)" >/dev/null 2>&1 || die "make failed"

mkdir -p "$OUT_DIR"
install -m 0755 bin/bfs "$OUT_DIR/bfs"

log "glibc ceiling: $(objdump -T "$OUT_DIR/bfs" | grep -oE 'GLIBC_2\.[0-9]+(\.[0-9]+)?' | sort -Vu | tail -n1)"
"$OUT_DIR/bfs" --version
echo "$OUT_DIR/bfs"
