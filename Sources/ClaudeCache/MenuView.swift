// The menu's content: one SwiftUI view hosted inside the status item's NSMenu.

import SwiftUI

// MARK: - Motion
//
// Every open, the bars, rings and charts grow from nothing to their values
// (`Store.reveal`, 0 → 1, driven by AppDelegate); sections fold open and closed; the ring drains smoothly
// between the once-a-second updates; numbers roll to their new values; and two
// things that want action breathe: a cache about to go cold, a limit nearly used
// up. "Reduce motion" in System Settings turns all of it off.

private struct RevealKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    /// How far the bars have grown in since the menu opened, 0 → 1.
    var reveal: CGFloat {
        get { self[RevealKey.self] }
        set { self[RevealKey.self] = newValue }
    }
}

extension View {
    /// Digits roll to a new value (macOS 14 and later; a plain change before).
    @ViewBuilder func rolling<V: Equatable>(_ value: V) -> some View {
        if #available(macOS 14.0, *) {
            contentTransition(.numericText()).animation(.easeOut(duration: 0.35), value: value)
        } else {
            self
        }
    }

    /// A slow breathing while `active`.
    func pulse(_ active: Bool) -> some View { modifier(Pulse(active: active)) }
}

struct Pulse: ViewModifier {
    let active: Bool
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.4 : 1)
            .onAppear { update() }
            .onChange(of: active) { _ in update() }
    }

    func update() {
        if active && !reduceMotion {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { dim = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { dim = false }
        }
    }
}

struct CacheMenu: View {
    @ObservedObject var store: Store
    @Environment(\.colorScheme) var scheme

    /// Taller than this and the content scrolls (the menu can't be taller than the screen).
    var maxHeight: CGFloat = 800
    // Which sections are open, remembered between launches.
    @AppStorage("open.limits") var openLimits = true
    @AppStorage("open.today") var openToday = true
    @AppStorage("open.context") var openContext = true
    @AppStorage("open.messages") var openMessages = false
    @AppStorage("open.biggest") var openBiggest = false
    @AppStorage("open.tips") var openTips = true
    @AppStorage("open.recent") var openRecent = true

    var body: some View {
        let ink = Ink(scheme)
        TimelineView(.periodic(from: .now, by: 1)) { context in
            ViewThatFits(in: .vertical) {
                content(now: context.date, ink: ink)
                ScrollView { content(now: context.date, ink: ink) }
            }
            .frame(width: 404)
            .frame(maxHeight: maxHeight)
            .background(RoundedRectangle(cornerRadius: 12).fill(ink.panel))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .environment(\.reveal, store.reveal)
    }

    func content(now: Date, ink: Ink) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Header(conversations: store.conversations, now: now, ink: ink)
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if store.conversations.isEmpty {
                Text("No conversations with replies yet").font(.callout).foregroundStyle(ink.secondary)
            }
            if let limits = store.limits {
                LimitsStrip(limits: limits, now: now, ink: ink, expanded: $openLimits)
            }
            if let today = store.today {
                TodayStrip(today: today, tips: store.dayTips, ink: ink, expanded: $openToday)
            }
            if let focus = store.focus {
                VStack(alignment: .leading, spacing: 10) {
                    Card(conversation: focus, now: now, ink: ink)
                        .id(focus.id)
                        .transition(.opacity)
                    if let context = focus.context {
                        ContextPanel(context: context, ink: ink, expanded: $openContext, messagesOpen: $openMessages)
                        if !context.top.isEmpty { BiggestItems(items: context.top, ink: ink, expanded: $openBiggest) }
                    }
                    if let tips = focus.tips, !tips.isEmpty { Tips(tips: tips, ink: ink, expanded: $openTips) }
                }
            }
            if store.conversations.count > 1 {
                VStack(alignment: .leading, spacing: 2) {
                    SectionTitle("Recent conversations", ink: ink,
                                 note: openRecent ? "tap one to inspect" : "\(store.conversations.count)",
                                 expanded: $openRecent)
                    ForEach(openRecent ? store.conversations : []) { conversation in
                        ConversationRow(conversation: conversation, now: now, ink: ink,
                                        selected: conversation.id == store.focus?.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.25)) { store.selected = conversation.id }
                                onMain { resizeMenu() }
                            }
                    }
                }
            }
            if let lastScan = store.lastScan {
                Text("Checks every \(Int(scanEvery)) s · last \(max(0, Int(now.timeIntervalSince(lastScan)))) s ago · token counts are estimates fitted to each reply's real total")
                    .font(.caption2).foregroundStyle(ink.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 404, alignment: .leading)
    }
}

