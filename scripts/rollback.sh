#!/usr/bin/env bash
#
# rollback.sh - restore the original (glibc 2.28) ZCode runtime binaries.
#
set -euo pipefail

RUNTIME_ROOT="${ZCODE_RUNTIME_ROOT:-$HOME/.zcode/server}"
BACKUP_SUFFIX=".official-glibc228.bak"

log() { echo "  [INFO]  $*"; }
err() { echo "  [ERROR] $*" >&2; }

TARGETS=(
  "$RUNTIME_ROOT/node"
  "$RUNTIME_ROOT/build/Release/pty.node"
  "$RUNTIME_ROOT/tools/bfs/bfs"
  "$RUNTIME_ROOT/tools/ugrep/ugrep"
)

RESTORED=0
for target in "${TARGETS[@]}"; do
  backup="$target$BACKUP_SUFFIX"
  if [ -f "$backup" ]; then
    install -m 0755 "$backup" "$target"
    log "restored $target from $backup"
    RESTORED=$((RESTORED + 1))
  else
    log "no backup for $target (nothing to restore)"
  fi
done

if [ "$RESTORED" -eq 0 ]; then
  err "no backups found under $RUNTIME_ROOT - nothing was restored"
  exit 1
fi

log "done - the runtime is back to the official binaries (they need glibc 2.28, so the remote will fail again on this host)"
