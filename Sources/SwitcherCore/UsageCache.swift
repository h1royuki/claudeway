import Foundation

public enum UsageCache {
    /// This file contains only usage statistics and identity UUIDs, never credentials.
    public static func load(at url: URL, profiles: [Profile]) -> [UUID: AccountUsage] {
        guard let data = try? Disk.read(url), data.count < 1_000_000,
              let records = try? JSONDecoder().decode([AccountUsage].self, from: data) else { return [:] }
        var result: [UUID: AccountUsage] = [:]
        for record in records {
            guard record.source == "server", record.observedAt <= Date().addingTimeInterval(60),
                  profiles.contains(where: { $0.id == record.profileID && $0.auth?.accountID == record.accountID && $0.organizationID == record.organizationID }),
                  record.windows.allSatisfy({ $0.usedPercent.isFinite && $0.usedPercent >= 0 }) else { continue }
            result[record.profileID] = record
        }
        return result
    }
    public static func save(_ values: [UUID: AccountUsage], at url: URL) throws {
        try Disk.write(values.values.filter { $0.source == "server" }.sorted { $0.profileID.uuidString < $1.profileID.uuidString }, url)
    }
}
