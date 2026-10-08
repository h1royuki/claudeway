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
    public let previousID: UUID
}
public struct ProfileState: Codable, Equatable {
    public var version = 2
    public var profiles: [Profile]
    public var activeID: UUID
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
    let targetID: UUID
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
        guard fd >= 0 else { throw StoreError.message("Не удалось открыть блокировку аккаунтов.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw StoreError.message("Claudeway уже запущен.") }
        lockFD = fd
    }
    private func requireLock() throws {
        guard lockFD >= 0 else { throw StoreError.message("Нет эксклюзивного доступа к аккаунтам.") }
    }
    private func rawState() throws -> ProfileState {
        try requireLock()
        let state = try JSONDecoder().decode(ProfileState.self, from: Disk.read(stateURL))
        let ids = Set(state.profiles.map(\.id))
        guard [1, 2].contains(state.version), !ids.isEmpty, ids.count == state.profiles.count,
              ids.contains(state.activeID), state.profiles.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw StoreError.message("Файл аккаунтов повреждён или имеет неизвестную версию.")
        }
        if let pending = state.pending {
            guard ids.contains(pending.id), ids.contains(pending.previousID), pending.id != pending.previousID else { throw StoreError.message("Некорректное добавление аккаунта.") }
        }
        return state
    }
    public func load() throws -> ProfileState {
        let state = try rawState()
        guard state.version == 2, state.profiles.allSatisfy({ $0.auth != nil }) else { throw StoreError.message("Сначала нужно перейти на общий профиль.") }
        return state
    }
    private func save(_ state: ProfileState) throws { try Disk.write(state, stateURL) }
    private func legacyData(_ id: UUID) -> URL { root.appendingPathComponent("profiles/\(id.uuidString)/data") }

