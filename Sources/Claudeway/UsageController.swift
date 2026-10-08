import Foundation
import SwitcherCore

@MainActor final class UsageController {
    private(set) var values: [UUID: AccountUsage] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var refreshing = false
    var onChange: (() -> Void)?
    var onRefreshCompleted: (([AccountUsage]) -> Void)?
    private let root: URL
    private let live: URL
    private var task: Task<Void, Never>?
    private var generation = 0
    private var polling = UsagePolling()
    private var cacheLoaded = false
    private let demo: Bool
    init(root: URL, live: URL, demo: Bool) { self.root = root; self.live = live; self.demo = demo }

    func refresh(_ state: ProfileState, force: Bool = false, allowKeychainPrompt: Bool = false) {
        guard !refreshing else { return }
        let cacheURL = root.appendingPathComponent("usage-cache.json")
        if !cacheLoaded {
            values = UsageCache.load(at: cacheURL, profiles: state.profiles)
            polling = UsagePolling.load(at: root.appendingPathComponent("usage-polling.json"))
            cacheLoaded = true
        }
        if demo {
            for (index, profile) in state.profiles.enumerated() {
                guard let account = profile.auth?.accountID else { continue }
                let now = Date()
                values[profile.id] = AccountUsage(profileID: profile.id, accountID: account, organizationID: profile.organizationID ?? UUID(), observedAt: now, source: "demo", windows: [
                    UsageWindow(key: "five_hour", title: L10n.text("5 h"), usedPercent: index == 0 ? 72 : 18, resetsAt: now.addingTimeInterval(index == 0 ? 5040 : 11400)),
                    UsageWindow(key: "seven_day", title: L10n.text("Wk"), usedPercent: index == 0 ? 41 : 63, resetsAt: now.addingTimeInterval(index == 0 ? 240000 : 410000))])
            }
            onChange?(); return
        }
        for profile in state.profiles {
            // History identifies an organization, not a person. Never guess when two
            // saved logins share that organization.
            guard let org = profile.organizationID,
                  state.profiles.filter({ $0.organizationID == org }).count == 1 else { continue }
            let paths = [live.appendingPathComponent("plan-usage-history.json"), root.appendingPathComponent("profiles/\(profile.id.uuidString)/data/plan-usage-history.json")]
            for path in paths {
                guard path.standardizedFileURL == path.resolvingSymlinksInPath().standardizedFileURL,
                      let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8_000_000,
                      let data = try? Data(contentsOf: path), let sample = try? UsageParser.history(data, profile: profile) else { continue }
                if values[profile.id]?.source != "server", values[profile.id].map({ $0.observedAt < sample.observedAt }) ?? true { values[profile.id] = sample }
            }
        }
        let now = Date()
        let targets = state.profiles.filter { profile in
            guard profile.id != state.pending?.id else { return false }
            return polling.allows(profile.id, force: force, now: now)
        }
        guard !targets.isEmpty else { onChange?(); return }
        refreshing = true
        onChange?()
        let current = generation
        task = Task { [weak self] in
            guard let self else { return }
            var samples: [AccountUsage] = []
            var promptAllowed = allowKeychainPrompt
            for profile in targets {
                guard !Task.isCancelled, self.generation == current else { return }
                self.polling.started(profile.id)
                self.polling.save(at: self.root.appendingPathComponent("usage-polling.json"))
                do {
                    let sample = try await UsageClient().fetch(profile: profile, activeID: state.activeID, root: self.root, live: self.live, allowKeychainPrompt: promptAllowed)
                    guard !Task.isCancelled, self.generation == current else { return }
                    samples.append(sample)
                    self.values[profile.id] = sample
                    self.errors.removeValue(forKey: profile.id)
                    try? UsageCache.save(self.values, at: cacheURL)
                } catch {
                    guard !Task.isCancelled, self.generation == current else { return }
                    let failure = error as? UsageFailure ?? .unavailable
                    self.errors[profile.id] = failure.errorDescription
                    if case .rateLimited(let seconds) = failure {
                        self.polling.rateLimited(profile.id, delay: seconds)
                        self.polling.save(at: self.root.appendingPathComponent("usage-polling.json"))
                    }
                    if case .keychain = failure { promptAllowed = false }
                }
                // Only public error labels and statistics; useful when a background
                // request fails while the menu is closed. No request/response bodies.
                let statuses = self.errors.mapValues { $0 }
                if let data = try? JSONEncoder().encode(statuses) {
                    try? data.write(to: self.root.appendingPathComponent("usage-status.json"), options: [.atomic, .completeFileProtection])
                }
                self.onChange?()
            }
            self.refreshing = false
            self.task = nil
            self.onChange?()
            self.onRefreshCompleted?(samples)
        }
    }

    func accept(_ value: AccountUsage) {
        values[value.profileID] = value
        errors.removeValue(forKey: value.profileID)
        try? UsageCache.save(values, at: root.appendingPathComponent("usage-cache.json"))
        onChange?()
    }
    func reloadPolling() { polling = UsagePolling.load(at: root.appendingPathComponent("usage-polling.json")) }

    func pause() {
        generation += 1
        task?.cancel(); task = nil; refreshing = false
    }
}
