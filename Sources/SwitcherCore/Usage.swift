import Foundation
import CoreFoundation

public struct UsageWindow: Codable, Equatable {
    public let key: String
    public let title: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let explicitlyInactive: Bool?
    public init(key: String, title: String, usedPercent: Double, resetsAt: Date?, explicitlyInactive: Bool? = nil) {
        self.key = key; self.title = title; self.usedPercent = usedPercent; self.resetsAt = resetsAt; self.explicitlyInactive = explicitlyInactive
    }
    public func hasElapsed(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }
    public var displayTitle: String {
        switch key {
        case "five_hour": return L10n.text("5 h")
        case "seven_day": return L10n.text("Week")
        default: return title // Model names supplied by the server are not UI strings.
        }
    }
}

public struct AccountUsage: Codable, Equatable {
    public let profileID: UUID
    public let accountID: UUID
    public let organizationID: UUID
    public let observedAt: Date
    public let source: String
    public let windows: [UsageWindow]
    public init(profileID: UUID, accountID: UUID, organizationID: UUID, observedAt: Date, source: String, windows: [UsageWindow]) {
        self.profileID = profileID; self.accountID = accountID; self.organizationID = organizationID
        self.observedAt = observedAt; self.source = source; self.windows = windows
    }
    public func nearestReset(at now: Date) -> Date? { windows.compactMap(\.resetsAt).filter { $0 > now }.min() }
    public func isStale(at now: Date) -> Bool { now.timeIntervalSince(observedAt) > 900 || windows.contains { $0.hasElapsed(at: now) } }
}

public enum UsageParser {
    public static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
    private static func percent(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
    /// Accept only explicit utilization/reset fields. Missing is never interpreted as zero.
    public static func windows(from data: Data) throws -> [UsageWindow] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StoreError.message(L10n.text("Unknown usage format.")) }
        var result: [UsageWindow] = []
        let fields = [("five_hour", L10n.text("5 h")), ("seven_day", L10n.text("Wk")), ("seven_day_sonnet", "Sonnet"), ("seven_day_opus", "Opus")]
        for (key, title) in fields {
            if key == "five_hour", object[key] is NSNull {
                result.append(UsageWindow(key: key, title: title, usedPercent: 0, resetsAt: nil, explicitlyInactive: true))
                continue
            }
            if let row = object[key] as? [String: Any], let value = percent(row["utilization"]) {
                result.append(UsageWindow(key: key, title: title, usedPercent: value, resetsAt: date(row["resets_at"]), explicitlyInactive: key == "five_hour" && value == 0 && row["resets_at"] is NSNull ? true : nil))
            }
        }
        if let limits = object["limits"] as? [[String: Any]] {
            for row in limits {
                guard let kind = row["kind"] as? String, let value = percent(row["percent"]) else { continue }
                let key: String, title: String
                if kind == "session" { key = "five_hour"; title = L10n.text("5 h") }
                else if kind == "weekly_all" { key = "seven_day"; title = L10n.text("Wk") }
                else if kind == "weekly_scoped", let scope = row["scope"] as? [String: Any],
                        let model = scope["model"] as? [String: Any], let name = model["display_name"] as? String,
                        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    key = "model:" + name; title = name
                    if result.contains(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) { continue }
                } else { continue }
                let window = UsageWindow(key: key, title: title, usedPercent: value, resetsAt: date(row["resets_at"]), explicitlyInactive: key == "five_hour" && value == 0 && row["resets_at"] is NSNull ? true : nil)
                if let index = result.firstIndex(where: { $0.key == key }) { result[index] = window }
                else { result.append(window) }
            }
        }
        guard !result.isEmpty else { throw StoreError.message(L10n.text("Usage limits are unavailable for this account.")) }
        return result
    }

    public static func history(_ data: Data, profile: Profile, now: Date = Date()) throws -> AccountUsage? {
        guard let account = profile.auth?.accountID, let org = profile.organizationID,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 2, let samples = object["samples"] as? [[String: Any]] else { return nil }
        let rows = samples.filter { row in
            guard (row["org"] as? String).flatMap(UUID.init(uuidString:)) == org, let t = row["t"] as? Double else { return false }
            return t.isFinite && t / 1000 <= now.timeIntervalSince1970 + 60
        }
        guard let latest = rows.max(by: { ($0["t"] as? Double ?? 0) < ($1["t"] as? Double ?? 0) }),
              let timestamp = latest["t"] as? Double, let values = latest["u"] as? [String: Any] else { return nil }
        let keys = [("fh", "five_hour", L10n.text("5 h")), ("sd", "seven_day", L10n.text("Wk")), ("sn", "seven_day_sonnet", "Sonnet"), ("so", "seven_day_opus", "Opus")]
        let windows = keys.compactMap { short, key, title -> UsageWindow? in
            guard let used = percent(values[short]) else { return nil }
            return UsageWindow(key: key, title: title, usedPercent: used, resetsAt: nil)
        }
        guard !windows.isEmpty else { return nil }
        return AccountUsage(profileID: profile.id, accountID: account, organizationID: org,
                            observedAt: Date(timeIntervalSince1970: timestamp / 1000), source: "local", windows: windows)
    }
}

public enum UsageText {
    public static func accessibleReset(_ date: Date?) -> String {
        guard let date else { return L10n.text("unknown") }
        let formatter = DateFormatter(); formatter.locale = L10n.locale
        formatter.dateStyle = .full; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    public static func countdown(to date: Date, now: Date = Date()) -> String {
        let minutes = max(1, Int(ceil(date.timeIntervalSince(now) / 60)))
        if date <= now { return L10n.text("awaiting update") }
        if minutes >= 1440 { return L10n.text("%@d %@h", String(minutes / 1440), String((minutes % 1440) / 60)) }
        if minutes >= 60 { return L10n.text("%@h %@m", String(minutes / 60), String(minutes % 60)) }
        return L10n.text("%@m", String(minutes))
    }
    public static func reset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        if date <= now { return L10n.text("refresh") }
        let formatter = DateFormatter(); formatter.locale = L10n.locale
        formatter.dateFormat = Calendar.current.isDate(date, inSameDayAs: now) ? "HH:mm" : "EE HH:mm"
        return formatter.string(from: date)
    }
    public static func age(_ date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return L10n.text("now") }
        if minutes < 60 { return L10n.text("%@m ago", String(minutes)) }
        if minutes < 1440 { return L10n.text("%@h ago", String(minutes / 60)) }
        return L10n.text("%@d ago", String(minutes / 1440))
    }
}
