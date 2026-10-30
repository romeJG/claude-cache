#!/bin/sh
# Renders the menu to PNGs (light and dark) without running the app.
#   tools/preview.sh                      the made-up demo data → build/preview-*.png
#   tools/preview.sh --live               your own conversations right now
#   tools/preview.sh --collapsed          every section closed
#   tools/preview.sh --pick 1             inspect the second conversation
set -e
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build"
data="$root/tools/demo.json"
pick=0
extra=""
while [ $# -gt 0 ]; do
  case "$1" in
    --live) /usr/bin/python3 -I "$root/Sources/claude_cache_watch.py" --json > "$root/build/live.json"; data="$root/build/live.json" ;;
    --collapsed) extra="--collapsed" ;;
    --pick) shift; pick="$1" ;;
  esac
  shift
done
swiftc -O -module-name ClaudeCache \
  "$root/Sources/ClaudeCache/Model.swift" "$root/Sources/ClaudeCache/MenuView.swift" \
  "$root/tools/preview/main.swift" -o "$root/build/preview" 2>&1 | grep -v warning || true
"$root/build/preview" "$data" "$root/build/preview" "$pick" $extra