/// A section heading; with `expanded` it's a disclosure: tap anywhere on it to
/// open or close the section (remembered between launches).
struct SectionTitle: View {
    let title: String
    let ink: Ink
    var note: String? = nil
    var expanded: Binding<Bool>? = nil
    init(_ title: String, ink: Ink, note: String? = nil, expanded: Binding<Bool>? = nil) {
        self.title = title; self.ink = ink; self.note = note; self.expanded = expanded
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            if let expanded {
                Chevron(open: expanded.wrappedValue, ink: ink)
            }
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).kerning(0.6)
                .foregroundStyle(ink.secondary)
            Spacer()
            if let note { Text(note).font(.caption2).foregroundStyle(ink.faint).lineLimit(1) }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(expanded) }
    }
}

struct Chevron: View {
    let open: Bool
    let ink: Ink

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(ink.secondary)
            .rotationEffect(.degrees(open ? 90 : 0))
            .frame(width: 9)
    }
}

/// Flip a disclosure and refit the menu to the new height.
func toggle(_ expanded: Binding<Bool>?) {
    guard let expanded else { return }
    withAnimation(.easeInOut(duration: 0.22)) { expanded.wrappedValue.toggle() }
    onMain { resizeMenu() }
}

/// Set by the app delegate: refits the open menu to its content.
var resizeMenu: () -> Void = {}

/// The plan's 5-hour and weekly usage, from Anthropic (see claude_cache_watch.py).
struct LimitsStrip: View {
    let limits: Limits
    let now: Date
    let ink: Ink
    @Binding var expanded: Bool

    var body: some View {
        let windows = limits.windows ?? []
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Plan limits", ink: ink, note: note(windows), expanded: $expanded)
            if expanded {
                ForEach(windows, id: \.key) { LimitRow(window: $0, now: now, ink: ink) }
                if let error = limits.error {
                    Tip(text: error, icon: windows.isEmpty ? "🔑" : "⚠️", ink: ink)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(ink.surface))
    }

    func note(_ windows: [LimitWindow]) -> String? {
        if !expanded {
            let parts = windows.prefix(2).map { "\($0.isWeekly ? "week" : "5h") \(Int($0.used.rounded()))%" }
            return parts.isEmpty ? (limits.error == nil ? nil : "unavailable") : parts.joined(separator: " · ")
        }
        guard let fetched = limits.fetched else { return nil }
        let age = now.timeIntervalSince1970 - fetched
        // Asked every 3 minutes: say so only when the answer is older than that.
        return age > 600 ? "as of \(Date(timeIntervalSince1970: fetched).formatted(date: .omitted, time: .shortened))"
            : limits.plan.map { $0.capitalized + " plan" }
    }
}

struct LimitRow: View {
    @Environment(\.reveal) private var reveal
    let window: LimitWindow
    let now: Date
    let ink: Ink

    var body: some View {
        let used = min(100, max(0, window.used))
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 12, weight: .medium)).foregroundStyle(ink.primary)
                Spacer()
                Text("\(Int(used.rounded()))% used")
                    .font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(ink.primary)
                    .rolling(Int(used.rounded()))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.track)
                    Capsule().fill(ink.usage(used)).frame(width: max(3, geo.size.width * used / 100 * reveal))
                        .pulse(used >= 85)
                }
            }
            .frame(height: 6)
            if let resets = window.resets {
                Text("Resets \(resetText(resets))").font(.caption2).foregroundStyle(ink.secondary)
            }
        }
    }

    /// "in 2 h 14 min (3:30 PM)" for the session; "Thu 9:00 AM" for a week.
    func resetText(_ resets: Double) -> String {
        let date = Date(timeIntervalSince1970: resets)
        let left = max(0, Int(resets - now.timeIntervalSince1970))
        let time = date.formatted(date: .omitted, time: .shortened)
        if left >= 24 * 3600 {
            return date.formatted(.dateTime.weekday(.abbreviated)) + " " + time
        }
        let h = left / 3600, m = (left % 3600) / 60
        return "in " + (h > 0 ? "\(h) h \(m) min" : "\(m) min") + " (\(time))"
    }
}