    public func initialize(requireStopped: () throws -> Void, settingsBaseID: UUID? = nil,
                           checkpoint: (String) throws -> Void = { _ in }) throws -> ProfileState {
        try requireLock()
        guard !needsRecovery else { throw StoreError.message("Сначала восстановите прерванную операцию.") }
        if Disk.exists(stateURL) {
            let state = try rawState()
            if state.version == 2 { return try load() }
            return try migrate(state, baseID: settingsBaseID ?? state.settingsBaseID ?? state.activeID, requireStopped: requireStopped, checkpoint: checkpoint)
        }
        try requireStopped()
        try Disk.directory(live)
        let auth = try vault.capture(live)
        let profile = Profile(name: "Основной", auth: auth, organizationID: discoverOrganization(in: live, account: auth.accountID))
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
        guard !name.isEmpty, name.count <= 60, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw StoreError.message("Введите название от 1 до 60 символов без переносов строк.") }
        guard !state.profiles.contains(where: { $0.id != excluding && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { throw StoreError.message("Такое название уже есть.") }
        return name
    }
    public func rename(_ id: UUID, to name: String) throws -> ProfileState {
        guard !needsRecovery else { throw StoreError.message("Сначала восстановите прерванную операцию.") }
        var state = try load()
        guard let i = state.profiles.firstIndex(where: { $0.id == id }) else { throw StoreError.message("Аккаунт не найден.") }
        state.profiles[i].name = try checkedName(name, state: state, excluding: id)
        try save(state); return state
    }
    public func add(_ name: String) throws -> ProfileState {
        var state = try load()
        guard !needsRecovery, state.pending == nil else { throw StoreError.message("Завершите текущую операцию.") }
        let profile = Profile(name: try checkedName(name, state: state), auth: try vault.capture(nil))
        state.profiles.append(profile)
        state.pending = PendingProfile(id: profile.id, previousID: state.activeID)
        try save(state); return state
    }
    public func finishAdding(requireStopped: () throws -> Void) throws -> ProfileState {
        var state = try load()
        guard !needsRecovery, let pending = state.pending, state.activeID == pending.id,
              let index = state.profiles.firstIndex(where: { $0.id == pending.id }) else { throw StoreError.message("Сначала откройте добавляемый аккаунт.") }
        try requireStopped()
        let auth = try vault.capture(live, requireLogin: true)
        guard !state.profiles.contains(where: { $0.id != pending.id && $0.auth?.accountID == auth.accountID }) else { throw StoreError.message("Этот аккаунт уже сохранён. Войдите в другой или отмените добавление.") }
        state.profiles[index].auth = auth
        state.profiles[index].organizationID = discoverOrganization(in: live, account: auth.accountID)
        state.pending = nil
        try requireStopped(); try save(state)
        return state
    }
    public func cancelAdding() throws -> ProfileState {
        var state = try load()
        guard let pending = state.pending else { return state }
        guard !needsRecovery, state.activeID == pending.previousID else { throw StoreError.message("Сначала вернитесь к предыдущему аккаунту.") }
        state.profiles.removeAll { $0.id == pending.id }; state.pending = nil
        try save(state); return state
    }

    @discardableResult
    public func switchProfile(to targetID: UUID, requireStopped: () throws -> Void,
                              checkpoint: (String) throws -> Void = { _ in }) throws -> ProfileState {
        guard !needsRecovery else { throw StoreError.message("Есть незавершённая операция.") }
        var original = try load()
        guard let targetProfile = original.profiles.first(where: { $0.id == targetID }), let target = targetProfile.auth,
              let sourceIndex = original.profiles.firstIndex(where: { $0.id == original.activeID }) else { throw StoreError.message("Аккаунт не найден.") }
        if original.activeID == targetID { return original }
        try requireStopped()
        try vault.validate(target)
        let actual = try AuthVault.account(in: live)
        if let actual, let expected = original.profiles[sourceIndex].auth?.accountID,
           actual != expected, original.pending?.id != original.activeID {
            throw StoreError.message("В Claude выполнен вход в другой аккаунт вне переключателя. Верните выбранный вход или добавьте его через меню, чтобы не перезаписать сохранённую авторизацию.")
        }
        let source = try vault.capture(live)
        if source.accountID != nil {
            original.profiles[sourceIndex].auth = source
            original.profiles[sourceIndex].organizationID = discoverOrganization(in: live, account: source.accountID)
            try save(original)
        }
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

    public func transferSessions(requireStopped: () throws -> Void) throws -> SessionTransferReport {
        var state = try load()
        guard !needsRecovery, let i = state.profiles.firstIndex(where: { $0.id == state.activeID }),
              let account = state.profiles[i].auth?.accountID else {
            return SessionTransferReport(note: "Войдите в аккаунт для отображения общей истории")
        }
        try requireStopped()
        if state.profiles[i].organizationID == nil {
            state.profiles[i].organizationID = discoverOrganization(in: live, account: account)
            try save(state)
        }
        let report = try SessionTransfer.synchronizeShared(dataRoot: live,
            accounts: state.profiles.compactMap { $0.auth?.accountID }, targetAccount: account,
            targetOrganization: state.profiles[i].organizationID,
            backupRoot: root.appendingPathComponent("chat-backups"), requireStopped: requireStopped)
        try Disk.write(report, root.appendingPathComponent("last-chat-transfer.json"))
        return report
    }

    @discardableResult
    public func recover(requireStopped: () throws -> Void) throws -> ProfileState {
        try requireLock(); try requireStopped()
        if Disk.exists(legacyJournal) { throw StoreError.message("Осталось переключение версии 1.1. Завершите восстановление в версии 1.1 перед миграцией.") }
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
              journal.original.profiles.contains(where: { $0.id == journal.targetID && $0.auth == journal.target }) else { throw StoreError.message("Некорректный журнал авторизации.") }
        let state = try load()
        var expected = journal.original; expected.activeID = journal.targetID
        guard state == journal.original || state == expected else { throw StoreError.message("Список аккаунтов изменился вне операции. Данные сохранены для ручного восстановления.") }
        if state == journal.original {
            try vault.apply(journal.source, to: live, restoreTransient: true, requireStopped: requireStopped)
            try save(journal.original)
        } else { try vault.validate(journal.target) }
        try Disk.fm.removeItem(at: journalURL); Disk.sync(root)
        return try load()
    }

    private func migrate(_ legacy: ProfileState, baseID: UUID, requireStopped: () throws -> Void,
                         checkpoint: (String) throws -> Void) throws -> ProfileState {
        guard legacy.pending == nil, legacy.profiles.contains(where: { $0.id == baseID }) else { throw StoreError.message("Завершите добавление аккаунта в версии 1.1 перед миграцией.") }
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
