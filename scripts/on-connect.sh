#!/usr/bin/env bash
#
# on-connect.sh - connection-time self-heal, fired from ~/.bashrc (see install-hook.sh).
#
# Runs on every SSH exec into this host. The healthy path is two file reads (~ms). When the
# installed tree's version is older than the newest cached bundle - the state right after a
# ZCode desktop upgrade, where the desktop's own reinstall died on glibc and rolled back -
# it heals in the background: stop runtime, bootstrap the newer release (CDN fetch + the
# watchtower/hand-complete machinery in bootstrap-source-server.sh), apply the bundle,
# restart the daemon. The next desktop connect then probes a matching, ready server and
# reuses it instead of reinstalling.
#
# Concurrency: flock -n, one healer at a time; later triggers exit immediately. The desktop
# and the healer may race on one connect; convergence comes from re-checking on every
# subsequent connect.
#
set -u

KIT_DIR="${ZCL_STATE_DIR:-$HOME/.zcode/legacy-glibc}"
S="${ZCODE_RUNTIME_ROOT:-$HOME/.zcode/server}"
LOG="$KIT_DIR/on-connect.log"
LOCK="$KIT_DIR/.on-connect.lock"
REPO="${ZCL_REPO:-BD7PIL/zcode-legacy-glibc}"

log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$LOG"; }

exec 9>"$LOCK" || exit 0
flock -n 9 || exit 0 # a healer is already running for this connect burst

current_version() {
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$S/current.json" 2>/dev/null | head -n1
}

CUR="$(current_version)"
[ -n "$CUR" ] || exit 0 # no tree at all; apply.sh/bootstrap handles that path explicitly

# Desktop-paired version: the newest versioned provisioning dir the desktop has written here
# (~/.zcode/v2/runtime/provider/linux-x86_64/<ver>/, excluding the 0.0.0-dev bucket). When it
# is newer than the tree, the desktop app has just updated and its own glibc reinstall died -
# the one signal that must not sit behind the hourly GitHub throttle (2026-11-11: this wait
# cost an hour after the release was already published).
PAIRED="$(ls -1 "$HOME/.zcode/v2/runtime/provider/linux-x86_64" 2>/dev/null \
  | grep -vE '^0\.0\.0-dev$' | sort -V | tail -n1)"
PAIRED_AHEAD=""
if [ -n "$PAIRED" ] && [ "$(printf '%s\n%s\n' "$PAIRED" "$CUR" | sort -V | tail -n1)" = "$PAIRED" ] && [ "$PAIRED" != "$CUR" ]; then
  PAIRED_AHEAD=1
fi

# newest cached bundle (zcodeVersion field of its manifest)
NEWEST=""; BUNDLE=""
for m in "$KIT_DIR"/cache/zcode-legacy-glibc-*.tar.gz; do
  [ -f "$m" ] || continue
  v="$(tar -xzOf "$m" ./manifest.json 2>/dev/null | sed -n 's/.*"zcodeVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [ -n "$v" ] || continue
  if [ -z "$NEWEST" ] || [ "$(printf '%s\n%s\n' "$NEWEST" "$v" | sort -V | tail -n1)" = "$v" ]; then
    NEWEST="$v"; BUNDLE="$m"
  fi
done

# cache empty, stale, or merely equal to the tree: check the repo's latest release (throttled
# to one query per hour - anonymous GitHub API allows 60/h). Equal counts as a candidate case:
# CI may have published a bundle for a release the cache does not hold yet.
if [ -z "$NEWEST" ] || [ "$NEWEST" = "$CUR" ] || [ "$(printf '%s\n%s\n' "$NEWEST" "$CUR" | sort -V | tail -n1)" = "$CUR" ]; then
  stamp="$KIT_DIR/.release-check.stamp"
  check=1
  if [ -z "$PAIRED_AHEAD" ] && [ -f "$stamp" ] && [ -n "$(find "$stamp" -mmin -60 2>/dev/null)" ]; then
    check=0 # checked within the last hour and the desktop has not just moved
  fi
  if [ "$check" -eq 1 ]; then
    touch "$stamp"
    tag="$(curl -fsSL --max-time 20 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
    if [ -n "$tag" ]; then
      b="zcode-legacy-glibc-$tag.tar.gz"
      dst="$KIT_DIR/cache/$b"
      if [ ! -f "$dst" ]; then
        log "fetching release $tag from GitHub (background budget: up to 20 min)"
        curl -fsSL --max-time 1200 -C - --retry 2 -o "$dst.part" \
          "https://github.com/$REPO/releases/download/$tag/$b" 2>>"$LOG" \
          && mv "$dst.part" "$dst" \
          && curl -fsSL --max-time 60 -o "$dst.sha256" \
            "https://github.com/$REPO/releases/download/$tag/$b.sha256" 2>>"$LOG" \
          || { log "fetch of $tag failed - will retry on next connect"; rm -f "$dst.part" "$stamp"; exit 0; }
        exp="$(tr -d ' \t\r\n' < "$dst.sha256" 2>/dev/null | grep -oE '^[0-9a-f]{64}')"
        act="$(sha256sum "$dst" 2>/dev/null | awk '{print $1}')"
        [ -n "$exp" ] && [ "$exp" = "$act" ] || { log "sha mismatch for $tag - removing"; rm -f "$dst" "$dst.sha256"; exit 0; }
        log "cached $tag"
      fi
      NEWEST="$(tar -xzOf "$dst" ./manifest.json 2>/dev/null | sed -n 's/.*"zcodeVersion"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
      BUNDLE="$dst"
    fi
  fi
