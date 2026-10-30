#!/bin/sh
# Builds Claude Cache.app (a universal binary, Apple silicon + Intel, with the
# scanner inside it) into build/.
#   ./build.sh             build/Claude Cache.app
#   ./build.sh --install   also copy it to ~/Applications and restart it
#   ./build.sh --dmg       also pack build/Claude Cache.dmg to share
set -e
root="$(cd "$(dirname "$0")" && pwd)"
app="$root/build/Claude Cache.app"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
for arch in arm64 x86_64; do
  swiftc -O -module-name ClaudeCache -target "$arch-apple-macos13.0" \
    "$root"/Sources/ClaudeCache/*.swift -o "$work/ClaudeCache-$arch" 2>&1 | grep -v warning || true
done
lipo -create "$work/ClaudeCache-arm64" "$work/ClaudeCache-x86_64" -output "$app/Contents/MacOS/ClaudeCache"
cp "$root/Sources/claude_cache_watch.py" "$app/Contents/Resources/"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Cache</string>
  <key>CFBundleDisplayName</key><string>Claude Cache</string>
  <key>CFBundleIdentifier</key><string>local.claude-cache-bar</string>
  <key>CFBundleExecutable</key><string>ClaudeCache</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu bar only: no Dock icon, no app menu. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS runs a locally built app without complaint.
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "Built $app"

if [ "$1" = "--install" ]; then
  osascript -e 'quit app "Claude Cache"' >/dev/null 2>&1 || true
  pkill -x ClaudeCache 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Claude Cache.app"
  cp -R "$app" "$HOME/Applications/"
  open "$HOME/Applications/Claude Cache.app"
  echo "Installed ~/Applications/Claude Cache.app"
fi

if [ "$1" = "--dmg" ]; then
  stage="$work/dmg"
  mkdir -p "$stage"
  cp -R "$app" "$stage/"
  ln -s /Applications "$stage/Applications"
  cat > "$stage/Read me.txt" <<'TXT'
Claude Cache — a menu bar app for Claude's prompt cache and token use.
https://github.com/romeJG/claude-cache

Install
  1. Drag "Claude Cache" onto Applications.
  2. Open it from Applications. It isn't notarized, so the first time macOS
     will refuse: open System Settings › Privacy & Security, scroll down and
     click "Open Anyway" next to Claude Cache, then open it again.
     (Or in Terminal: xattr -dr com.apple.quarantine "/Applications/Claude Cache.app")
  3. It appears in the menu bar (🔥 / ⏳ / 🧊). Click it for the details.
     Turn on "Open at Login" in its menu to start it with your Mac.

Needs
  - macOS 13 or later.
  - Python 3 at /usr/bin/python3 (part of the Command Line Tools: if it's
    missing, run  xcode-select --install  in Terminal).
  - Claude Code or the Claude app on this Mac: it reads their conversation logs
    in ~/.claude/projects and ~/Library/Application Support/Claude. Nothing is
    sent anywhere.
TXT
  dmg="$root/build/Claude Cache.dmg"
  rm -f "$dmg"
  hdiutil create -volname "Claude Cache" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
  echo "Packed $dmg"
fi
