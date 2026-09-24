#!/usr/bin/env bash
#
# verify.sh - assert that the patched ZCode remote runtime is usable on this host.
#
set -euo pipefail

RUNTIME_ROOT="${ZCODE_RUNTIME_ROOT:-$HOME/.zcode/server}"
GLIBC_CEILING="${ZCL_GLIBC_CEILING:-2.17}"
GLIBCXX_CEILING="${ZCL_GLIBCXX_CEILING:-3.4.19}"

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

check_binary() {  # id path expected_version
  local id="$1" path="$2" expect="${3:-}"
  [ -f "$path" ] || { bad "$id: missing $path"; return; }
  [ -x "$path" ] || { bad "$id: not executable: $path"; return; }

  local glibc glibcxx
  glibc="$(max_symbol "$path" 'GLIBC_2\.[0-9]+(\.[0-9]+)?')"
  glibcxx="$(max_symbol "$path" '(GLIBCXX|CXXABI)_[0-9.]+')"

  if [ "$glibc" = "none" ]; then
    log "$id: statically linked (no GLIBC symbols)"
  elif version_le "${glibc#GLIBC_}" "$GLIBC_CEILING"; then
    ok "$id: glibc ceiling $glibc <= $GLIBC_CEILING"
  else
    bad "$id: requires $glibc > $GLIBC_CEILING"
  fi

  if [ "$id" = "node-runtime" ] && [ "$glibcxx" != "none" ]; then
    version_le "${glibcxx#GLIBCXX_}" "$GLIBCXX_CEILING" \
      && ok "$id: libstdc++ ceiling $glibcxx <= $GLIBCXX_CEILING" \
      || bad "$id: requires $glibcxx > $GLIBCXX_CEILING"
  fi

  if [ -n "$expect" ]; then
    log "$id: desktop expects '$expect'"
  fi
}

marker_version() {  # id
  case "$1" in
    node-runtime) sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$RUNTIME_ROOT/.asset-components/node-runtime.json" 2>/dev/null | head -n1 ;;
    node-pty)     sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$RUNTIME_ROOT/.asset-components/node-pty.json" 2>/dev/null | head -n1 ;;
    bfs)          tr -d ' \t\r\n' < "$RUNTIME_ROOT/tools/bfs/.version" 2>/dev/null || true ;;
    ugrep)        tr -d ' \t\r\n' < "$RUNTIME_ROOT/tools/ugrep/.version" 2>/dev/null || true ;;
    ripgrep)      tr -d ' \t\r\n' < "$RUNTIME_ROOT/tools/ripgrep/.version" 2>/dev/null || true ;;
  esac
}

NODE="$RUNTIME_ROOT/node"
PTY="$RUNTIME_ROOT/build/Release/pty.node"
BFS="$RUNTIME_ROOT/tools/bfs/bfs"
UGREP="$RUNTIME_ROOT/tools/ugrep/ugrep"
RG="$RUNTIME_ROOT/tools/ripgrep/rg"

echo "== binaries =="
check_binary node-runtime "$NODE" "$(marker_version node-runtime)"
check_binary node-pty     "$PTY"  "$(marker_version node-pty)"
check_binary bfs          "$BFS"  "$(marker_version bfs)"
check_binary ugrep        "$UGREP" "$(marker_version ugrep)"
check_binary ripgrep      "$RG"   "$(marker_version ripgrep)"

echo "== node runtime =="
if [ -x "$NODE" ]; then
  v="$("$NODE" -v 2>/dev/null || true)"
  [ -n "$v" ] && ok "node -v -> $v" || bad "node cannot run"
  sb="$RUNTIME_ROOT/zcode-server.cjs"
  if [ -f "$sb" ]; then
    sv="$(timeout 60 "$NODE" "$sb" --version 2>/dev/null | tr -d '\r\n' || true)"
    [ -n "$sv" ] && ok "zcode-server.cjs --version -> $sv" || bad "server bundle failed to start"
  fi
fi

echo "== terminal (pty.node) =="
if [ -x "$NODE" ] && [ -f "$PTY" ]; then
  if "$NODE" -e "require(process.argv[1]);" "$PTY" >/dev/null 2>&1; then
    ok "pty.node loads"
  else
    bad "pty.node failed to load: $("$NODE" -e "require(process.argv[1])" "$PTY" 2>&1 | head -n1)"
  fi
fi

echo "== tool binaries =="
for t in "$RG:$RG" "$BFS:$BFS" "$UGREP:$UGREP"; do
  bin="${t%%:*}"
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
