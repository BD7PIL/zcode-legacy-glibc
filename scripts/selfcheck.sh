#!/usr/bin/env bash
#
# selfcheck.sh - health check for the patched runtime, with optional offline self-heal.
#
# Designed to be called by cron/@reboot (opt-in). It never downloads anything: when the runtime
# is broken it replays the newest bundle from the local cache.
#
set -euo pipefail

RUNTIME_ROOT="${ZCODE_RUNTIME_ROOT:-$HOME/.zcode/server}"
STATE_DIR="${ZCL_STATE_DIR:-$HOME/.zcode/legacy-glibc}"
CACHE_DIR="$STATE_DIR/cache"
LOG_FILE="$STATE_DIR/selfcheck.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRON_MARKER="# zcode-legacy-glibc selfcheck"

mkdir -p "$STATE_DIR"

log() { echo "  [INFO]  $*" | tee -a "$LOG_FILE"; }
err() { echo "  [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

NODE="$RUNTIME_ROOT/node"
PTY="$RUNTIME_ROOT/build/Release/pty.node"

healthy() {
  [ -x "$NODE" ] || { err "node missing or not executable"; return 1; }
  "$NODE" -v >/dev/null 2>&1 || { err "node cannot start"; return 1; }
  [ -f "$PTY" ] || { err "pty.node missing"; return 1; }
  "$NODE" -e "require(process.argv[1])" "$PTY" >/dev/null 2>&1 || { err "pty.node cannot be loaded"; return 1; }
  for t in "$RUNTIME_ROOT/tools/bfs/bfs" "$RUNTIME_ROOT/tools/ugrep/ugrep" "$RUNTIME_ROOT/tools/ripgrep/rg"; do
    [ -x "$t" ] || { err "missing tool: $t"; return 1; }
    "$t" --version >/dev/null 2>&1 || { err "tool does not run: $t"; return 1; }
  done
  return 0
}

install_cron() {
  local entry="@reboot $SCRIPT_DIR/selfcheck.sh >> $LOG_FILE 2>&1"
  local daily="23 7 * * * $SCRIPT_DIR/selfcheck.sh >> $LOG_FILE 2>&1"
  { crontab -l 2>/dev/null | grep -vF "$CRON_MARKER"; echo "$CRON_MARKER"; echo "$entry"; echo "$daily"; } | crontab -
  log "cron installed (@reboot + daily 07:23)"
}

remove_cron() {
  crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" | grep -v 'selfcheck.sh' | crontab - || true
  log "cron removed"
}

case "${1:-}" in
  --install-cron) install_cron; exit 0 ;;
  --remove-cron)  remove_cron; exit 0 ;;
  -h|--help)      echo "Usage: selfcheck.sh [--install-cron|--remove-cron]"; exit 0 ;;
esac

echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) selfcheck start" >> "$LOG_FILE"

if healthy; then
  log "runtime healthy"
  exit 0
fi

BUNDLE="$(find "$CACHE_DIR" -maxdepth 1 -name 'zcode-legacy-glibc-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2- || true)"
if [ -z "${BUNDLE:-}" ]; then
  err "runtime is broken and no cached bundle exists in $CACHE_DIR - run: $SCRIPT_DIR/apply.sh --bundle <tarball>"
  exit 1
fi

log "runtime broken - replaying $BUNDLE"
bash "$SCRIPT_DIR/apply.sh" --bundle "$BUNDLE" || { err "re-apply failed"; exit 1; }

if healthy; then
  log "self-heal succeeded"
else
  err "self-heal finished but the runtime is still unhealthy"
  exit 1
fi
