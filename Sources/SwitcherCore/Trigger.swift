import Foundation

public struct TriggerSettings: Codable, Equatable {
    public var enabled = false
    public var profiles = Set<UUID>()
    public init() {}
    public func save(at root: URL) throws {
        try Disk.write(self, root.appendingPathComponent("trigger-settings.json"))
    }
    public static func load(at root: URL) throws -> Self {
        let path = root.appendingPathComponent("trigger-settings.json")
        guard Disk.exists(path) else { return Self() }
        let data = try Disk.read(path)
        // Old schedule fields are ignored; retain the user's enabled/account choices.
        let value = try JSONDecoder().decode(Self.self, from: data)
        if let old = try JSONSerialization.jsonObject(with: data) as? [String: Any], old["mode"] != nil {
            let backup = root.appendingPathComponent("trigger-settings-schedule-backup.json")
            if !Disk.exists(backup) { try Disk.write(data, backup) }
            try value.save(at: root)
        }
        return value
    }
}

public enum TriggerFailure: Error, LocalizedError {
    case settings, missingCLI, incompatibleCLI, unknownWindow, exhausted, launch, storage, managed
    public var errorDescription: String? {
        switch self {
        case .managed: return L10n.text("Background requests unavailable with managed Claude Code settings")
        case .settings: return L10n.text("Could not read window-start settings")
        case .missingCLI: return L10n.text("Install Claude Code")
        case .incompatibleCLI: return L10n.text("Update Claude Code for background requests")
        case .unknownWindow: return L10n.text("Five-hour window state unknown")
        case .exhausted: return L10n.text("Limit reached — wait for reset")
        case .launch: return L10n.text("Could not launch Claude Code")
        case .storage: return L10n.text("Could not save the window-start journal")
        }
    }
}

public enum TriggerWindowState: Equatable {
    case active, idle, unknown
    public static func read(_ usage: AccountUsage, now: Date) -> Self {
        guard usage.source == "server", abs(now.timeIntervalSince(usage.observedAt)) <= 60,
              let window = usage.windows.first(where: { $0.key == "five_hour" }) else { return .unknown }
        if let reset = window.resetsAt { return reset > now ? .active : .idle }
        return window.explicitlyInactive == true ? .idle : .unknown
    }
}

// Deliberately not Codable: the token exists only while preparing/running a request.
public struct TriggerPreparation {
    public let usage: AccountUsage
    let token: String
    init(usage: AccountUsage, token: String) { self.usage = usage; self.token = token }
}
public enum TriggerSendResult { case completed, uncertain, rateLimited, rejected(String) }
public protocol TriggerBackend {
    func prepare(_ profile: Profile, allowPrompt: Bool) async throws -> TriggerPreparation
    func send(_ preparation: TriggerPreparation) async throws -> TriggerSendResult
    func usage(_ profile: Profile) async throws -> AccountUsage
}
public enum TriggerPhase: String, Codable { case checking, waiting, sending, awaiting, uncertain, confirmed, skipped, failed }
public struct TriggerRecord: Codable {
    public var phase: TriggerPhase
    public var message: String
    public var date: Date
    public var resetAt: Date?
    public var retryAt: Date?
    public var displayMessage: String { L10n.message(message) }
    public var needsVerification: Bool { [.sending, .awaiting, .uncertain].contains(phase) }
}
public struct TriggerJournal: Codable {
    public var records: [UUID: TriggerRecord] = [:]
    public init() {}

}

