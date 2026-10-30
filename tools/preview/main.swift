// Renders the menu to PNGs without running the app — for screenshots and for
// checking a design change. Built by tools/preview.sh together with the app's
// Model.swift and MenuView.swift.
//
// Usage: preview <scan.json> <out-prefix> [index of the conversation to inspect] [--collapsed] [--reveal 0.4]
// --reveal draws one frame of the grow-in animation (0 = just opened, 1 = done).
// <scan.json> is `claude_cache_watch.py --json` output, or tools/demo.json, whose
// times are seconds before now (negative), so the demo always looks current.

import AppKit
import SwiftUI

let args = CommandLine.arguments
var json = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as! [String: Any]
let now = Date().timeIntervalSince1970
if var conversations = json["conversations"] as? [[String: Any]] {
    for i in conversations.indices {
        if let when = conversations[i]["when"] as? Double, when < 1_000_000_000 {
            conversations[i]["when"] = now + when
            conversations[i]["replies"] = (conversations[i]["replies"] as? [Double] ?? []).map { now + $0 }
        }
    }
    json["conversations"] = conversations
}
// Demo limits use times relative to now, too.
if var limits = json["limits"] as? [String: Any], var windows = limits["windows"] as? [[String: Any]] {
    for i in windows.indices {
        if let resets = windows[i]["resets"] as? Double, resets < 1_000_000_000 { windows[i]["resets"] = now + resets }
    }
    limits["windows"] = windows
    if let fetched = limits["fetched"] as? Double, fetched < 1_000_000_000 { limits["fetched"] = now + fetched }
    json["limits"] = limits
}
let scanned = try! JSONDecoder().decode(Scan.self, from: JSONSerialization.data(withJSONObject: json))
let prefix = args[2]
let pick = args.count > 3 ? Int(args[3]) ?? 0 : 0
let collapsed = args.contains("--collapsed")

for key in ["today", "context", "messages", "biggest", "tips", "recent"] {
    UserDefaults.standard.removeObject(forKey: "open." + key)
}
if collapsed {
    for key in ["today", "context", "biggest", "tips", "recent"] { UserDefaults.standard.set(false, forKey: "open." + key) }
} else {
    UserDefaults.standard.set(true, forKey: "open.messages")
}

let store = Store()
store.conversations = scanned.conversations
store.today = scanned.today
store.limits = scanned.limits
store.dayTips = scanned.tips
store.selected = scanned.conversations.indices.contains(pick) ? scanned.conversations[pick].id : nil
store.lastScan = Date().addingTimeInterval(-2)
if let i = args.firstIndex(of: "--reveal"), i + 1 < args.count, let reveal = Double(args[i + 1]) {
    store.reveal = reveal
}

MainActor.assumeIsolated {
    for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
        // A busy backdrop, like the see-through menu over a desktop.
        let view = CacheMenu(store: store, maxHeight: 4000)
            .environment(\.colorScheme, scheme)
            .background(LinearGradient(colors: [Color(white: 0.55).opacity(0.8), .blue.opacity(0.6), Color(white: 0.5).opacity(0.7)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let rep = NSBitmapImageRep(data: renderer.nsImage!.tiffRepresentation!)!
        let out = "\(prefix)-\(name).png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
        print(out)
    }
}
