#!/usr/bin/env bash
#
# install.sh - one-command setup of the glibc-2.17 ZCode remote runtime on a fresh host.
#
# Everything the device consumes comes from this repo's GitHub release (replacement binaries
# + kit scripts). The only third-party fetch is the official ~91 MB source-server archive from
# the ZCode release CDN, which the kit's bootstrap step downloads and installs through ZCode's
# own updater - we do not redistribute ZCode's proprietary binaries.
#
# Usage:
#   curl -fsSL https://github.com/BD7PIL/zcode-legacy-glibc/releases/latest/download/install.sh | bash
#   # or, pinned to a release:
#   install.sh [release-tag]
#
# Env:
#   ZCL_STATE_DIR  kit home (default ~/.zcode/legacy-glibc)
#   ZCL_REPO       source repo (default BD7PIL/zcode-legacy-glibc)
#   ZCL_SOURCE_CDN override for the ZCode release CDN
#
set -euo pipefail

KIT_DIR="${ZCL_STATE_DIR:-$HOME/.zcode/legacy-glibc}"
REPO="${ZCL_REPO:-BD7PIL/zcode-legacy-glibc}"
TAG="${1:-}"

log()  { echo "  [INFO]  $*"; }
die()  { echo "  [ERROR] $*" >&2; exit 1; }

command -v curl >/dev/null || die "curl is required"
command -v tar >/dev/null || die "tar is required"
command -v sha256sum >/dev/null || die "sha256sum is required"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --------------------------------------------------------------------------- resolve release
if [ -z "$TAG" ]; then
  TAG="$(curl -fsSL --max-time 30 "https://api.github.com/repos/$REPO/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [ -n "$TAG" ] || die "cannot resolve the latest release of $REPO (check network egress)"
fi
log "release: $TAG"

BUNDLE_NAME="zcode-legacy-glibc-$TAG.tar.gz"
BASE="https://github.com/$REPO/releases/download/$TAG"

curl -fsSL --max-time 600 --retry 3 -o "$WORK/$BUNDLE_NAME" "$BASE/$BUNDLE_NAME" \
  || die "bundle download failed: $BASE/$BUNDLE_NAME"
curl -fsSL --max-time 60 -o "$WORK/$BUNDLE_NAME.sha256" "$BASE/$BUNDLE_NAME.sha256" \
  || die "checksum download failed"
expected="$(tr -d ' \t\r\n' < "$WORK/$BUNDLE_NAME.sha256" | grep -oE '^[0-9a-f]{64}' || true)"
actual="$(sha256sum "$WORK/$BUNDLE_NAME" | awk '{print $1}')"
[ -n "$expected" ] && [ "$expected" = "$actual" ] \
  || die "bundle sha256 mismatch (expected ${expected:-none}, got $actual) - refusing to install"
log "bundle verified: $BUNDLE_NAME"

# --------------------------------------------------------------------------- install kit
mkdir -p "$KIT_DIR/cache"
tar -xzf "$WORK/$BUNDLE_NAME" -C "$WORK"
[ -d "$WORK/scripts" ] || die "release $TAG predates self-contained bundles (no scripts/ inside) - rebuild it"
rm -rf "$KIT_DIR/scripts"
cp -r "$WORK/scripts" "$KIT_DIR/scripts"
chmod +x "$KIT_DIR/scripts/"*.sh
mv "$WORK/$BUNDLE_NAME" "$KIT_DIR/cache/$BUNDLE_NAME"
cp "$WORK/$BUNDLE_NAME.sha256" "$KIT_DIR/cache/"
log "kit installed: $KIT_DIR (scripts + cached bundle)"

# --------------------------------------------------------------------------- apply + verify
log "applying (a fresh host downloads the official source-server from the ZCode CDN first)"
bash "$KIT_DIR/scripts/apply.sh" --bundle "$KIT_DIR/cache/$BUNDLE_NAME"

echo
echo "  [DONE]  ZCode remote runtime is installed and verified on this host."
echo "          State: $KIT_DIR/state.env   Log hints: $KIT_DIR/selfcheck.log"
echo "          Re-apply after a ZCode upgrade:  $KIT_DIR/scripts/apply.sh"
echo "          Health check:                    $KIT_DIR/scripts/verify.sh"
echo "          Rollback to official binaries:   $KIT_DIR/scripts/rollback.sh"