/// One serial queue, with a durable send barrier. All state mutation stays on the main actor.
@MainActor public final class TriggerEngine {
    public private(set) var journal: TriggerJournal
    public private(set) var running = false
    public var onChange: (() -> Void)?
    public var onUsage: ((AccountUsage) -> Void)?
    private let root: URL
    private let backend: TriggerBackend
    private let now: () -> Date
    private var journalURL: URL { root.appendingPathComponent("trigger-journal.json") }
    public init(root: URL, backend: TriggerBackend, now: @escaping () -> Date = Date.init) throws {
        self.root = root; self.backend = backend; self.now = now
        let path = root.appendingPathComponent("trigger-journal.json")
        journal = Disk.exists(path) ? try JSONDecoder().decode(TriggerJournal.self, from: Disk.read(path)) : TriggerJournal()
    }
    /// Called only with fresh successful API results, never cached/local fallback.
    public func automaticTargets(settings: TriggerSettings, profiles: [Profile], samples: [AccountUsage]) -> [UUID] {
        guard settings.enabled else { return [] }
        let date = now()
        return profiles.filter { profile in
            guard settings.profiles.contains(profile.id), let sample = samples.last(where: { $0.profileID == profile.id }),
                  matches(sample, profile), TriggerWindowState.read(sample, now: date) == .idle else { return false }
            if let record = journal.records[profile.id] {
                if let retry = record.retryAt, retry > date { return false }
                if let reset = record.resetAt, reset > date { return false }
                // A delayed usage update must never create a stream of tiny requests.
                if record.needsVerification && date.timeIntervalSince(record.date) < 5 * 3600 { return false }
                if date.timeIntervalSince(record.date) < 60 { return false }
            }
            return true
        }.map(\.id)
    }
    private func matches(_ sample: AccountUsage, _ profile: Profile) -> Bool {
        sample.accountID == profile.auth?.accountID && sample.organizationID == profile.organizationID
    }
    public func observe(_ samples: [AccountUsage], profiles: [Profile]) throws {
        guard !running else { return }
        for sample in samples {
            guard let profile = profiles.first(where: { $0.id == sample.profileID }), matches(sample, profile),
                  TriggerWindowState.read(sample, now: now()) == .active,
                  let previous = journal.records[profile.id], sample.observedAt >= previous.date,
                  let reset = sample.windows.first(where: { $0.key == "five_hour" })?.resetsAt else { continue }
            if previous.needsVerification {
                try record(profile.id, .confirmed, L10n.text("Usage window started"), resetAt: reset)
            } else if [.confirmed, .skipped].contains(previous.phase), previous.resetAt != reset {
                journal.records[profile.id]?.resetAt = reset
                try persist()
            }
        }
    }
    public func verificationTargets() -> [UUID] {
        journal.records.compactMap { id, record in
            record.needsVerification && (record.retryAt ?? .distantPast) <= now() && now().timeIntervalSince(record.date) < 5 * 3600 ? id : nil
        }
    }
    private func persist() throws {
        do { try Disk.write(journal, journalURL) } catch { throw TriggerFailure.storage }
        onChange?()
    }
    private func record(_ id: UUID, _ phase: TriggerPhase, _ message: String, retry: Date? = nil, resetAt: Date? = nil) throws {
        // Keep the original send date so reconciliation has a bounded lifetime.
        let original = journal.records[id]
        let date = (phase == .awaiting || phase == .uncertain) && original?.needsVerification == true ? original!.date : now()
        journal.records[id] = TriggerRecord(phase: phase, message: L10n.canonicalMessage(message), date: date, resetAt: resetAt, retryAt: retry)
        try persist()
    }
    private func saveUsage(_ value: AccountUsage) {
        onUsage?(value)
    }
    public func run(profiles: [Profile], ids: [UUID], automatic: Bool = false, verifyOnly: Bool = false, allowPrompt: Bool = false) async throws {
        guard !running else { return }
        running = true; onChange?()
        defer { running = false; onChange?() }
        let unique = Set(ids)
        for profile in profiles where unique.contains(profile.id) {
            let id = profile.id
            let previous = journal.records[id]
            if !verifyOnly, let previous, !previous.needsVerification,
               previous.phase != .checking, now().timeIntervalSince(previous.date) < 60 { continue }
            let reconcile = verifyOnly || (previous?.needsVerification == true && (now().timeIntervalSince(previous!.date) < 5 * 3600))
            if let retry = previous?.retryAt, retry > now() { continue }
            var polling = UsagePolling.load(at: root.appendingPathComponent("usage-polling.json"))
            if let until = polling.blockedDate(id), until > now() {
                if !reconcile { try record(id, .waiting, L10n.text("Claude asks you to wait"), retry: until) }
                continue
            }
            do {
                if reconcile {
                    let sample = try await backend.usage(profile); saveUsage(sample)
                    if TriggerWindowState.read(sample, now: now()) == .active {
                        try record(id, .confirmed, L10n.text("Usage window started"), resetAt: sample.windows.first(where: { $0.key == "five_hour" })?.resetsAt)
                    } else {
                        try record(id, .uncertain, L10n.text("Request may have completed — window not confirmed"), retry: now().addingTimeInterval(300))
                    }
                    continue
                }
                try record(id, .checking, L10n.text("Checking usage…"))
                polling.started(id, now: now()); polling.save(at: root.appendingPathComponent("usage-polling.json"))
                let prepared = try await backend.prepare(profile, allowPrompt: allowPrompt)
                saveUsage(prepared.usage)
                switch TriggerWindowState.read(prepared.usage, now: now()) {
                case .active:
                    try record(id, .skipped, L10n.text("Usage window already active"), resetAt: prepared.usage.windows.first(where: { $0.key == "five_hour" })?.resetsAt); continue
                case .unknown: throw TriggerFailure.unknownWindow
                case .idle: break
                }
                if let reset = previous?.resetAt, reset > now() {
                    try record(id, .skipped, L10n.text("Waiting for a confirmed reset time"), resetAt: reset); continue
                }
                if prepared.usage.windows.contains(where: { $0.key != "five_hour" && $0.usedPercent >= 100 && ($0.resetsAt == nil || $0.resetsAt! > now()) }) { throw TriggerFailure.exhausted }
                // This write MUST succeed before launching any process that could send.
                try record(id, .sending, L10n.text("Sending a short request…"))
                let outcome = try await backend.send(prepared)
                switch outcome {
                case .completed:
                    try record(id, .awaiting, L10n.text("Request completed, waiting for usage update"))
                case .uncertain:
                    try record(id, .uncertain, L10n.text("Request may have completed — checking usage"))
                case .rateLimited:
                    polling.rateLimited(id, delay: 900, now: now()); polling.save(at: root.appendingPathComponent("usage-polling.json"))
                    try record(id, .failed, L10n.text("Claude asks you to wait"), retry: now().addingTimeInterval(900)); continue
                case .rejected(let message):
                    try record(id, .failed, message, retry: now().addingTimeInterval(300)); continue
                }
                let sample = try await backend.usage(profile); saveUsage(sample)
                if TriggerWindowState.read(sample, now: now()) == .active {
                    try record(id, .confirmed, L10n.text("Usage window started"), resetAt: sample.windows.first(where: { $0.key == "five_hour" })?.resetsAt)
                } else {
                    let phase = journal.records[id]!.phase
                    try record(id, phase, journal.records[id]!.message, retry: now().addingTimeInterval(60))
                }
            } catch {
                // Storage failure must stop the whole queue, never silently drop a barrier.
                if case TriggerFailure.storage = error { throw TriggerFailure.storage }
                let message = (error as? UsageFailure)?.errorDescription ?? (error as? TriggerFailure)?.errorDescription ?? L10n.text("Could not start the window")
                var retry: Date? = nil
                var network = false
                if let failure = error as? UsageFailure {
                    if case .network = failure { retry = now().addingTimeInterval(60); network = true }
                    if case .rateLimited(let delay) = failure {
                        retry = now().addingTimeInterval(delay); network = true
                        polling.rateLimited(id, delay: delay, now: now()); polling.save(at: root.appendingPathComponent("usage-polling.json"))
                    }
                }
                if journal.records[id]?.needsVerification == true {
                    try record(id, .uncertain, L10n.text("Request may have completed · ") + message, retry: retry ?? now().addingTimeInterval(300))
                } else {
                    try record(id, network ? .waiting : .failed, message, retry: retry ?? now().addingTimeInterval(60))
                }
            }
        }
    }
}
