// The menu bar item, drawn: the cache's emoji and minutes left, then the plan's
// usage as two stacked gauges (5-hour over week).
//
//   🔥 58m  5h ▬▬▬──── 16%
//           wk ▬▬▬▬─── 28%
//
// The cache reads at a glance by its emoji (🔥 warm, ⏳ under 20 minutes left, 🥶 cold,
// 🔄 compacting); the rest stays monochrome, with colour only where it wants
// attention: orange for minutes nearly up or usage past 60%, red past 85%.

import AppKit

extension StatusTitle {
    /// Redrawn on every draw, so the colours follow the menu bar's light or dark look.
    func image(height: CGFloat) -> NSImage {
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let emojiFont = NSFont.systemFont(ofSize: 13)
        let symbolSize: CGFloat = 17
        let gap: CGFloat = 6
        let bar = CGSize(width: 22, height: 3.5)
        let labelW = ("wk" as NSString).size(withAttributes: [.font: smallFont]).width
        let pctW = ("100%" as NSString).size(withAttributes: [.font: smallFont]).width

        let (symbol, time, tone): (String, String?, NSColor) = {
            switch cache {
            case .warm(let minutes, let low):
                return ((low ? CacheState.low : .hot).emoji, "\(minutes)m", low ? .systemOrange : .labelColor)
            case .compacting: return ("🔄", nil, .labelColor)
            case .cold: return (CacheState.cold.emoji, nil, .labelColor)
            }
        }()
        let timeW = time.map { ($0 as NSString).size(withAttributes: [.font: timeFont]).width + 3 } ?? 0
        let usage = [("5h", session), ("wk", week)].compactMap { label, used in used.map { (label, $0) } }
        let usageW = usage.isEmpty ? 0 : gap + labelW + 3 + bar.width + 3 + pctW
        let size = NSSize(width: ceil(symbolSize + timeW + usageW), height: height)

        return NSImage(size: size, flipped: true) { _ in
            var x: CGFloat = 0
            let glyph = NSAttributedString(string: symbol, attributes: [.font: emojiFont])
            let g = glyph.size()
            glyph.draw(at: NSPoint(x: x + (symbolSize - g.width) / 2, y: (height - g.height) / 2))
            x += symbolSize
            if let time {
                let text = NSAttributedString(string: time, attributes: [.font: timeFont, .foregroundColor: tone])
                text.draw(at: NSPoint(x: x + 3, y: (height - text.size().height) / 2))
                x += timeW
            }
            guard !usage.isEmpty else { return true }
            x += gap
            let rowH = height / CGFloat(max(2, usage.count))
            for (i, (label, used)) in usage.enumerated() {
                let color: NSColor = used >= Self.usageAlarm ? .systemRed : used >= Self.usageWarn ? .systemOrange : .labelColor
                let mid = rowH * (CGFloat(i) + 0.5) + (usage.count == 1 ? rowH / 2 : 0)
                let l = NSAttributedString(string: label, attributes: [.font: smallFont, .foregroundColor: NSColor.secondaryLabelColor])
                l.draw(at: NSPoint(x: x, y: mid - l.size().height / 2))
                var bx = x + labelW + 3
                let track = NSRect(x: bx, y: mid - bar.height / 2, width: bar.width, height: bar.height)
                NSColor.labelColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: track, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
                var fill = track
                fill.size.width = max(bar.height, bar.width * min(100, max(0, used)) / 100)
                color.setFill()
                NSBezierPath(roundedRect: fill, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
                bx += bar.width + 3
                let p = NSAttributedString(string: "\(Int(used.rounded()))%",
                                           attributes: [.font: smallFont, .foregroundColor: used >= Self.usageWarn ? color : NSColor.labelColor])
                p.draw(at: NSPoint(x: bx + pctW - p.size().width, y: mid - p.size().height / 2))
            }
            return true
        }
    }

    /// The same, in words, for VoiceOver.
    var spoken: String {
        var parts: [String] = []
        switch cache {
        case .warm(let minutes, _): parts.append("Cache warm, \(minutes) minutes left")
        case .compacting: parts.append("Compacting")
        case .cold: parts.append("No warm cache")
        }
        if let session { parts.append("5-hour limit \(Int(session.rounded()))% used") }
        if let week { parts.append("week \(Int(week.rounded()))% used") }
        return parts.joined(separator: ", ")
    }
}
