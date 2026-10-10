import Foundation
import Darwin

public struct Profile: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var auth: AuthReference?
    public var organizationID: UUID?
    public init(id: UUID = UUID(), name: String, auth: AuthReference? = nil, organizationID: UUID? = nil) {
        self.id = id; self.name = name; self.auth = auth; self.organizationID = organizationID
    }
}
public struct PendingProfile: Codable, Equatable {
    public let id: UUID
    public let previousID: UUID?
}
public struct ProfileState: Codable, Equatable {
    public var version = 2
    public var profiles: [Profile]
    public var activeID: UUID?
    public var pending: PendingProfile?
    public var settingsBaseID: UUID?
}
public enum StoreError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
private struct AuthJournal: Codable {
    var version = 2
    let original: ProfileState
    let targetID: UUID?
    let source: AuthReference
    let target: AuthReference
}
private struct MigrationJournal: Codable {
    let original: ProfileState
    let backupID: UUID
    let baseID: UUID?
}

/// Version 2 always keeps one live Desktop directory. Only auth/browser state
/// changes during normal switches. Legacy full profiles remain untouched.
public final class ProfileStore {
    public let root: URL
    public let live: URL
    private let vault: AuthVault
    private var lockFD: Int32 = -1
    public var stateURL: URL { root.appendingPathComponent("profiles.json") }
    public var journalURL: URL { root.appendingPathComponent("auth-switch-journal.json") }
    public var migrationURL: URL { root.appendingPathComponent("migration-journal.json") }
    private var legacyJournal: URL { root.appendingPathComponent("switch-journal.json") }
    public var needsRecovery: Bool { Disk.exists(journalURL) || Disk.exists(migrationURL) || Disk.exists(legacyJournal) }
    public var needsPreparation: Bool {
        guard let bytes = try? Disk.read(stateURL), let state = try? JSONDecoder().decode(ProfileState.self, from: bytes) else { return true }
        return state.version == 1
    }
    public init(root: URL, live: URL) {
        self.root = root; self.live = live
        vault = AuthVault(root: root.appendingPathComponent("auth-snapshots"))
    }
    deinit { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
    public func acquireLock() throws {
        try Disk.directory(root)
        guard lockFD < 0 else { return }
        let fd = open(root.appendingPathComponent("switcher.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StoreError.message(L10n.text("Could not open the account lock.")) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw StoreError.message(L10n.text("Claudeway is already running.")) }
        lockFD = fd
    }
    private func requireLock() throws {
        guard lockFD >= 0 else { throw StoreError.message(L10n.text("Exclusive account access unavailable.")) }
    }
    private func rawState() throws -> ProfileState {
        try requireLock()
        let state = try JSONDecoder().decode(ProfileState.self, from: Disk.read(stateURL))
        let ids = Set(state.profiles.map(\.id))
        guard [1, 2].contains(state.version), ids.count == state.profiles.count,
              state.activeID.map(ids.contains) ?? (state.version == 2),
              state.profiles.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw StoreError.message(L10n.text("The account file is damaged or has an unknown version."))
        }
        if let pending = state.pending {
            let validPrevious = pending.previousID.map { ids.contains($0) && $0 != pending.id }
                ?? (state.version == 2 && state.activeID == pending.id)
            guard ids.contains(pending.id), validPrevious else { throw StoreError.message(L10n.text("Invalid pending account addition.")) }
        }
        return state
    }
    public func load() throws -> ProfileState {
        let state = try rawState()
        guard state.version == 2, state.profiles.allSatisfy({ $0.auth != nil }) else { throw StoreError.message(L10n.text("Migrate to a shared profile first.")) }
        return state
    }
    private func save(_ state: ProfileState) throws { try Disk.write(state, stateURL) }
    private func legacyData(_ id: UUID) -> URL { root.appendingPathComponent("profiles/\(id.uuidString)/data") }

    /// First launch does not inspect, capture or restart Claude.
    public func initializeEmpty() throws -> ProfileState {
        try requireLock()
        guard !needsRecovery else { throw StoreError.message(L10n.text("Recover the interrupted operation first.")) }
        if Disk.exists(stateURL) { return try load() }
        let state = ProfileState(profiles: [], activeID: nil)
        try save(state); return state
    }

    public func initialize(requireStopped: () throws -> Void, settingsBaseID: UUID? = nil,
                           checkpoint: (String) throws -> Void = { _ in }) throws -> ProfileState {
        try requireLock()
        guard !needsRecovery else { throw StoreError.message(L10n.text("Recover the interrupted operation first.")) }
        if Disk.exists(stateURL) {
            let state = try rawState()
            if state.version == 2 { return try load() }
            guard let base = settingsBaseID ?? state.settingsBaseID ?? state.activeID else { throw StoreError.message(L10n.text("Account not found.")) }
            return try migrate(state, baseID: base, requireStopped: requireStopped, checkpoint: checkpoint)
        }
        try requireStopped()
        try Disk.directory(live)
        let auth = try vault.capture(live)
        let profile = Profile(name: L10n.text("Primary"), auth: auth, organizationID: discoverOrganization(in: live, account: auth.accountID))
        let state = ProfileState(profiles: [profile], activeID: profile.id, settingsBaseID: profile.id)
        try save(state)
        return state
    }

    private func discoverOrganization(in directory: URL, account: UUID?) -> UUID? {
        guard let account else { return nil }
        return SessionTransfer.sharedTargetDirectory(in: directory, accountID: account, organizationID: nil)
            .flatMap { UUID(uuidString: $0.lastPathComponent) }
    }
    private func checkedName(_ raw: String, state: ProfileState, excluding: UUID? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw StoreError.message(L10n.text("Enter a name of 1–60 characters without line breaks.")) }
        guard !state.profiles.contains(where: { $0.id != excluding && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw StoreError.message(L10n.text("This name is already in use.")) }
        return name
    }
    public func rename(_ id: UUID, to name: String) throws -> ProfileState {
        guard !needsRecovery else { throw StoreError.message(L10n.text("Recover the interrupted operation first.")) }
        var state = try load()
        guard state.pending == nil else { throw StoreError.message(L10n.text("Finish the current operation.")) }
        guard let i = state.profiles.firstIndex(where: { $0.id == id }) else { throw StoreError.message(L10n.text("Account not found.")) }
        state.profiles[i].name = try checkedName(name, state: state, excluding: id)
        try save(state); return state
    }
    public func add(_ name: String) throws -> ProfileState {
        var state = try load()
        guard !needsRecovery, state.pending == nil else { throw StoreError.message(L10n.text("Finish the current operation.")) }
        let profile = Profile(name: try checkedName(name, state: state), auth: try vault.capture(nil))
        // With no tracked active account, explicitly adopt the current Desktop login.
        // Other additions use a blank login and a recoverable switch.
        let previous = state.activeID
        state.profiles.append(profile)
        state.pending = PendingProfile(id: profile.id, previousID: previous)
        if previous == nil { state.activeID = profile.id }
        try save(state); return state
    }
    public func finishAdding(requireStopped: () throws -> Void) throws -> ProfileState {
        var state = try load()
        guard !needsRecovery, let pending = state.pending, state.activeID == pending.id,
              let index = state.profiles.firstIndex(where: { $0.id == pending.id }) else { throw StoreError.message(L10n.text("Open the account being added first.")) }
        try requireStopped()
        let auth = try vault.capture(live, requireLogin: true)
        guard !state.profiles.contains(where: { $0.id != pending.id && $0.auth?.accountID == auth.accountID }) else { throw StoreError.message(L10n.text("This account is already saved. Sign into another account or cancel.")) }
        state.profiles[index].auth = auth
        state.profiles[index].organizationID = discoverOrganization(in: live, account: auth.accountID)
        state.pending = nil
        try requireStopped(); try save(state)
        return state
    }
    public func cancelAdding() throws -> ProfileState {
        var state = try load()
        guard let pending = state.pending else { return state }
        guard !needsRecovery, pending.previousID == nil || state.activeID == pending.previousID else { throw StoreError.message(L10n.text("Return to the previous account first.")) }
        state.profiles.removeAll { $0.id == pending.id }; state.pending = nil
        if pending.previousID == nil { state.activeID = nil }
        try save(state); return state
    }

    /// Forget the entry only. Never erase Desktop data, shared chats or recovery snapshots.
    public func remove(_ id: UUID, checkpoint: (String) throws -> Void = { _ in }) throws -> ProfileState {
        var state = try load()
        guard !needsRecovery, state.pending == nil else { throw StoreError.message(L10n.text("Finish the current operation.")) }
        guard state.profiles.contains(where: { $0.id == id }) else { throw StoreError.message(L10n.text("Account not found.")) }
        state.profiles.removeAll { $0.id == id }
        if state.activeID == id { state.activeID = nil }
        if state.settingsBaseID == id { state.settingsBaseID = nil }
        try checkpoint("before-remove-commit")
        try save(state)
        try checkpoint("remove-commit")
        return state
    }

    public func captureDetachedLogin(requireStopped: () throws -> Void) throws -> AuthReference {
        try requireLock(); try requireStopped(); return try vault.capture(live)
    }

    public func restoreDetachedLogin(_ auth: AuthReference, requireStopped: () throws -> Void,
                                     checkpoint: (String) throws -> Void = { _ in }) throws {
        guard !needsRecovery else { throw StoreError.message(L10n.text("Recover the interrupted operation first.")) }
        let original = try load()
        try requireStopped(); try vault.validate(auth)
        let source = try vault.capture(live)
        _ = try applySwitch(original: original, targetID: nil, source: source, target: auth, requireStopped: requireStopped, checkpoint: checkpoint)
    }

    @discardableResult
    public func switchProfile(to targetID: UUID, requireStopped: () throws -> Void,
                              checkpoint: (String) throws -> Void = { _ in }) throws -> ProfileState {
        guard !needsRecovery else { throw StoreError.message(L10n.text("An operation is unfinished.")) }
        var original = try load()
        guard let targetProfile = original.profiles.first(where: { $0.id == targetID }), let target = targetProfile.auth else { throw StoreError.message(L10n.text("Account not found.")) }
        let sourceIndex = original.profiles.firstIndex(where: { $0.id == original.activeID })
        if original.activeID == targetID { return original }
        try requireStopped()
        let actual = try AuthVault.account(in: live)
        if original.activeID == nil, let actual, actual == target.accountID,
           let index = original.profiles.firstIndex(where: { $0.id == targetID }) {
            // Re-adopt a currently open saved account without replacing refreshed
            // credentials with an older snapshot after the active entry was removed.
            original.profiles[index].auth = try vault.capture(live, requireLogin: true)
            original.profiles[index].organizationID = discoverOrganization(in: live, account: actual)
            original.activeID = targetID
            try requireStopped(); try save(original)
            return original
        }
        try vault.validate(target)
        if let actual, let sourceIndex, let expected = original.profiles[sourceIndex].auth?.accountID,
           actual != expected, original.pending?.id != original.activeID {
            throw StoreError.message(L10n.text("Claude was signed into another account outside Claudeway. Restore the selected login or add the account through the menu to avoid overwriting saved authentication."))
        }
        let source = try vault.capture(live)
        if source.accountID != nil, let sourceIndex {
            original.profiles[sourceIndex].auth = source
            original.profiles[sourceIndex].organizationID = discoverOrganization(in: live, account: source.accountID)
            try save(original)
        }
        return try applySwitch(original: original, targetID: targetID, source: source, target: target, requireStopped: requireStopped, checkpoint: checkpoint)
    }

    private func applySwitch(original: ProfileState, targetID: UUID?, source: AuthReference, target: AuthReference,
                             requireStopped: () throws -> Void, checkpoint: (String) throws -> Void = { _ in }) throws -> ProfileState {
        let journal = AuthJournal(original: original, targetID: targetID, source: source, target: target)
        try Disk.write(journal, journalURL)
        try checkpoint("journal")
        try vault.apply(target, to: live, requireStopped: requireStopped, checkpoint: checkpoint)
        try checkpoint("auth")
        var next = original; next.activeID = targetID
        try requireStopped(); try save(next)
        try checkpoint("commit")
        try Disk.fm.removeItem(at: journalURL); Disk.sync(root)
        return next
    }

    public func transferProjects() throws -> [TransferProject] {
        let state = try load()
        return try SessionTransfer.projects(dataRoot: live, accounts: state.profiles.compactMap { $0.auth?.accountID })
    }

    public func saveTransferSettings(_ settings: TransferSettings) throws {
        try requireLock()
        guard !needsRecovery, !needsPreparation else {
            throw StoreError.message(L10n.text("Recover the interrupted operation first."))
        }
        try settings.save(at: root)
    }

    public func transferSessions(requireStopped: () throws -> Void) throws -> SessionTransferReport {
        let settings = try TransferSettings.load(at: root)
        guard settings.mode != .disabled else { return SessionTransferReport() }
        var state = try load()
        guard !needsRecovery, let i = state.profiles.firstIndex(where: { $0.id == state.activeID }),
              let account = state.profiles[i].auth?.accountID else {
            return SessionTransferReport(note: L10n.text("Sign in to display shared history"))
        }
        try requireStopped()
        if state.profiles[i].organizationID == nil {
            state.profiles[i].organizationID = discoverOrganization(in: live, account: account)
            try save(state)
        }
        let report = try SessionTransfer.synchronizeShared(dataRoot: live,
            accounts: state.profiles.compactMap { $0.auth?.accountID }, targetAccount: account,
            targetOrganization: state.profiles[i].organizationID,
            backupRoot: root.appendingPathComponent("chat-backups"), settings: settings, requireStopped: requireStopped)
        try Disk.write(report, root.appendingPathComponent("last-chat-transfer.json"))
        return report
    }

    @discardableResult
    public func recover(requireStopped: () throws -> Void) throws -> ProfileState {
        try requireLock(); try requireStopped()
        if Disk.exists(legacyJournal) { throw StoreError.message(L10n.text("A version 1.1 switch is unfinished. Complete recovery in version 1.1 before migrating.")) }
        if Disk.exists(migrationURL) {
            let journal = try JSONDecoder().decode(MigrationJournal.self, from: Disk.read(migrationURL))
            let current = try rawState()
            if current.version == 1 {
                let backup = root.appendingPathComponent("migration-backups/\(journal.backupID.uuidString)")
                let restored = root.appendingPathComponent("restore-\(UUID().uuidString)")
                try Disk.clone(backup.appendingPathComponent("active-data"), restored)
                try requireStopped()
                if Disk.exists(live) { try Disk.move(live, backup.appendingPathComponent("interrupted-\(UUID().uuidString)")) }
                try Disk.move(restored, live)
                var restoredState = journal.original
                restoredState.settingsBaseID = journal.baseID ?? journal.original.settingsBaseID
                try save(restoredState)
            }
            try Disk.fm.removeItem(at: migrationURL); Disk.sync(root)
            return current.version == 2 ? try load() : try rawState()
        }
        guard Disk.exists(journalURL) else { return try load() }
        let journal = try JSONDecoder().decode(AuthJournal.self, from: Disk.read(journalURL))
        guard journal.version == 2, journal.original.version == 2,
              journal.targetID == nil || journal.original.profiles.contains(where: { $0.id == journal.targetID && $0.auth == journal.target }) else { throw StoreError.message(L10n.text("Invalid authentication journal.")) }
        let state = try load()
        var expected = journal.original; expected.activeID = journal.targetID
        guard state == journal.original || state == expected else { throw StoreError.message(L10n.text("The account list changed outside this operation. Data is preserved for manual recovery.")) }
        if state == journal.original {
            try vault.apply(journal.source, to: live, restoreTransient: true, requireStopped: requireStopped)
            try save(journal.original)
        } else { try vault.validate(journal.target) }
        try Disk.fm.removeItem(at: journalURL); Disk.sync(root)
        return try load()
    }

    private func migrate(_ legacy: ProfileState, baseID: UUID, requireStopped: () throws -> Void,
                         checkpoint: (String) throws -> Void) throws -> ProfileState {
        guard legacy.pending == nil, legacy.profiles.contains(where: { $0.id == baseID }) else { throw StoreError.message(L10n.text("Finish adding the account in version 1.1 before migrating.")) }
        try requireStopped()
        let backupID = UUID()
        let backup = root.appendingPathComponent("migration-backups/\(backupID.uuidString)")
        try Disk.directory(backup)
        try Disk.clone(live, backup.appendingPathComponent("active-data"))
        try Disk.write(legacy, backup.appendingPathComponent("profiles-v1.json"))
        var next = legacy; next.version = 2; next.settingsBaseID = baseID
        for i in next.profiles.indices {
            let id = next.profiles[i].id
            let data = id == legacy.activeID ? live : legacyData(id)
            let auth = try vault.capture(data, requireLogin: true)
            next.profiles[i].auth = auth
            next.profiles[i].organizationID = discoverOrganization(in: data, account: auth.accountID)
        }
        let stage = backup.appendingPathComponent("shared-prepared")
        let baseData = baseID == legacy.activeID ? live : legacyData(baseID)
        try Disk.clone(baseData, stage)
        let recursiveTrees = Set(["claude-code-sessions", "local-agent-mode-sessions", "git-shadow", "design"])
        let excluded = Set(AuthVault.parts.map { $0.split(separator: "/").first.map(String.init)! } + [AuthVault.transient, "config.json", "claude_desktop_config.json"])
        for profile in legacy.profiles where profile.id != baseID {
            let other = profile.id == legacy.activeID ? live : legacyData(profile.id)
            for filename in ["config.json", "claude_desktop_config.json"] {
                let a = stage.appendingPathComponent(filename), b = other.appendingPathComponent(filename)
                if Disk.exists(b) {
                    var preferred = Disk.exists(a) ? try Disk.object(a) : [:]
                    var incoming = try Disk.object(b)
                    if filename == "config.json" { for key in AuthVault.keys { incoming.removeValue(forKey: key) } }
                    preferred = Disk.mergeMissing(preferred, incoming)
                    try Disk.writeObject(preferred, a)
                }
            }
            for file in try Disk.fm.contentsOfDirectory(at: other, includingPropertiesForKeys: nil) {
                let name = file.lastPathComponent
                guard !excluded.contains(name), !name.hasPrefix("Singleton"), !name.hasPrefix(".auth-") else { continue }
                let destination = stage.appendingPathComponent(name)
                if !Disk.exists(destination) { try Disk.clone(file, destination) }
                else if recursiveTrees.contains(name) { try mergeTree(file, destination) }
            }
        }
        // Keep the currently selected login, even if shared settings came from a
        // different account. The first migration is the only whole-root move.
        let active = next.profiles.first { $0.id == legacy.activeID }!.auth!
        try vault.apply(active, to: stage, requireStopped: requireStopped)
        try requireStopped()
        try Disk.write(MigrationJournal(original: legacy, backupID: backupID, baseID: baseID), migrationURL)
        try checkpoint("migration-journal")
        try Disk.move(live, backup.appendingPathComponent("original-active-data"))
        try checkpoint("migration-parked")
        try Disk.move(stage, live)
        try checkpoint("migration-installed")
        try save(next)
        try checkpoint("migration-commit")
        try Disk.fm.removeItem(at: migrationURL); Disk.sync(root)
        return next
    }
    private func mergeTree(_ source: URL, _ target: URL) throws {
        for child in try Disk.fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            let destination = target.appendingPathComponent(child.lastPathComponent)
            if !Disk.exists(destination) { try Disk.clone(child, destination); continue }
            let type = try Disk.fm.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType
            let targetType = try Disk.fm.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
            if type == .typeDirectory, targetType == .typeDirectory { try mergeTree(child, destination) }
            else if child.lastPathComponent.hasPrefix("local_"), child.pathExtension == "json",
                    let a = try? Disk.object(child), let b = try? Disk.object(destination),
                    a["cliSessionId"] as? String == b["cliSessionId"] as? String,
                    let x = a["lastActivityAt"] as? Double, let y = b["lastActivityAt"] as? Double, x > y {
                try Disk.write(Disk.read(child), destination)
            }
        }
    }
}
