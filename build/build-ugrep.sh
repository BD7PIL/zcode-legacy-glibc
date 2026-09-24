#!/usr/bin/env bash
#
# build-ugrep.sh - build ugrep for the glibc-2.17 target, with a private static PCRE2.
#
# EL7 has no pcre2 headers and no libzstd, and installing RPMs is out of scope for this kit, so
# PCRE2 is compiled into a private prefix and linked statically into ugrep. libstdc++/libgcc are
# static as well, which leaves only glibc 2.17 + zlib/bzip2/lzma as runtime dependencies.
#
# Env:
#   UGREP_VERSION   default 7.8.4 (must match what ZCode's manifest declares)
#   PCRE2_VERSION   default 10.44
#   ZCL_DEPS_DIR    default $HOME/.zcode/legacy-glibc/build-deps
#   OUT_DIR         default ./out-ugrep
#   UGREP_SIMD      optional extra configure flags, e.g. "--disable-avx2" for a portable build
#
set -euo pipefail

UGREP_VERSION="${UGREP_VERSION:-7.8.4}"
PCRE2_VERSION="${PCRE2_VERSION:-10.44}"
DEPS_DIR="${ZCL_DEPS_DIR:-$HOME/.zcode/legacy-glibc/build-deps}"
OUT_DIR="${OUT_DIR:-$(pwd)/out-ugrep}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"
UGREP_SIMD="${UGREP_SIMD:-}"

log() { echo "  [INFO]  $*" >&2; }
die() { echo "  [ERROR] $*" >&2; exit 1; }

if [ -z "${CC:-}" ] && [ -x /opt/rh/devtoolset-11/root/usr/bin/gcc ]; then
  export CC=/opt/rh/devtoolset-11/root/usr/bin/gcc
  export CXX=/opt/rh/devtoolset-11/root/usr/bin/g++
fi
export CXXFLAGS="${CXXFLAGS:--static-libstdc++ -static-libgcc}"
export LDFLAGS="${LDFLAGS:--static-libstdc++ -static-libgcc}"

PCRE2_PREFIX="$DEPS_DIR/pcre2-$PCRE2_VERSION"

if [ ! -f "$PCRE2_PREFIX/lib/libpcre2-8.a" ]; then
  log "building PCRE2 $PCRE2_VERSION (static) into $PCRE2_PREFIX"
  mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
  curl -fsSL -o "pcre2-$PCRE2_VERSION.tar.gz" \
    "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" || die "PCRE2 download failed"
  tar xzf "pcre2-$PCRE2_VERSION.tar.gz"
  cd "pcre2-$PCRE2_VERSION"
  ./configure --prefix="$PCRE2_PREFIX" --disable-shared --enable-static \
    --disable-pcre2grep-libz --disable-pcre2grep-libbz2 --disable-pcre2test-libreadline \
    >/dev/null 2>&1 || die "PCRE2 configure failed"
  make -j"$(nproc 2>/dev/null || echo 2)" >/dev/null 2>&1 || die "PCRE2 make failed"
  make install >/dev/null 2>&1 || die "PCRE2 install failed"
fi
log "PCRE2: $PCRE2_PREFIX"

log "building ugrep $UGREP_VERSION"
mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
curl -fsSL -o ugrep.tar.gz "https://github.com/Genivia/ugrep/archive/refs/tags/v${UGREP_VERSION}.tar.gz" || die "ugrep download failed"
tar xzf ugrep.tar.gz
cd "ugrep-${UGREP_VERSION}"

# shellcheck disable=SC2086
./configure --prefix="$WORK_DIR/ugrep-prefix" \
  --with-pcre2="$PCRE2_PREFIX" --without-zstd --without-boost-regex $UGREP_SIMD \
  >/dev/null 2>&1 || die "ugrep configure failed"
make -j"$(nproc 2>/dev/null || echo 2)" >/dev/null 2>&1 || die "ugrep make failed"

mkdir -p "$OUT_DIR"
install -m 0755 src/ugrep "$OUT_DIR/ugrep"

log "glibc ceiling: $(objdump -T "$OUT_DIR/ugrep" | grep -oE 'GLIBC_2\.[0-9]+(\.[0-9]+)?' | sort -Vu | tail -n1)"
"$OUT_DIR/ugrep" --version | head -n1
echo "$OUT_DIR/ugrep"