fi

[ -n "$NEWEST" ] || exit 0

# Version pairing cap: upgrade only to what the desktop pairs with (PAIRED, computed above).
# Chasing the CDN's newest server release without this cap once upgraded a remote to 3.18.0
# that the desktop 3.17.2 refused to talk to (2026-11-11).
if [ -n "$PAIRED" ] && [ "$(printf '%s\n%s\n' "$NEWEST" "$PAIRED" | sort -V | tail -n1)" = "$NEWEST" ] && [ "$NEWEST" != "$PAIRED" ]; then
  log "WARN bundle $NEWEST exceeds desktop-paired server $PAIRED - refusing to overtake the desktop; waiting for the desktop app to move"
  printf 'ZCL_SERVER_VERSION=%s\nZCL_BUNDLE_VERSION=%s\nZCL_DESKTOP_PAIRED=%s\nZCL_MISMATCH_AT=%s\n' \
    "$CUR" "$NEWEST" "$PAIRED" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$KIT_DIR/anchor-mismatch.env"
  exit 0
fi
rm -f "$KIT_DIR/anchor-mismatch.env"
if [ "$NEWEST" = "$CUR" ]; then
  exit 0 # healthy - versions match
fi
if [ "$(printf '%s\n%s\n' "$NEWEST" "$CUR" | sort -V | tail -n1)" != "$NEWEST" ]; then
  # The server auto-upgraded past the newest bundle we hold (CI lag). The tree still runs -
  # the desktop's failed reinstall rolled back - but nothing to heal with yet. Report it
  # instead of passing silently (verify.sh surfaces this), and retry on later connects.
  log "WARN server $CUR is newer than newest bundle $NEWEST - waiting for CI to publish"
  printf 'ZCL_SERVER_VERSION=%s\nZCL_BUNDLE_VERSION=%s\nZCL_MISMATCH_AT=%s\n' \
    "$CUR" "$NEWEST" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$KIT_DIR/anchor-mismatch.env"
  exit 0
fi
rm -f "$KIT_DIR/anchor-mismatch.env"

# ---------------------------------------------------------------- heal (background, locked)
# If the desktop's own bootstrap is in flight (it stages under .bootstrap-*), do not race it:
# both sides end up writing current.json and the desktop side always dies on glibc anyway.
# The desktop prunes stale staging dirs itself, so any dir here means a live attempt - defer,
# the next connect re-checks.
if ls "$S"/.bootstrap-* >/dev/null 2>&1; then
  log "desktop bootstrap staging present - deferring heal to avoid a current.json write race"
  exit 0
fi
log "tree is $CUR, bundle $NEWEST available - healing"
pkill -f "$S/releases" 2>/dev/null && sleep 1

LEGACY="$(sed -n 's/.*"releaseDir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$S/current.json")/runtime/node"
if bash "$KIT_DIR/scripts/bootstrap-source-server.sh" --zcode-version "$NEWEST" --node "$LEGACY" >>"$LOG" 2>&1; then
  log "bootstrapped $NEWEST"
else
  log "bootstrap for $NEWEST failed - will retry on next connect"
  exit 1
fi

if bash "$KIT_DIR/scripts/apply.sh" --bundle "$BUNDLE" >>"$LOG" 2>&1; then
  log "applied $(basename "$BUNDLE")"
else
  log "apply failed - will retry on next connect"
  exit 1
fi

pkill -f "$S/releases" 2>/dev/null; sleep 1
rm -f "$S/run/server.lock" "$S/run/control.sock"
"$S/bin/zcode" serve --daemon --json --server-root "$S" >>"$LOG" 2>&1
# 'healed' is only true when the daemon actually came up on the new version - serve can fail
# (bad identity, port, ...) and status.json can be stale, so check both fields.
sleep 3
state="$(sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$S/run/status.json" 2>/dev/null | head -n1)"
ver="$(current_version)"
if [ "$state" = "ready" ] && [ "$ver" = "$NEWEST" ]; then
  log "healed: $ver ready"
else
  log "heal incomplete: daemon state=${state:-none} version=${ver:-none} (wanted $NEWEST) - will retry on next connect"
  exit 1
fi
