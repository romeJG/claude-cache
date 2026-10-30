// The data the menu shows (decoded from claude_cache_watch.py --json), the shared
// store, colours and number formatting.

import SwiftUI

struct Part: Decodable {
    let key: String
    let label: String
    let tokens: Int
}

struct Item: Decodable {
    let label: String
    let tokens: Int
}

/// What filled the context on the latest request (claude_cache_watch.py's breakdown).
struct Context: Decodable {
    let used: Int
    let window: Int
    let autocompact: Int
    let exact: Bool
    let parts: [Part]
    let messages: [Part]
    let groups: [Item]
    let top: [Item]

    var free: Int { max(0, window - used - autocompact) }
    func share(_ n: Int) -> Double { window > 0 ? Double(n) / Double(window) : 0 }
}

struct Conversation: Decodable, Identifiable {
    let id: String         // log file name
    let title: String
    let project: String
    let cwd: String?       // the folder Claude Code ran in
    let resumable: Bool?   // a Claude Code log `claude --resume` can open (not Cowork)
    let when: Double       // unix time of the last reply
    let ttl: Double        // cache lifetime in seconds (300 or 3600)
    let cached: Int        // tokens the last reply read from the cache
    let replies: [Double]? // reply times in the hour up to the last one
    let context: Context?
    let tips: [String]?

    func secondsLeft(at now: Date) -> Double { ttl - (now.timeIntervalSince1970 - when) }
}

/// Totals since midnight across every conversation on this Mac.
struct Today: Decodable {
    let replies, input, written, read, output: Int
    let restarts, restart_tokens, compactions, conversations: Int

    /// Share of input tokens served from the cache (cheap) rather than sent fresh or written.
    var hitRate: Double {
        let all = read + written + input
        return all > 0 ? Double(read) / Double(all) : 0
    }
}

/// One of the plan's usage windows (5-hour session, the week, …), as /usage shows it.
struct LimitWindow: Decodable {
    let key: String
    let label: String
    let used: Double       // percent of the window's allowance
    let resets: Double?    // unix time it resets

    var isWeekly: Bool { key.hasPrefix("seven_day") }
}

struct Limits: Decodable {
    let windows: [LimitWindow]?
    let plan: String?
    let error: String?
    let fetched: Double?   // when Anthropic last answered
}

struct Scan: Decodable {
    let conversations: [Conversation]
    let today: Today
    let tips: [String]
    let limits: Limits?
}

