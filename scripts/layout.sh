#!/usr/bin/env bash
#
# layout.sh - shared ZCode remote-runtime layout detection (sourced, not executed).
#
# Two layouts exist:
#
#   new  "source server" (ZCode desktop >= 3.16): $ROOT/bin/zcode + $ROOT/current.json,
#        binaries live inside $ROOT/releases/<releaseId>/runtime/...
#   old  "component assets" (ZCode desktop <= 3.15): node + zcode-server.cjs at $ROOT,
#        version markers in $ROOT/.asset-components/*.json and tools/*/.version
#

# runtime_layout [root] -> "new" | "old" | "none"
runtime_layout() {
  local root="${1:-${ZCODE_RUNTIME_ROOT:-$HOME/.zcode/server}}"
  if [ -f "$root/bin/zcode" ] && [ -f "$root/current.json" ]; then
    echo new
  elif [ -d "$root/.asset-components" ] || [ -f "$root/node" ]; then
    echo old
  else
    echo none
  fi
}

# release_dir [root] -> absolute releaseDir from current.json (new layout; empty otherwise)
release_dir() {
  local root="${1:-${ZCODE_RUNTIME_ROOT:-$HOME/.zcode/server}}"
  [ -f "$root/current.json" ] || return 0
  sed -n 's/.*"releaseDir"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$root/current.json" | head -n1
}

# component_path <root> <layout> <id> -> absolute path of a replaceable binary (empty when N/A)
component_path() {
  local root="$1" layout="$2" id="$3" rd
  if [ "$layout" = "new" ]; then
    rd="$(release_dir "$root")"
    [ -n "$rd" ] || return 0
    case "$id" in
      node-runtime) echo "$rd/runtime/node" ;;
      node-pty)     echo "$rd/runtime/node_modules/node-pty/prebuilds/linux-x64/pty.node" ;;
      koffi)        echo "$rd/runtime/node_modules/koffi/build/koffi/linux_x64/koffi.node" ;;
      bfs)          echo "$rd/runtime/tools/bfs/bfs" ;;
      ugrep)        echo "$rd/runtime/tools/ugrep/ugrep" ;;
      ripgrep)      echo "$rd/runtime/tools/ripgrep/rg" ;;
    esac
  else
    case "$id" in
      node-runtime) echo "$root/node" ;;
      node-pty)     echo "$root/build/Release/pty.node" ;;
      bfs)          echo "$root/tools/bfs/bfs" ;;
      ugrep)        echo "$root/tools/ugrep/ugrep" ;;
      ripgrep)      echo "$root/tools/ripgrep/rg" ;;
    esac
  fi
}

# json_field <file> <key> -> first string value of "key" in a (small) JSON file
json_field() {
  sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n1
}
