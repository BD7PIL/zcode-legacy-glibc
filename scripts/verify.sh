#!/usr/bin/env bash
#
# verify.sh - assert that the patched ZCode remote runtime is usable on this host.
#
set -euo pipefail

RUNTIME_ROOT="${ZCODE_RUNTIME_ROOT:-$HOME/.zcode/server}"
GLIBC_CEILING="${ZCL_GLIBC_CEILING:-2.17}"
GLIBCXX_CEILING="${ZCL_GLIBCXX_CEILING:-3.4.19}"
BACKUP_SUFFIX=".official-glibc228.bak"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=layout.sh
. "$SCRIPT_DIR/layout.sh"

FAILED=0

log()  { echo "  [INFO]  $*"; }
ok()   { echo "  [ OK ]  $*"; }
bad()  { echo "  [FAIL]  $*"; FAILED=1; }

# Compare dotted versions: version_le A B -> true when A <= B
version_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$2" ]; }

max_symbol() {  # file pattern
  local out
  out="$(objdump -T "$1" 2>/dev/null | grep -oE "$2" | sort -Vu | tail -n1 || true)"
  echo "${out:-none}"
}

check_binary() {  # id path
  local id="$1" path="$2"
  [ -f "$path" ] || { bad "$id: missing $path"; return; }
  [ -x "$path" ] || { bad "$id: not executable: $path"; return; }

  local glibc glibcxx
  glibc="$(max_symbol "$path" 'GLIBC_2\.[0-9]+(\.[0-9]+)?')"
  glibcxx="$(max_symbol "$path" '(GLIBCXX|CXXABI)_[0-9.]+')"

  if [ "$glibc" = "none" ]; then
    log "$id: statically linked (no GLIBC symbols)"
  elif version_le "${glibc#GLIBC_}" "$GLIBC_CEILING"; then
    ok "$id: glibc ceiling $glibc <= $GLIBC_CEILING"
  elif [ -f "$path$BACKUP_SUFFIX" ]; then
    bad "$id: requires $glibc > $GLIBC_CEILING (replacement did not take effect?)"
  else
    warn "$id: still the official build (requires $glibc) - expected when the bundle has no replacement for it"
  fi

  if [ "$id" = "node-runtime" ] && [ "$glibcxx" != "none" ]; then
    version_le "${glibcxx#GLIBCXX_}" "$GLIBCXX_CEILING" \
      && ok "$id: libstdc++ ceiling $glibcxx <= $GLIBCXX_CEILING" \
      || bad "$id: requires $glibcxx > $GLIBCXX_CEILING"
  fi
}

LAYOUT="$(runtime_layout "$RUNTIME_ROOT")"
[ "$LAYOUT" != "none" ] || { echo "  [ERROR] no runtime found at $RUNTIME_ROOT" >&2; exit 1; }
log "layout: $LAYOUT"

RD=""
if [ "$LAYOUT" = "new" ]; then
  RD="$(release_dir "$RUNTIME_ROOT")"
  [ -n "$RD" ] || { echo "  [ERROR] current.json has no releaseDir" >&2; exit 1; }
fi

NODE="$(component_path "$RUNTIME_ROOT" "$LAYOUT" node-runtime)"
PTY="$(component_path "$RUNTIME_ROOT" "$LAYOUT" node-pty)"
BFS="$(component_path "$RUNTIME_ROOT" "$LAYOUT" bfs)"
UGREP="$(component_path "$RUNTIME_ROOT" "$LAYOUT" ugrep)"
RG="$(component_path "$RUNTIME_ROOT" "$LAYOUT" ripgrep)"
KOFFI="$(component_path "$RUNTIME_ROOT" "$LAYOUT" koffi)"

echo "== binaries =="
check_binary node-runtime "$NODE"
check_binary node-pty     "$PTY"
check_binary bfs          "$BFS"
check_binary ugrep        "$UGREP"
check_binary ripgrep      "$RG"
[ -n "$KOFFI" ] && [ -f "$KOFFI" ] && check_binary koffi "$KOFFI"

echo "== node runtime =="
if [ -x "$NODE" ]; then
  v="$("$NODE" -v 2>/dev/null || true)"
  [ -n "$v" ] && ok "node -v -> $v" || bad "node cannot run"
  if [ "$LAYOUT" = "new" ]; then
    sv="$(timeout 60 "$RUNTIME_ROOT/bin/zcode" --version 2>/dev/null | tr -d '\r\n' || true)"
    [ -n "$sv" ] && ok "bin/zcode --version -> $sv" || bad "bin/zcode failed to run"
    rt_dir="$(dirname "$NODE")"
    kv="$(cd "$rt_dir" && timeout 30 "$NODE" -e 'try{console.log("koffi "+require("koffi/package.json").version)}catch(e){console.log("KOFFI_UNAVAILABLE")}' 2>/dev/null | tr -d '\r\n' || true)"
    if [ "$kv" = "KOFFI_UNAVAILABLE" ]; then
      if [ -f "$KOFFI$BACKUP_SUFFIX" ]; then
        bad "koffi cannot be loaded (replacement broken)"
      else
        warn "koffi unavailable (official build needs glibc 2.28) - TUI-dependent features may degrade"
      fi
    elif [ -n "$kv" ]; then
      ok "$kv loads"
    fi
  else
    sb="$RUNTIME_ROOT/zcode-server.cjs"
    if [ -f "$sb" ]; then
      sv="$(timeout 60 "$NODE" "$sb" --version 2>/dev/null | tr -d '\r\n' || true)"
      [ -n "$sv" ] && ok "zcode-server.cjs --version -> $sv" || bad "server bundle failed to start"
    fi
  fi
fi

echo "== terminal (pty.node) =="
if [ -x "$NODE" ] && [ -f "$PTY" ]; then
  if "$NODE" -e "require(process.argv[1]);" "$PTY" >/dev/null 2>&1; then
    ok "pty.node loads"
  else
    bad "pty.node failed to load: $("$NODE" -e "require(process.argv[1])" "$PTY" 2>&1 | head -n1)"
  fi
  pty_js="$(dirname "$NODE")/node_modules/node-pty"
  if [ -d "$pty_js" ]; then
    out="$(cd "$pty_js/.." && timeout 20 "$NODE" -e '
const pty=require("node-pty");
const p=pty.spawn("/bin/sh",["-c","echo PTY_OK"],{name:"xterm",cols:80,rows:24,cwd:"/tmp"});
let buf="";p.onData(d=>buf+=d);
p.onExit(()=>{process.stdout.write(buf.includes("PTY_OK")?"spawn-ok":"spawn-no-echo");process.exit(0)});
setTimeout(()=>{process.stdout.write("spawn-timeout");process.exit(1)},8000);
' 2>/dev/null | tr -d '\r\n' || true)"
    [ "$out" = "spawn-ok" ] && ok "pty spawn -> real /dev/pts works" || bad "pty spawn: ${out:-no output}"
  fi
fi

echo "== tool binaries =="
for bin in "$RG" "$BFS" "$UGREP"; do
  [ -x "$bin" ] || continue
  out="$("$bin" --version 2>&1 | head -n1 || true)"
  [ -n "$out" ] && ok "$(basename "$bin"): $out" || bad "$(basename "$bin") --version produced no output"
done

echo
if [ "$FAILED" -eq 0 ]; then
  echo "  [INFO]  all checks passed"
else
  echo "  [ERROR] one or more checks failed" >&2
  exit 1
fi
