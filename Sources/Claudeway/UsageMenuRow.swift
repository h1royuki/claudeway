import AppKit
import SwitcherCore

/// Compact native-menu content; the whole account row remains one switch target.
@MainActor final class UsageMenuRow: NSView {
    private let profile: Profile
    private let active: Bool
    private let usage: AccountUsage?
    private let error: String?
    private let canSelect: Bool
    private let action: () -> Void
    private var menuHighlighted = false
    override var isFlipped: Bool { true }
    private let accent = NSColor(calibratedRed: 0.70, green: 0.40, blue: 0.28, alpha: 1)
    // One trailing edge for countdowns and every reset timestamp.
    private var timeColumnRight: CGFloat { bounds.width - 14 }

    init(profile: Profile, active: Bool, usage: AccountUsage?, error: String?, enabled: Bool, action: @escaping () -> Void) {
        self.profile = profile; self.active = active; self.usage = usage; self.error = error
        self.canSelect = enabled; self.action = action
        // Each limit has its own compact row: label, bar, used percent, reset time.
        let count = max(2, usage?.windows.count ?? 0)
        super.init(frame: NSRect(x: 0, y: 0, width: 258, height: 26 + count * 18 + (Self.notice(usage: usage, error: error) == nil ? 0 : 14)))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityText())
        toolTip = nil
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    // NSMenu is the only owner of selection. Independent mouse tracking left
    // stale hover flags on a second row during native menu tracking.
    func setMenuHighlighted(_ highlighted: Bool) {
        menuHighlighted = highlighted
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard canSelect, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        choose()
    }
    override func accessibilityPerformPress() -> Bool { guard canSelect else { return false }; choose(); return true }
    private func choose() {
        enclosingMenuItem?.menu?.cancelTracking()
        DispatchQueue.main.async { [action] in action() }
    }
    private func text(_ value: String, rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = alignment; paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
    override func draw(_ dirtyRect: NSRect) {
        let selected = canSelect && menuHighlighted
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 2), xRadius: 5, yRadius: 5)
        if selected {
            NSColor.selectedContentBackgroundColor.setFill(); panel.fill()
        }
        let fg: NSColor = selected ? .white : (canSelect ? .labelColor : .disabledControlTextColor)
        let secondary: NSColor = selected ? .white.withAlphaComponent(0.8) : .secondaryLabelColor
        let now = Date()
        text(profile.name, rect: NSRect(x: 14, y: 4, width: 134, height: 18), font: .systemFont(ofSize: 13, weight: active ? .semibold : .medium), color: fg)
        if active {
            (selected ? NSColor.white : accent).setFill()
            NSBezierPath(roundedRect: NSRect(x: 5, y: 4, width: 2, height: bounds.height - 8), xRadius: 1, yRadius: 1).fill()
        }
        let nearest = usage?.nearestReset(at: now).map { "↻ " + UsageText.countdown(to: $0, now: now) } ?? "↻ —"
        text(nearest, rect: NSRect(x: timeColumnRight - 89, y: 6, width: 89, height: 16), font: .monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: secondary, alignment: .right)
        let windows = usage?.windows ?? []
        for i in 0..<max(2, windows.count) {
            let window = i < windows.count ? windows[i] : nil
            let y = CGFloat(25 + i * 18)
            let title = window?.key == "seven_day" ? "Неделя" : window?.title ?? (i == 0 ? "5 ч" : "Неделя")
            text(title, rect: NSRect(x: 14, y: y, width: 46, height: 16), font: .systemFont(ofSize: 11), color: secondary)
            let elapsed = window?.hasElapsed(at: now) ?? false
            let value = window.map { elapsed ? "—" : "\(Int($0.usedPercent.rounded()))%" } ?? "—"
            text(value, rect: NSRect(x: timeColumnRight - 93, y: y, width: 32, height: 16), font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: fg, alignment: .right)
            let bar = NSRect(x: 65, y: y + 7, width: timeColumnRight - 164, height: 3)
            (selected ? NSColor.white.withAlphaComponent(0.22) : NSColor.quaternaryLabelColor).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            if let window, !elapsed {
                (selected ? NSColor.white : window.usedPercent >= 90 ? NSColor.systemOrange : accent).setFill()
                let fill = NSRect(x: bar.minX, y: bar.minY, width: bar.width * min(100, window.usedPercent) / 100, height: bar.height)
                NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
            }
            text(UsageText.reset(window?.resetsAt, now: now), rect: NSRect(x: timeColumnRight - 53, y: y + 1, width: 53, height: 15), font: .monospacedDigitSystemFont(ofSize: 10, weight: .regular), color: secondary, alignment: .right)
        }
        if let notice = Self.notice(usage: usage, error: error) {
            text(notice, rect: NSRect(x: 14, y: bounds.height - 15, width: 230, height: 13), font: .systemFont(ofSize: 9), color: secondary)
        }
    }
    private static func notice(usage: AccountUsage?, error: String?) -> String? {
        if let error { return error }
        guard let usage else { return "Нет данных о лимитах" }
        if usage.source == "local" { return "Время сброса недоступно" }
        if usage.isStale(at: Date()) { return "Данные \(UsageText.age(usage.observedAt)) · обновить" }
        return nil
    }
    private func accessibilityText() -> String {
        var parts = [profile.name + (active ? ", активен" : ", переключиться")]
        for window in usage?.windows ?? [] {
            parts.append("\(window.title): использовано \(Int(window.usedPercent.rounded())) процентов; сброс \(window.resetsAt?.description(with: Locale(identifier: "ru_RU")) ?? "неизвестен")")
        }
        if let usage { parts.append("Обновлено \(UsageText.age(usage.observedAt))") }
        if let error { parts.append(error) }
        return parts.joined(separator: ". ")
    }
}
