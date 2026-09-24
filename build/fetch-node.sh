#!/usr/bin/env bash
#
# fetch-node.sh - download and verify the Node.js glibc-2.17 build for a given version.
#
# Env:
#   NODE_VERSION   default 22.16.0
#   ZCL_DEPS_DIR   default $HOME/.zcode/legacy-glibc/build-deps
#
# On success prints the extracted node directory (containing bin/node and include/node).
#
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-22.16.0}"
DEPS_DIR="${ZCL_DEPS_DIR:-$HOME/.zcode/legacy-glibc/build-deps}"
BASE_URL="https://unofficial-builds.nodejs.org/download/release/v${NODE_VERSION}"
ARCHIVE="node-v${NODE_VERSION}-linux-x64-glibc-217.tar.gz"

log() { echo "  [INFO]  $*"; }
die() { echo "  [ERROR] $*" >&2; exit 1; }

mkdir -p "$DEPS_DIR"
cd "$DEPS_DIR"

if [ ! -f "$ARCHIVE" ]; then
  log "downloading $BASE_URL/$ARCHIVE"
  curl -fsSL -o "$ARCHIVE" "$BASE_URL/$ARCHIVE" || die "download failed: $ARCHIVE"
fi

log "verifying sha256 against $BASE_URL/SHASUMS256.txt"
curl -fsSL -o SHASUMS256.txt "$BASE_URL/SHASUMS256.txt" || die "cannot fetch SHASUMS256.txt"
expected="$(grep " ${ARCHIVE}\$" SHASUMS256.txt | awk '{print $1}')"
[ -n "$expected" ] || die "no checksum published for $ARCHIVE"
actual="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
[ "$expected" = "$actual" ] || die "checksum mismatch for $ARCHIVE (expected $expected, got $actual)"
log "checksum OK: $actual"

dir="$DEPS_DIR/node-v${NODE_VERSION}-linux-x64-glibc-217"
if [ ! -x "$dir/bin/node" ]; then
  log "extracting"
  tar xzf "$ARCHIVE" -C "$DEPS_DIR"
fi

"$dir/bin/node" -v >/dev/null || die "extracted node does not run on this host"
echo "$dir"
