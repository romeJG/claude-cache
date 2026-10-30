// Claude Cache: a menu bar app for keeping Claude's token use down.
//
// The data comes from claude_cache_watch.py --json (bundled in the app), which reads the
// conversation logs on this Mac; this app only displays it. The bar shows the
// latest conversation's cache time left. The menu answers, top to bottom:
//   - Today: how much of the input came from the cache, and what went cold.
//   - Is this conversation's cache warm? (ring + timeline of replies and the warm window)
//   - What fills its context? (the same rows as Claude Code's Context panel)
//   - What are the biggest single things in it, and what would save tokens?
//   - The other recent conversations, each with its context size (tap one to inspect it).
//
// Build:  ./build.sh --install   (see README.md). This file only starts the app.

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // menu bar only, no Dock icon
app.run()