/// Today across every conversation: how well the cache is working and what it cost.
struct TodayStrip: View {
    @Environment(\.reveal) private var reveal
    let today: Today
    let tips: [String]
    let ink: Ink
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Today", ink: ink,
                         note: expanded
                            ? "\(today.conversations) conversation\(today.conversations == 1 ? "" : "s") · \(today.replies) replies"
                            : "\(percent(today.hitRate)) from cache · \(tokens(today.output)) output" + (tips.isEmpty ? "" : " · ⚠️"),
                         expanded: $expanded)
            if expanded { details }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(ink.surface))
    }

    @ViewBuilder var details: some View {
            HStack(spacing: 0) {
                Stat(value: percent(today.hitRate), label: "from cache", ink: ink,
                     tint: today.hitRate >= 0.9 ? ink.tint(.hot) : ink.tint(.low))
                Stat(value: tokens(today.read), label: "cache reads", ink: ink)
                Stat(value: tokens(today.written + today.input), label: "written / new", ink: ink)
                Stat(value: tokens(today.output), label: "output", ink: ink)
            }
            // Where today's input came from: cheap cache reads vs. full-price writes.
            GeometryReader { geo in
                let all = Double(max(1, today.read + today.written + today.input))
                HStack(spacing: 1) {
                    Rectangle().fill(ink.tint(.hot)).frame(width: geo.size.width * Double(today.read) / all * reveal)
                    Rectangle().fill(ink.tint(.low)).frame(width: geo.size.width * Double(today.written + today.input) / all * reveal)
                    Spacer(minLength: 0)
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            ForEach(tips, id: \.self) { Tip(text: $0, icon: "⚠️", ink: ink) }
    }
}

struct Stat: View {
    let value: String
    let label: String
    let ink: Ink
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 15, weight: .bold).monospacedDigit())
                .rolling(value)
                .foregroundStyle(tint ?? ink.primary)
            Text(label).font(.caption2).foregroundStyle(ink.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The focused conversation's context, laid out like Claude Code's Context panel.
struct ContextPanel: View {
    let context: Context
    let ink: Ink
    @Binding var expanded: Bool
    @Binding var messagesOpen: Bool

    var body: some View {
        let messagesTotal = max(1, context.messages.reduce(0) { $0 + $1.tokens })
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Context", ink: ink,
                         note: !expanded ? "tap for the breakdown" : context.exact ? nil : "system prompt not logged here",
                         expanded: $expanded)
            HStack(alignment: .firstTextBaseline) {
                Text("\(percent(context.share(context.used))) used")
                    .rolling(context.used)
                    .font(.system(size: 17, weight: .bold).monospacedDigit()).foregroundStyle(ink.primary)
                Spacer()
                Text("\(tokens(context.used)) / \(tokens(context.window))")
                    .font(.callout.monospacedDigit()).foregroundStyle(ink.secondary)
            }
            StackedBar(segments: context.parts.map { (ink.part($0.key), context.share($0.tokens)) }
                       + [(ink.part("autocompact"), context.share(context.autocompact))],
                       ink: ink, height: 8)
            if expanded {
            VStack(spacing: 3) {
                ForEach(context.parts.filter { $0.tokens > 0 }, id: \.key) { part in
                    PartRow(color: ink.part(part.key), label: part.label, tokens: part.tokens,
                            share: context.share(part.tokens), ink: ink,
                            expanded: part.key == "messages" ? $messagesOpen : nil)
                    if part.key == "messages" && messagesOpen {
                        // What the conversation itself is made of, as a share of it.
                        VStack(spacing: 2) {
                            ForEach(context.messages.filter { $0.tokens > 0 }.sorted { $0.tokens > $1.tokens }, id: \.key) { m in
                                SubRow(label: m.label, tokens: m.tokens,
                                       fraction: Double(m.tokens) / Double(messagesTotal),
                                       color: ink.part("messages"), ink: ink)
                            }
                        }
                        .padding(.leading, 18)
                        .padding(.bottom, 2)
                    }
                }
                PartRow(color: ink.part("autocompact"), label: "Autocompact buffer", tokens: context.autocompact,
                        share: context.share(context.autocompact), ink: ink)
                PartRow(color: ink.track, label: "Free space", tokens: context.free,
                        share: context.share(context.free), ink: ink)
            }
            }
        }
    }
}

