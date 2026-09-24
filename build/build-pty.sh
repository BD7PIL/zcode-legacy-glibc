#!/usr/bin/env bash
#
# build-pty.sh - rebuild the node-pty native addon for the glibc-2.17 target.
#
# The official prebuild requires GLIBC_2.28 and GLIBCXX_3.4.22. This script compiles the exact
# upstream version from npm against the RHEL7 system glibc and statically links libstdc++/libgcc,
# so the resulting pty.node has no libstdc++ runtime dependency at all.
#
# Env:
#   NODE_PTY_VERSION  default 1.2.0-beta.10 (must match what ZCode's manifest declares)
#   NODE_DIR          extracted glibc-217 node directory (see fetch-node.sh)
#   CC / CXX          default to devtoolset-11 on EL7, falling back to plain gcc/g++
#   OUT_DIR           default ./out-pty
#
# On success prints the path of the built pty.node.
#
set -euo pipefail

NODE_PTY_VERSION="${NODE_PTY_VERSION:-1.2.0-beta.10}"
NODE_DIR="${NODE_DIR:-}"
OUT_DIR="${OUT_DIR:-$(pwd)/out-pty}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"

log() { echo "  [INFO]  $*"; }
die() { echo "  [ERROR] $*" >&2; exit 1; }

[ -n "$NODE_DIR" ] && [ -x "$NODE_DIR/bin/node" ] || die "NODE_DIR must point at an extracted node (see fetch-node.sh)"

if [ -z "${CC:-}" ] && [ -x /opt/rh/devtoolset-11/root/usr/bin/gcc ]; then
  export CC=/opt/rh/devtoolset-11/root/usr/bin/gcc
  export CXX=/opt/rh/devtoolset-11/root/usr/bin/g++
fi
export CXXFLAGS="${CXXFLAGS:--static-libstdc++ -static-libgcc}"
export LDFLAGS="${LDFLAGS:--static-libstdc++ -static-libgcc}"
export PATH="$NODE_DIR/bin:$PATH"

# node-gyp's bundled gyp needs Python >= 3.8; on EL7 python3 is 3.6, so use rh-python38 when present
# and otherwise fall back to node-gyp@9 whose gyp still supports 3.6.
if [ -z "${PYTHON:-}" ]; then
  if [ -x /opt/rh/rh-python38/root/usr/bin/python3 ]; then
    export PYTHON=/opt/rh/rh-python38/root/usr/bin/python3
  elif command -v python3 >/dev/null 2>&1; then
    export PYTHON="$(command -v python3)"
  else
    die "no python3 found (node-gyp needs it)"
  fi
fi
log "python: $PYTHON ($("$PYTHON" -V 2>&1))"

GYP_SPEC="node-gyp@11"
if ! "$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'; then
  GYP_SPEC="node-gyp@9"
  log "python < 3.8 detected - using $GYP_SPEC"
fi

log "packing node-pty@$NODE_PTY_VERSION"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
npm pack "node-pty@$NODE_PTY_VERSION" --silent >/dev/null 2>&1 || die "npm pack failed for node-pty@$NODE_PTY_VERSION"
tar xzf "node-pty-${NODE_PTY_VERSION}.tgz"
cd package

log "installing build dependencies (scripts disabled)"
npm install --ignore-scripts --no-audit --no-fund >/dev/null 2>&1 || die "npm install failed"

log "compiling with $GYP_SPEC"
npm install --no-save --no-audit --no-fund "$GYP_SPEC" >/dev/null 2>&1
node_modules/.bin/node-gyp rebuild --nodedir="$NODE_DIR" >/dev/null || die "node-gyp rebuild failed"

[ -f build/Release/pty.node ] || die "pty.node was not produced"

mkdir -p "$OUT_DIR"
install -m 0755 build/Release/pty.node "$OUT_DIR/pty.node"

log "glibc ceiling: $(objdump -T "$OUT_DIR/pty.node" | grep -oE 'GLIBC_2\.[0-9]+(\.[0-9]+)?' | sort -Vu | tail -n1)"
log "libstdc++ refs: $(objdump -T "$OUT_DIR/pty.node" | grep -cE 'GLIBCXX_|CXXABI_' || true)"
echo "$OUT_DIR/pty.node"
