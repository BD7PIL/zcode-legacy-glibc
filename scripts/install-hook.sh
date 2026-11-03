#!/usr/bin/env bash
#
# install-hook.sh - wire on-connect.sh into ~/.bashrc so every SSH exec self-checks.
#
# EL7's bash (SSH_SOURCE_BASHRC) sources ~/.bashrc for non-interactive ssh commands, which is
# exactly what the ZCode desktop runs on every connect (probe, daemon control, exec). The hook
# is placed at the very top of the file, before any early-return lines, and is idempotent.
#
# Usage: install-hook.sh [--remove]
#
set -euo pipefail

KIT_DIR="${ZCL_STATE_DIR:-$HOME/.zcode/legacy-glibc}"
BASHRC="${ZCL_BASHRC:-$HOME/.bashrc}"
MARKER="# zcode-legacy-glibc on-connect self-heal"

log()  { echo "  [INFO]  $*"; }
err()  { echo "  [ERROR] $*" >&2; exit 1; }

HOOK_START="$MARKER"
HOOK_END="# zcode-legacy-glibc on-connect end"

if [ "${1:-}" = "--remove" ]; then
  [ -f "$BASHRC" ] || err "no $BASHRC"
  tmp="$(mktemp)"
  awk -v start="$HOOK_START" -v end="$HOOK_END" '
    $0 ~ start {skip=1; next}
    $0 ~ end   {skip=0; next}
    !skip {print}
  ' "$BASHRC" > "$tmp"
  if cmp -s "$BASHRC" "$tmp"; then
    log "hook not present - nothing removed"
  else
    mv "$tmp" "$BASHRC"
    log "hook removed from $BASHRC"
  fi
  rm -f "$tmp"
  exit 0
fi

if grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
  log "hook already installed in $BASHRC"
  exit 0
fi

[ -x "$KIT_DIR/scripts/on-connect.sh" ] || err "missing $KIT_DIR/scripts/on-connect.sh - install the kit first"

tmp="$(mktemp)"
{
  cat <<'EOF'
# zcode-legacy-glibc on-connect self-heal
if [ -n "${SSH_CONNECTION:-}" ] && [ -x "$HOME/.zcode/legacy-glibc/scripts/on-connect.sh" ]; then
  setsid "$HOME/.zcode/legacy-glibc/scripts/on-connect.sh" >/dev/null 2>&1 </dev/null &
fi
# zcode-legacy-glibc on-connect end
EOF
  cat "$BASHRC" 2>/dev/null || true
} > "$tmp"
mv "$tmp" "$BASHRC"
log "hook installed at the top of $BASHRC"
log "every ssh exec now self-checks (~ms when healthy; heals in the background on a version mismatch)"