struct StackedBar: View {
    @Environment(\.reveal) private var reveal
    let segments: [(Color, Double)]
    let ink: Ink
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1.5) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    if seg.1 > 0 {
                        Rectangle().fill(seg.0).frame(width: max(2, geo.size.width * seg.1 * reveal))
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, alignment: .leading)
            .background(ink.track)
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

struct PartRow: View {
    let color: Color
    let label: String
    let tokens: Int
    let share: Double
    let ink: Ink
    /// Set on a row with sub-rows: tap it to show or hide them.
    var expanded: Binding<Bool>? = nil

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 11, height: 11)
            Text(label).font(.system(size: 12)).foregroundStyle(ink.primary)
            if let expanded { Chevron(open: expanded.wrappedValue, ink: ink) }
            Spacer()
            Text(ClaudeCache.tokens(tokens)).font(.system(size: 12).monospacedDigit()).foregroundStyle(ink.secondary)
                .frame(width: 56, alignment: .trailing)
            Text(percent(share)).font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(ink.primary)
                .frame(width: 44, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(expanded) }
    }
}

/// A smaller row with a bar showing its share of its parent.
struct SubRow: View {
    @Environment(\.reveal) private var reveal
    let label: String
    let tokens: Int
    let fraction: Double
    let color: Color
    let ink: Ink
    /// nil: the label takes the room it needs (one line) and the bar is short.
    var labelWidth: CGFloat? = 128

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(ink.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: labelWidth ?? .infinity, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.track)
                    Capsule().fill(color).frame(width: max(2, geo.size.width * fraction * reveal))
                }
            }
            .frame(width: labelWidth == nil ? 90 : nil, height: 4)
            Text(ClaudeCache.tokens(tokens)).font(.system(size: 11).monospacedDigit()).foregroundStyle(ink.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}

/// The single largest things in the context: the ones worth not doing again.
struct BiggestItems: View {
    let items: [Item]
    let ink: Ink
    @Binding var expanded: Bool

    var body: some View {
        let peak = Double(items.map(\.tokens).max() ?? 1)
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle("Biggest items", ink: ink,
                         note: expanded ? nil : "\(items[0].label) · \(tokens(items[0].tokens))",
                         expanded: $expanded)
            ForEach(expanded ? items : [], id: \.label) { item in
                SubRow(label: item.label, tokens: item.tokens, fraction: Double(item.tokens) / peak,
                       color: ink.part("tools"), ink: ink, labelWidth: nil)
            }
        }
    }
}

struct Tips: View {
    let tips: [String]
    let ink: Ink
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionTitle("To save tokens", ink: ink,
                         note: expanded ? nil : "\(tips.count) tip\(tips.count == 1 ? "" : "s")",
                         expanded: $expanded)
            ForEach(expanded ? tips : [], id: \.self) { Tip(text: $0, icon: "💡", ink: ink) }
        }
    }
}

