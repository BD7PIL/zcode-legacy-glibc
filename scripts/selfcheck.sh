#!/usr/bin/env bash
#
# selfcheck.sh - manual health check for the patched runtime, with offline self-heal.
#
# It never downloads anything: when the runtime is broken it replays the newest bundle from the
# local cache. (No cron is installed by this kit; run it by hand, e.g. after a desktop upgrade.)
#
set -euo pipefail

RUNTIME_ROOT="${ZCODE_RUNTIME_ROOT:-$HOME/.zcode/server}"
STATE_DIR="${ZCL_STATE_DIR:-$HOME/.zcode/legacy-glibc}"
CACHE_DIR="$STATE_DIR/cache"
LOG_FILE="$STATE_DIR/selfcheck.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=layout.sh
. "$SCRIPT_DIR/layout.sh"

mkdir -p "$STATE_DIR"

log() { echo "  [INFO]  $*" | tee -a "$LOG_FILE"; }
err() { echo "  [ERROR] $*" | tee -a "$LOG_FILE" >&2; }

LAYOUT="$(runtime_layout "$RUNTIME_ROOT")"

healthy() {
  local node pty
  node="$(component_path "$RUNTIME_ROOT" "$LAYOUT" node-runtime)" || return 1
  pty="$(component_path "$RUNTIME_ROOT" "$LAYOUT" node-pty)" || return 1
  [ -x "$node" ] || { err "node missing or not executable"; return 1; }
  "$node" -v >/dev/null 2>&1 || { err "node cannot start"; return 1; }
  if [ "$LAYOUT" = "new" ]; then
    "$RUNTIME_ROOT/bin/zcode" --version >/dev/null 2>&1 || { err "bin/zcode cannot run"; return 1; }
  fi
  [ -f "$pty" ] || { err "pty.node missing"; return 1; }
  "$node" -e "require(process.argv[1])" "$pty" >/dev/null 2>&1 || { err "pty.node cannot be loaded"; return 1; }
  local id
  for id in bfs ugrep ripgrep; do
    local t; t="$(component_path "$RUNTIME_ROOT" "$LAYOUT" "$id")"
    [ -x "$t" ] || { err "missing tool: $t"; return 1; }
    "$t" --version >/dev/null 2>&1 || { err "tool does not run: $t"; return 1; }
  done
  return 0
}

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
