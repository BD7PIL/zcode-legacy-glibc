#!/usr/bin/env bash
#
# build-koffi.sh - build the koffi FFI addon for the glibc-2.17 target.
#
# koffi (used by @mbears/opentui-core inside the source-server runtime) ships only glibc-2.28
# and dynamic-musl prebuilds, so on EL7 it must be compiled from source against the RHEL7
# system glibc with libstdc++/libgcc statically linked.
#
# Env:
#   KOFFI_VERSION  default 2.15.6 (must match the runtime's node_modules/koffi/package.json)
#   NODE_DIR       extracted glibc-217 node directory (see fetch-node.sh)
#   CC / CXX       default to devtoolset-11 on EL7, falling back to plain gcc/g++
#   OUT_DIR        default ./out-koffi
#
# On success prints the path of the built koffi.node.
#
set -euo pipefail

KOFFI_VERSION="${KOFFI_VERSION:-2.15.6}"
NODE_DIR="${NODE_DIR:-}"
OUT_DIR="${OUT_DIR:-$(pwd)/out-koffi}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"

log() { echo "  [INFO]  $*" >&2; }
die() { echo "  [ERROR] $*" >&2; exit 1; }

[ -n "$NODE_DIR" ] && [ -x "$NODE_DIR/bin/node" ] || die "NODE_DIR must point at an extracted node (see fetch-node.sh)"

if [ -z "${CC:-}" ] && [ -x /opt/rh/devtoolset-11/root/usr/bin/gcc ]; then
  export CC=/opt/rh/devtoolset-11/root/usr/bin/gcc
  export CXX=/opt/rh/devtoolset-11/root/usr/bin/g++
fi
export CXXFLAGS="${CXXFLAGS:--static-libstdc++ -static-libgcc}"
export LDFLAGS="${LDFLAGS:--static-libstdc++ -static-libgcc}"
export PATH="$NODE_DIR/bin:$PATH"

if [ -z "${PYTHON:-}" ]; then
  if [ -x /opt/rh/rh-python38/root/usr/bin/python3 ]; then
    export PYTHON=/opt/rh/rh-python38/root/usr/bin/python3
  elif command -v python3 >/dev/null 2>&1; then
    export PYTHON="$(command -v python3)"
  else
    die "no python3 found (node-gyp needs it)"
  fi
fi

GYP_SPEC="node-gyp@11"
if ! "$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)'; then
  GYP_SPEC="node-gyp@9"
  log "python < 3.8 detected - using $GYP_SPEC"
fi

log "packing koffi@$KOFFI_VERSION"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
npm pack "koffi@$KOFFI_VERSION" --silent >/dev/null 2>&1 || die "npm pack failed for koffi@$KOFFI_VERSION"
tar xzf "koffi-${KOFFI_VERSION}.tgz"
cd package
[ -f binding.gyp ] || die "koffi@$KOFFI_VERSION ships no binding.gyp - source build unsupported upstream"

log "compiling with $GYP_SPEC"
npm install --no-save --no-audit --no-fund --ignore-scripts "$GYP_SPEC" >/dev/null 2>&1 || die "npm install (node-gyp) failed"
node_modules/.bin/node-gyp rebuild --nodedir="$NODE_DIR" > build.log 2>&1 || { tail -30 build.log >&2; die "node-gyp rebuild failed"; }

BUILT="$(find . -name 'koffi.node' -path '*/Release/*' -o -name 'koffi.node' -path '*/koffi/*' | head -n1)"
[ -n "$BUILT" ] || { find . -name 'koffi.node' >&2 || true; die "node-gyp produced no koffi.node"; }

mkdir -p "$OUT_DIR"
install -m 0755 "$BUILT" "$OUT_DIR/koffi.node"

log "glibc ceiling: $(objdump -T "$OUT_DIR/koffi.node" | grep -oE 'GLIBC_2\.[0-9]+(\.[0-9]+)?' | sort -Vu | tail -n1)"
log "libstdc++ refs: $(objdump -T "$OUT_DIR/koffi.node" | grep -cE 'GLIBCXX_|CXXABI_' || true)"
echo "$OUT_DIR/koffi.node"
