import Foundation

public struct SessionTransferReport: Codable {
    public var added = 0
    public var updated = 0
    public var skipped = 0
    public var note: String?
    public var backupDirectory: String?
    /// Only completed changes belong in a user-facing notification.
    public var notificationBody: String? {
        var parts: [String] = []
        if added > 0 { parts.append("Добавлено: \(added)") }
        if updated > 0 { parts.append("Обновлено: \(updated)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    public var summary: String {
        note ?? "Чаты: добавлено \(added), обновлено \(updated), пропущено \(skipped)"
    }
}

/// Imports only local chat list records. The actual transcripts stay in
/// ~/.claude/projects. Account credentials, connector configuration, approval
/// grants and system/tool snapshots never cross profile boundaries.
public enum SessionTransfer {
    private static let fm = FileManager.default
    private static let sharedFields = [
        "sessionId", "cliSessionId", "cwd", "originCwd", "createdAt",
        "lastActivityAt", "lastFocusedAt", "model", "effort", "isArchived",
        "title", "titleSource", "completedTurns", "titleTurn",
        "postTurnSummary", "postTurnSummaryFor", "lastAssistantUuid",
        "worktreePath", "worktreeName", "branch", "sourceBranch"
    ]

    private struct Record {
        let url: URL
        let data: Data
        let json: [String: Any]
        let id: String
        let activity: Double
    }

    private static func isDirectory(_ url: URL) -> Bool {
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else { return false }
        return url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func regularData(_ url: URL) -> Data? {
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 4_000_000 else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Only use the account recorded by Claude itself. An ambiguous organization
    /// is skipped rather than guessed. A native chat initializes this directory.
    private static func organizationDirectories(_ profile: URL) -> [URL] {
        guard isDirectory(profile),
              let data = regularData(profile.appendingPathComponent("config.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = json["lastKnownAccountUuid"] as? String,
              UUID(uuidString: account) != nil else { return [] }
        let sessions = profile.appendingPathComponent("claude-code-sessions")
        let accountDirectory = sessions.appendingPathComponent(account)
        guard isDirectory(sessions), isDirectory(accountDirectory) else { return [] }
        return ((try? fm.contentsOfDirectory(at: accountDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && isDirectory($0) }
            .sorted { $0.path < $1.path }
    }

    private static func record(_ url: URL, transcriptRoot: URL? = nil) -> Record? {
        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "json", name.hasPrefix("local_"),
              UUID(uuidString: String(name.dropFirst(6))) != nil,
              let data = regularData(url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["sessionId"] as? String == name,
              let cliID = json["cliSessionId"] as? String, UUID(uuidString: cliID) != nil,
              let cwd = json["cwd"] as? String, cwd.hasPrefix("/"),
              let activity = json["lastActivityAt"] as? NSNumber,
              activity.doubleValue.isFinite,
              json["sshConnectionId"] == nil, json["sshHost"] == nil,
              json["wslDistribution"] == nil, json["remoteSessionId"] == nil else { return nil }
        // Desktop does not write completedTurns until a final reply. Interrupted
        // or tool-running conversations still have a real, resumable transcript.
        let completed = (json["completedTurns"] as? NSNumber).map { $0.intValue > 0 } ?? false
        guard completed || LocalTranscript.hasConversation(cliID: cliID, cwd: cwd, root: transcriptRoot) else { return nil }
        return Record(url: url, data: data, json: json, id: name, activity: activity.doubleValue)
    }

    private static func deletedID(_ url: URL) -> String? {
        var name = url.lastPathComponent
        guard name.hasPrefix("deleted_") else { return nil }
        name = String(name.dropFirst(8))
        if name.hasSuffix(".json") { name = String(name.dropLast(5)) }
        if name.hasPrefix("local_") { name = String(name.dropFirst(6)) }
        guard UUID(uuidString: name) != nil else { return nil }
        return "local_" + name.lowercased()
    }

    @discardableResult
    public static func synchronize(sources: [URL], target: URL, backupRoot: URL,
                                   transcriptRoot: URL? = nil, requireStopped: () throws -> Void) throws -> SessionTransferReport {
        try requireStopped()
        var report = SessionTransferReport()
        var targets = organizationDirectories(target)
        // Claude may create an empty scheduled-tasks directory for a second
        // organization even though this profile has always used just one for
        // chats. Use the unique populated chat directory; never pick between
        // two populated organizations or by modification time.
        if targets.count > 1 {
            let populated = targets.filter { directory in
                ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
                    .contains { record($0, transcriptRoot: transcriptRoot) != nil }
            }
            if populated.count == 1 { targets = populated }
        }
        guard targets.count == 1, let destinationDirectory = targets.first else {
            report.note = targets.isEmpty
                ? "Чаты: сначала создайте один локальный диалог в новом профиле"
                : "Чаты: несколько организаций в профиле, перенос пропущен"
            return report
        }
        let allDirectories = Set((sources + [target]).flatMap(organizationDirectories))
        return try synchronizeDirectories(allDirectories, destinationDirectory, backupRoot, transcriptRoot, requireStopped)
    }

    private static func sharedOrganizations(in root: URL, accountID: UUID) -> [URL] {
        let sessions = root.appendingPathComponent("claude-code-sessions")
        guard isDirectory(sessions),
              let account = ((try? fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? [])
                .first(where: { UUID(uuidString: $0.lastPathComponent) == accountID && isDirectory($0) }) else { return [] }
        return ((try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil)) ?? [])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && isDirectory($0) }
    }

    public static func sharedTargetDirectory(in root: URL, accountID: UUID, organizationID: UUID?, transcriptRoot: URL? = nil) -> URL? {
        let directories = sharedOrganizations(in: root, accountID: accountID)
        if let organizationID { return directories.first { UUID(uuidString: $0.lastPathComponent) == organizationID } }
        if directories.count == 1 { return directories.first }
        let populated = directories.filter { directory in
            ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).contains { record($0, transcriptRoot: transcriptRoot) != nil }
        }
        return populated.count == 1 ? populated.first : nil
    }

    public static func synchronizeShared(dataRoot: URL, accounts: [UUID], targetAccount: UUID,
                                         targetOrganization: UUID?, backupRoot: URL,
                                         transcriptRoot: URL? = nil, requireStopped: () throws -> Void) throws -> SessionTransferReport {
        try requireStopped()
        guard let destination = sharedTargetDirectory(in: dataRoot, accountID: targetAccount, organizationID: targetOrganization, transcriptRoot: transcriptRoot) else {
            return SessionTransferReport(note: "История: создайте локальный чат; организация ещё не определена")
        }
        let directories = Set(accounts.flatMap { sharedOrganizations(in: dataRoot, accountID: $0) })
        return try synchronizeDirectories(directories, destination, backupRoot, transcriptRoot, requireStopped)
    }

    private static func synchronizeDirectories(_ allDirectories: Set<URL>, _ destinationDirectory: URL,
                                               _ backupRoot: URL, _ transcriptRoot: URL?, _ requireStopped: () throws -> Void) throws -> SessionTransferReport {
        var report = SessionTransferReport()
        var deleted = Set<String>()
        var candidates: [String: Record] = [:]
        var conflicts = Set<String>()
        for directory in allDirectories.sorted(by: { $0.path < $1.path }) {
            let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            for file in files {
                if let id = deletedID(file) { deleted.insert(id); continue }
                guard directory != destinationDirectory,
                      file.lastPathComponent.hasPrefix("local_"), file.pathExtension == "json" else { continue }
                guard let candidate = record(file, transcriptRoot: transcriptRoot) else { report.skipped += 1; continue }
                if let previous = candidates[candidate.id] {
                    if previous.json["cliSessionId"] as? String != candidate.json["cliSessionId"] as? String {
                        conflicts.insert(candidate.id)
                    }
                    if candidate.activity > previous.activity { candidates[candidate.id] = candidate }
                } else { candidates[candidate.id] = candidate }
            }
        }

        struct Change {
            let destination: URL
            let previous: Data?
            let replacement: Data
        }
        var changes: [Change] = []
        for source in candidates.values.sorted(by: { $0.id < $1.id }) {
            guard !deleted.contains(source.id.lowercased()), !conflicts.contains(source.id) else {
                report.skipped += 1; continue
            }
            let destination = destinationDirectory.appendingPathComponent(source.id + ".json")
            let attributes = try? fm.attributesOfItem(atPath: destination.path)
            let existing = attributes == nil ? nil : record(destination, transcriptRoot: transcriptRoot)
            if attributes != nil && existing == nil { report.skipped += 1; continue }
            if let existing {
                guard existing.json["cliSessionId"] as? String == source.json["cliSessionId"] as? String,
                      source.activity > existing.activity else { report.skipped += 1; continue }
            }
            // Preserve destination-local grants and connectors for existing chats.
            // A newly imported chat starts in Manual mode without remote control.
            var merged = existing?.json ?? ["permissionMode": "default", "remoteControlAutoEligible": false, "steeredByRemoteClient": false]
            for key in sharedFields {
                merged.removeValue(forKey: key)
                if let value = source.json[key] { merged[key] = value }
            }
            let bytes = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
            changes.append(Change(destination: destination, previous: existing?.data, replacement: bytes))
        }
        guard !changes.isEmpty else { return report }
        try requireStopped()
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard isDirectory(backupRoot) else { throw StoreError.message("Небезопасный каталог резервных копий чатов.") }
        let backup = backupRoot.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        report.backupDirectory = backup.path
        // Record all originals before any replacement. This also supports manual
        // recovery from a power loss midway through an otherwise additive import.
        let index = changes.map { ["destination": $0.destination.path, "hadOriginal": $0.previous != nil] as [String: Any] }
        try privateWrite(JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted]), to: backup.appendingPathComponent("changes.json"))
        for change in changes {
            if let previous = change.previous {
                try privateWrite(previous, to: backup.appendingPathComponent(change.destination.lastPathComponent))
            }
        }
        var applied: [Change] = []
        do {
            for change in changes {
                try requireStopped()
                // Recheck against concurrent external edits before replacing.
                let currentAttributes = try? fm.attributesOfItem(atPath: change.destination.path)
                if let previous = change.previous {
                    guard regularData(change.destination) == previous else { throw StoreError.message("Запись чата изменилась во время переноса.") }
                } else if currentAttributes != nil { throw StoreError.message("Новый чат появился во время переноса.") }
                applied.append(change)
                try privateWrite(change.replacement, to: change.destination)
                if change.previous == nil { report.added += 1 } else { report.updated += 1 }
            }
        } catch {
            let cause = error
            // Never roll files back underneath a process that reopened them.
            try requireStopped()
            for change in applied.reversed() {
                if let previous = change.previous { try privateWrite(previous, to: change.destination) }
                else if fm.fileExists(atPath: change.destination.path) { try fm.removeItem(at: change.destination) }
            }
            throw cause
        }
        return report
    }

    private static func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        try file.synchronize()
        try file.close()
    }
}
