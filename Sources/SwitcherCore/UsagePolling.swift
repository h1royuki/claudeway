import Foundation

public struct UsagePolling: Codable {
    private var lastAttempt: [UUID: Date] = [:]
    private var blockedUntil: [UUID: Date] = [:]
    public init() {}
    public func allows(_ id: UUID, force: Bool, now: Date = Date()) -> Bool {
        if let blocked = blockedUntil[id], blocked > now { return false }
        return lastAttempt[id].map { now.timeIntervalSince($0) >= (force ? 60 : 300) } ?? true
    }
    public func blockedDate(_ id: UUID) -> Date? { blockedUntil[id] }
    public mutating func started(_ id: UUID, now: Date = Date()) { lastAttempt[id] = now }
    public mutating func rateLimited(_ id: UUID, delay: TimeInterval, now: Date = Date()) { blockedUntil[id] = now.addingTimeInterval(max(300, delay)) }
    public static func retryDelay(_ header: String?, now: Date = Date()) -> TimeInterval {
        if let header, let seconds = Double(header), seconds.isFinite, seconds >= 0 { return max(300, seconds) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let header, let date = formatter.date(from: header) { return max(300, date.timeIntervalSince(now)) }
        return 900
    }
    public static func load(at url: URL) -> UsagePolling {
        guard let data = try? Disk.read(url), data.count < 100_000,
              let result = try? JSONDecoder().decode(Self.self, from: data) else { return UsagePolling() }
        return result
    }
    public func save(at url: URL) { try? Disk.write(self, url) }
}