let warnSeconds: Double = 20 * 60  // ⏳ from here down
let scanEvery: TimeInterval = 5
let timelineSpan: Double = 60 * 60 // each half of the timeline: the past hour, the next hour
/// The scanner, copied into the app bundle's Resources by build.sh.
let watcher = Bundle.main.path(forResource: "claude_cache_watch", ofType: "py")
    ?? (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/claude_cache_watch.py"

enum CacheState {
    case hot, low, cold
    init(left: Double) { self = left <= 0 ? .cold : left < warnSeconds ? .low : .hot }
    var emoji: String { switch self { case .hot: "🔥"; case .low: "⏳"; case .cold: "🧊" } }
}

/// What the menu bar says: only what wants attention, so it can be ignored when quiet.
///   the cache  — the warm conversation closest to going cold ("🔥 58m", "⏳ 4m"),
///                "⟳" while one compacts, "🧊" when none is warm
///   the limits — the fullest usage window, from 60% ("5h 72%"), alarming from 85%
/// Nothing warm and limits fine: just a dimmed 🧊.
struct StatusTitle {
    var cache: String
    var limit: String? = nil
    var alarm = false       // the limit is nearly used up
    var quiet = false       // nothing to act on
    var tooltip = ""

    static let limitShown = 60.0
    static let limitAlarm = 85.0

    init(conversations: [Conversation], limits: Limits?, jobs: [String: Job], now: Date) {
        let warm = conversations
            .map { ($0, $0.secondsLeft(at: now)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 < $1.1 }
        let time = { (d: Double) in Date(timeIntervalSince1970: d).formatted(date: .omitted, time: .shortened) }

        if jobs.values.contains(.running) {
            cache = "⟳"
        } else if let (_, left) = warm.first {
            cache = "\(CacheState(left: left).emoji) \(Int(ceil(left / 60)))m"
        } else {
            cache = CacheState.cold.emoji
        }

        let fullest = (limits?.windows ?? []).max { $0.used < $1.used }
        if let fullest, fullest.used >= Self.limitShown {
            let name = fullest.key == "five_hour" ? "5h" : fullest.key.hasSuffix("opus") ? "Opus" : "week"
            limit = "\(name) \(Int(fullest.used.rounded()))%"
            alarm = fullest.used >= Self.limitAlarm
        }
        quiet = warm.isEmpty && limit == nil && cache == CacheState.cold.emoji

        var lines = warm.map { c, left in
            "\(CacheState(left: left).emoji) \(c.title) — warm until \(time(c.when + c.ttl))"
        }
        if lines.isEmpty { lines.append("No conversation's cache is warm") }
        for w in limits?.windows ?? [] {
            lines.append("\(w.label): \(Int(w.used.rounded()))% used" + (w.resets.map { ", resets \(time($0))" } ?? ""))
        }
        tooltip = lines.joined(separator: "\n")
    }
}

/// Text and surface colours. The menu is see-through glass, and SwiftUI's
/// .secondary/.tertiary blend with whatever is behind it, so the panel paints its
/// own solid background and every colour here is explicit and checked against it
/// (body text ≥ 7:1, small print ≥ 4.5:1 in both modes).
struct Ink {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }
    var panel: Color { dark ? Color(white: 0.13) : Color(white: 0.985) }
    var primary: Color { dark ? Color(white: 0.96) : Color(white: 0.08) }
    var secondary: Color { dark ? Color(white: 0.76) : Color(white: 0.30) }
    var faint: Color { dark ? Color(white: 0.64) : Color(white: 0.40) }
    var surface: Color { dark ? Color(white: 0.19) : Color(white: 0.93) }
    var track: Color { dark ? Color(white: 0.30) : Color(white: 0.82) }
    /// One colour per context part, as in Claude Code's Context panel.
    func part(_ key: String) -> Color {
        switch key {
        case "messages": Color(red: 0.31, green: 0.55, blue: 0.95)
        case "tools": Color(red: 0.88, green: 0.40, blue: 0.24)
        case "mcp": Color(red: 0.25, green: 0.68, blue: 0.47)
        case "memory": Color(red: 0.86, green: 0.60, blue: 0.16)
        case "skills": Color(red: 0.64, green: 0.47, blue: 0.90)
        case "system": dark ? Color(white: 0.66) : Color(white: 0.52)
        case "autocompact": dark ? Color(white: 0.40) : Color(white: 0.68)
        default: track
        }
    }
    /// How close a usage window is to its limit: fine, getting there, nearly out.
    func usage(_ percent: Double) -> Color {
        percent >= 85 ? (dark ? Color(red: 1.0, green: 0.45, blue: 0.42) : Color(red: 0.80, green: 0.15, blue: 0.12))
            : percent >= 60 ? tint(.low)
            : part("mcp")
    }
    /// Status colours tuned for each mode: bright on dark, deeper on light.
    func tint(_ state: CacheState) -> Color {
        switch state {
        case .hot: dark ? Color(red: 1.0, green: 0.62, blue: 0.25) : Color(red: 0.86, green: 0.40, blue: 0.0)
        case .low: dark ? Color(red: 1.0, green: 0.84, blue: 0.25) : Color(red: 0.80, green: 0.60, blue: 0.0)
        case .cold: dark ? Color(red: 0.45, green: 0.80, blue: 1.0) : Color(red: 0.10, green: 0.50, blue: 0.80)
        }
    }
}

/// Run `work` on the main thread soon, even while the menu is open. An open menu
/// runs the main run loop in its event-tracking mode, which never drains the main
/// dispatch queue: `DispatchQueue.main.async` would wait until the menu closes.
func onMain(_ work: @escaping () -> Void) {
    CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, work)
    CFRunLoopWakeUp(CFRunLoopGetMain())
}

func clock(_ seconds: Double) -> String {
    let s = Int(abs(seconds))
    return String(format: "%d:%02d", s / 60, s % 60)
}

final class Store: ObservableObject {
    @Published var conversations: [Conversation] = []
    @Published var today: Today?
    @Published var limits: Limits?
    @Published var dayTips: [String] = []
    @Published var error: String?
    @Published var lastScan: Date?
    /// The conversation shown in full; the latest one unless you picked another.
    @Published var selected: String?
    /// How far the bars have grown in since the menu opened, 0 → 1. Set by the app
    /// delegate (a view inside a closed menu doesn't update, so it can't reset itself).
    @Published var reveal: CGFloat = 1

    var focus: Conversation? { conversations.first { $0.id == selected } ?? conversations.first }
    /// Compactions started from the menu, by conversation id.
    @Published var jobs: [String: Job] = [:]
    /// The conversation whose Compact button was tapped once and waits for a second tap.
    @Published var armed: (id: String, at: Date)?
}

enum Job: Equatable {
    case running
    case done
    case failed(String)
}

func tokens(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000)
        : n >= 1_000 ? String(format: "%.1fk", Double(n) / 1_000) : "\(n)"
}

func percent(_ x: Double) -> String {
    x >= 0.1 || x == 0 ? String(format: "%.0f%%", x * 100) : String(format: "%.1f%%", x * 100)
}