struct Tip: View {
    let text: String
    let icon: String
    let ink: Ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(icon).font(.system(size: 11))
            Text(text).font(.system(size: 11.5)).foregroundStyle(ink.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One line per recent conversation: cache state, context size and its make-up.
struct ConversationRow: View {
    let conversation: Conversation
    let now: Date
    let ink: Ink
    let selected: Bool

    var body: some View {
        let left = conversation.secondsLeft(at: now)
        let state = CacheState(left: left)
        let expiry = Date(timeIntervalSince1970: conversation.when + conversation.ttl)
            .formatted(date: .omitted, time: .shortened)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(state.emoji).font(.system(size: 12))
                Text(conversation.title).font(.system(size: 12, weight: .medium)).foregroundStyle(ink.primary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                Text(state == .cold ? "cold" : "\(Int(ceil(left / 60)))m")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(state == .cold ? ink.secondary : ink.tint(state))
            }
            if let context = conversation.context {
                HStack(spacing: 8) {
                    StackedBar(segments: context.parts.map { (ink.part($0.key), context.share($0.tokens)) }, ink: ink, height: 4)
                        .frame(width: 96)
                    Text("\(tokens(context.used)) (\(percent(context.share(context.used)))) · \(state == .cold ? "cold since \(expiry)" : "warm until \(expiry)") · \(conversation.project)")
                        .font(.caption2).foregroundStyle(ink.secondary).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? ink.surface : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? ink.track : Color.clear))
    }
}

struct Header: View {
    let conversations: [Conversation]
    let now: Date
    let ink: Ink

    var body: some View {
        let states = conversations.map { CacheState(left: $0.secondsLeft(at: now)) }
        HStack(alignment: .firstTextBaseline) {
            Text("Claude tokens").font(.headline).foregroundStyle(ink.primary)
            Spacer()
            ForEach([CacheState.hot, .low, .cold], id: \.self) { state in
                let n = states.filter { $0 == state }.count
                if n > 0 {
                    Text("\(state.emoji) \(n)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(ink.primary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(ink.surface))
                        .overlay(Capsule().strokeBorder(ink.tint(state), lineWidth: 1.5))
                }
            }
        }
    }
}

struct Card: View {
    let conversation: Conversation
    let now: Date
    let ink: Ink

    var body: some View {
        let left = conversation.secondsLeft(at: now)
        let state = CacheState(left: left)
        if state == .cold {
            // Nothing to act on: a compact row, so the warm ones stand out.
            HStack(spacing: 10) {
                Ring(fraction: 0, state: state, left: left, size: 30, ink: ink)
                VStack(alignment: .leading, spacing: 1) {
                    Text(conversation.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ink.primary)
                        .lineLimit(1).truncationMode(.tail)
                    Text("\(detail(left: left, state: state)) · \(conversation.project)")
                        .font(.caption).foregroundStyle(ink.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(ink.surface))
        } else {
            HStack(alignment: .center, spacing: 12) {
                Ring(fraction: max(0, left) / conversation.ttl, state: state, left: left, size: 50, ink: ink)
                VStack(alignment: .leading, spacing: 4) {
                    Text(conversation.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ink.primary)
                        .lineLimit(1).truncationMode(.tail)
                    Text(detail(left: left, state: state))
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(ink.primary)
                    Timeline(conversation: conversation, now: now, state: state, ink: ink)
                        .frame(height: 36)
                    Text("\(conversation.project) · \(Int(conversation.ttl / 60))-min cache · \(ClaudeCache.tokens(conversation.cached)) cached")
                        .font(.caption).foregroundStyle(ink.secondary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(ink.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ink.tint(state), lineWidth: 1.5).pulse(state == .low))
        }
    }

    func detail(left: Double, state: CacheState) -> String {
        let expiry = Date(timeIntervalSince1970: conversation.when + conversation.ttl)
            .formatted(date: .omitted, time: .shortened)
        switch state {
        case .hot: return "\(clock(left)) left · warm until \(expiry)"
        case .low: return "\(clock(left)) left · send something before \(expiry)"
        case .cold: return "Cold since \(expiry)"
        }
    }
}

/// Time left as a draining ring, minutes in the middle.
struct Ring: View {
    @Environment(\.reveal) private var reveal
    let fraction: Double
    let state: CacheState
    let left: Double
    var size: CGFloat = 50
    let ink: Ink
    @State private var shown: Double?

    var body: some View {
        let line = size > 40 ? 5.0 : 3.0
        ZStack {
            Circle().stroke(ink.track, lineWidth: line)
            Circle()
                .trim(from: 0, to: (shown ?? fraction) * reveal)
                .stroke(ink.tint(state), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                // Drain smoothly between the once-a-second updates. Animate only the
                // trim: an implicit .animation here would also drag the arc across
                // the menu for a second whenever a section opens or closes.
                .onChange(of: fraction) { new in
                    withAnimation(.linear(duration: 1)) { shown = new }
                }
            if size > 40 {
                VStack(spacing: -1) {
                    Text(state.emoji).font(.system(size: 13))
                    Text("\(Int(ceil(max(0, left) / 60)))m")
                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                        .foregroundStyle(ink.primary)
                        .rolling(Int(ceil(max(0, left) / 60)))
                }
            } else {
                Text(state.emoji).font(.system(size: 12))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The past hour as a bar chart of replies per 5 minutes | now | the next hour:
/// the warm window still ahead, yellow for its last 20 minutes.
struct Timeline: View {
    @Environment(\.reveal) private var reveal
    let conversation: Conversation
    let now: Date
    let state: CacheState
    let ink: Ink

    static let bins = 12  // 5-minute buckets across the past hour

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let nowT = now.timeIntervalSince1970
            // Seconds from now → x: -1 h at the left edge, now in the middle, +1 h at the right.
            let x = { (t: Double) -> CGFloat in
                CGFloat((min(max(t - nowT, -timelineSpan), timelineSpan) + timelineSpan) / (2 * timelineSpan)) * w
            }
            let expiry = conversation.when + conversation.ttl
            let chart: CGFloat = 14   // height of the activity bars
            let bar: CGFloat = 6      // height of the time track
            let barY = chart + 2
            let counts = binned(nowT)
            let peak = max(1, counts.max() ?? 1)
            let binW = (w / 2) / CGFloat(Self.bins)

            ZStack(alignment: .topLeading) {
                // activity: replies per 5 minutes over the past hour
                ForEach(0..<Self.bins, id: \.self) { i in
                    let h = counts[i] == 0 ? 0 : max(2, chart * CGFloat(counts[i]) / CGFloat(peak)) * reveal
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(ink.tint(state))
                        .frame(width: max(1, binW - 2), height: h)
                        .offset(x: CGFloat(i) * binW + 1, y: chart - h)
                }
                // track
                Capsule().fill(ink.track)
                    .frame(width: w, height: bar).offset(y: barY)
                // warm window ahead
                if expiry > nowT {
                    // The window grows out from "now" as the menu opens.
                    let x = { (t: Double) -> CGFloat in x(nowT) + (x(t) - x(nowT)) * reveal }
                    let warnStart = max(nowT, expiry - warnSeconds)
                    if warnStart > nowT {
                        Rectangle().fill(ink.tint(.hot))
                            .frame(width: x(warnStart) - x(nowT), height: bar)
                            .offset(x: x(nowT), y: barY)
                    }
                    UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                        .fill(ink.tint(.low))
                        .frame(width: max(1, x(expiry) - x(warnStart)), height: bar)
                        .offset(x: x(warnStart), y: barY)
                }
                // now
                Capsule().fill(ink.primary)
                    .frame(width: 2, height: chart + bar + 4)
                    .offset(x: w / 2 - 1, y: 0)
                // labels
                HStack {
                    Text("1 h ago"); Spacer(); Text("now"); Spacer(); Text("in 1 h")
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(ink.secondary)
                .frame(width: w)
                .offset(y: barY + bar + 2)
            }
        }
    }

    /// Replies in each 5-minute bucket of the past hour, oldest first.
    func binned(_ nowT: Double) -> [Int] {
        var counts = Array(repeating: 0, count: Self.bins)
        let size = timelineSpan / Double(Self.bins)
        for t in conversation.replies ?? [] where t > nowT - timelineSpan && t <= nowT {
            counts[min(Self.bins - 1, Int((t - (nowT - timelineSpan)) / size))] += 1
        }
        return counts
    }
}

