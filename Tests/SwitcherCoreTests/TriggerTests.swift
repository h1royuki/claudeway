import Foundation
@testable import SwitcherCore

private final class TriggerStub: TriggerBackend {
    var sample: AccountUsage!
    var after: AccountUsage!
    var prepares = 0, sends = 0, reads = 0
    var failure: Error?
    var outcome: TriggerSendResult = .completed
    var delay: UInt64 = 0
    func prepare(_ profile: Profile, allowPrompt: Bool) async throws -> TriggerPreparation {
        prepares += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let failure { throw failure }
        return TriggerPreparation(usage: sample, token: "FAKE-trigger-credential")
    }
    func send(_ preparation: TriggerPreparation) async throws -> TriggerSendResult { sends += 1; return outcome }
    func usage(_ profile: Profile) async throws -> AccountUsage { reads += 1; return after }
}
private final class TriggerClock { var date = Date(timeIntervalSince1970: 1800000000) }

@MainActor final class TriggerTests {
    private let clock = TriggerClock()
    let profile = Profile(name: "Test", auth: AuthReference(generation: UUID(), accountID: UUID()), organizationID: UUID())
    func sample(_ state: TriggerWindowState) -> AccountUsage {
        AccountUsage(profileID: profile.id, accountID: profile.auth!.accountID!, organizationID: profile.organizationID!, observedAt: clock.date, source: "server", windows:
            state == .unknown ? [] : [UsageWindow(key: "five_hour", title: "5 ч", usedPercent: state == .active ? 10 : 0, resetsAt: state == .active ? clock.date.addingTimeInterval(3600) : nil, explicitlyInactive: state == .idle)])
    }
    func runAll() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TriggerTests-\(UUID())")
        try Disk.directory(root); defer { try? FileManager.default.removeItem(at: root) }
        func directory() throws -> URL { let d = root.appendingPathComponent(UUID().uuidString); try Disk.directory(d); return d }
        var settings = TriggerSettings()
        XCTAssertFalse(settings.enabled); XCTAssertTrue(settings.profiles.isEmpty)
        settings.enabled = true; settings.profiles = [profile.id]
        try settings.save(at: root); XCTAssertEqual(try TriggerSettings.load(at: root), settings)
        let legacy = try JSONSerialization.data(withJSONObject: ["enabled": true, "profiles": [profile.id.uuidString], "mode": "firstUse", "hour": 8, "minute": 0, "weekdays": [2]])
        try Disk.write(legacy, root.appendingPathComponent("trigger-settings.json"))
        XCTAssertEqual(try TriggerSettings.load(at: root), settings)
        let migrated = try Disk.object(root.appendingPathComponent("trigger-settings.json"))
        XCTAssertNil(migrated["hour"]); XCTAssertNil(migrated["mode"]); XCTAssertNil(migrated["weekdays"])
        XCTAssertEqual(try Disk.read(root.appendingPathComponent("trigger-settings-schedule-backup.json")), legacy)
        print("PASS schedule removal migrates enabled/account choices, with a legacy backup")

        let idle = try UsageParser.windows(from: Data(#"{"five_hour":null}"#.utf8))
        XCTAssertEqual(idle.first?.explicitlyInactive, true)
        let modern = try UsageParser.windows(from: Data(#"{"five_hour":{"utilization":0,"resets_at":null},"limits":[{"kind":"session","is_active":false,"percent":0,"resets_at":null}]}"#.utf8))
        XCTAssertEqual(modern.first?.explicitlyInactive, true)
        let unknown = try UsageParser.windows(from: Data(#"{"five_hour":{"utilization":0}}"#.utf8))
        XCTAssertNil(unknown.first?.explicitlyInactive)
        XCTAssertEqual(TriggerWindowState.read(sample(.active), now: clock.date), .active)
        XCTAssertEqual(TriggerWindowState.read(sample(.idle), now: clock.date), .idle)
        XCTAssertEqual(TriggerWindowState.read(sample(.unknown), now: clock.date), .unknown)
        XCTAssertEqual(TriggerWindowState.read(sample(.idle), now: clock.date.addingTimeInterval(61)), .unknown)
        print("PASS idle versus missing window, explicit null and fresh server state")

        let backend = TriggerStub(); backend.sample = sample(.idle); backend.after = sample(.active)
        let sendRoot = try directory()
        let engine = try TriggerEngine(root: sendRoot, backend: backend, now: { self.clock.date })
        try await engine.run(profiles: [profile], ids: [profile.id, profile.id])
        XCTAssertEqual(backend.sends, 1); XCTAssertEqual(engine.journal.records[profile.id]?.phase, .confirmed)
        let encoded = try String(contentsOf: sendRoot.appendingPathComponent("trigger-journal.json"))
        XCTAssertFalse(encoded.contains("FAKE-trigger-credential"))
        let attributes = try FileManager.default.attributesOfItem(atPath: sendRoot.appendingPathComponent("trigger-journal.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let restarted = try TriggerEngine(root: sendRoot, backend: backend, now: { self.clock.date })
        try await restarted.run(profiles: [profile], ids: [profile.id], automatic: true)
        XCTAssertEqual(backend.sends, 1)
        print("PASS single send, server confirmation, restart deduplication and private secret-free journal")

        backend.sample = sample(.active)
        let skip = try TriggerEngine(root: directory(), backend: backend, now: { self.clock.date })
        try await skip.run(profiles: [profile], ids: [profile.id])
        XCTAssertEqual(skip.journal.records[profile.id]?.phase, .skipped); XCTAssertEqual(backend.sends, 1)
        backend.sample = sample(.unknown)
        let unknownEngine = try TriggerEngine(root: directory(), backend: backend, now: { self.clock.date })
        try await unknownEngine.run(profiles: [profile], ids: [profile.id])
        XCTAssertEqual(unknownEngine.journal.records[profile.id]?.phase, .failed); XCTAssertEqual(backend.sends, 1)
        for failure: Error in [UsageFailure.login, UsageFailure.identity, TriggerFailure.missingCLI] {
            backend.failure = failure
            let failed = try TriggerEngine(root: directory(), backend: backend, now: { self.clock.date })
            try await failed.run(profiles: [profile], ids: [profile.id])
            XCTAssertEqual(failed.journal.records[profile.id]?.phase, .failed)
        }
        XCTAssertEqual(backend.sends, 1); backend.failure = nil
        print("PASS active window skip, unknown state, expired login, wrong identity and missing CLI")

        let offlineRoot = try directory(), offline = TriggerStub(); offline.failure = UsageFailure.network
        let retryEngine = try TriggerEngine(root: offlineRoot, backend: offline, now: { self.clock.date })
        try await retryEngine.run(profiles: [profile], ids: [profile.id], automatic: true)
        XCTAssertEqual(retryEngine.journal.records[profile.id]?.phase, .waiting)
        XCTAssertTrue(retryEngine.automaticTargets(settings: settings, profiles: [profile], samples: [sample(.idle)]).isEmpty)
        clock.date = clock.date.addingTimeInterval(61)
        XCTAssertEqual(retryEngine.automaticTargets(settings: settings, profiles: [profile], samples: [sample(.idle)]), [profile.id])
        XCTAssertTrue(retryEngine.automaticTargets(settings: settings, profiles: [profile], samples: []).isEmpty)
        let rateRoot = try directory(); offline.failure = UsageFailure.rateLimited(7200)
        let rate = try TriggerEngine(root: rateRoot, backend: offline, now: { self.clock.date })
        try await rate.run(profiles: [profile], ids: [profile.id])
        let tries = offline.prepares
        try await rate.run(profiles: [profile], ids: [profile.id])
        XCTAssertEqual(offline.prepares, tries)
        XCTAssertEqual(UsagePolling.load(at: rateRoot.appendingPathComponent("usage-polling.json")).blockedDate(profile.id), clock.date.addingTimeInterval(7200))
        print("PASS offline retry requires new usage; no action on failed refresh; persisted Retry-After")

        for phase in [TriggerPhase.checking, .sending, .awaiting, .uncertain] {
            let crashRoot = try directory(), stub = TriggerStub()
            stub.sample = sample(.idle); stub.after = sample(.idle)
            var journal = TriggerJournal()
            journal.records[profile.id] = TriggerRecord(phase: phase, message: "Test crash", date: clock.date)
            try Disk.write(journal, crashRoot.appendingPathComponent("trigger-journal.json"))
            let recovered = try TriggerEngine(root: crashRoot, backend: stub, now: { self.clock.date })
            try await recovered.run(profiles: [profile], ids: [profile.id], verifyOnly: phase != .checking)
            XCTAssertEqual(stub.sends, phase == .checking ? 1 : 0)
            if phase != .checking { XCTAssertEqual(recovered.journal.records[profile.id]?.phase, .uncertain) }
        }
        print("PASS recovery before and after durable send barrier, no duplicate on ambiguous result")

        let cyclesBackend = TriggerStub()
        let cycles = try TriggerEngine(root: directory(), backend: cyclesBackend, now: { self.clock.date })
        XCTAssertTrue(cycles.automaticTargets(settings: settings, profiles: [profile], samples: [sample(.active)]).isEmpty)
        XCTAssertTrue(cycles.automaticTargets(settings: settings, profiles: [profile], samples: [sample(.unknown)]).isEmpty)
        let stale = sample(.idle); clock.date = clock.date.addingTimeInterval(61)
        XCTAssertTrue(cycles.automaticTargets(settings: settings, profiles: [profile], samples: [stale]).isEmpty)
        let alien = AccountUsage(profileID: profile.id, accountID: UUID(), organizationID: profile.organizationID!, observedAt: clock.date, source: "server", windows: sample(.idle).windows)
        XCTAssertTrue(cycles.automaticTargets(settings: settings, profiles: [profile], samples: [alien]).isEmpty)
        var disabled = settings; disabled.enabled = false
        XCTAssertTrue(cycles.automaticTargets(settings: disabled, profiles: [profile], samples: [sample(.idle)]).isEmpty)
        disabled = settings; disabled.profiles = []
        XCTAssertTrue(cycles.automaticTargets(settings: disabled, profiles: [profile], samples: [sample(.idle)]).isEmpty)
        for _ in 0..<2 {
            cyclesBackend.sample = sample(.idle); cyclesBackend.after = sample(.active)
            let selected = cycles.automaticTargets(settings: settings, profiles: [profile], samples: [sample(.idle)])
            XCTAssertEqual(selected, [profile.id])
            try await cycles.run(profiles: [profile], ids: selected, automatic: true)
            clock.date = clock.date.addingTimeInterval(120)
            XCTAssertTrue(cycles.automaticTargets(settings: settings, profiles: [profile], samples: [sample(.idle)]).isEmpty)
            clock.date = clock.date.addingTimeInterval(3601)
        }
        XCTAssertEqual(cyclesBackend.sends, 2)
        print("PASS repeated resets within one day; active/stale/unknown/wrong-account/disabled samples cannot trigger")

        let delayedBackend = TriggerStub(), delayedRoot = try directory()
        delayedBackend.sample = sample(.idle); delayedBackend.after = sample(.idle)
        let delayed = try TriggerEngine(root: delayedRoot, backend: delayedBackend, now: { self.clock.date })
        try await delayed.run(profiles: [profile], ids: [profile.id])
        clock.date = clock.date.addingTimeInterval(301)
        let restored = try TriggerEngine(root: delayedRoot, backend: delayedBackend, now: { self.clock.date })
        XCTAssertTrue(restored.automaticTargets(settings: settings, profiles: [profile], samples: [sample(.idle)]).isEmpty)
        try restored.observe([sample(.active)], profiles: [profile])
        XCTAssertEqual(restored.journal.records[profile.id]?.phase, .confirmed)
        XCTAssertEqual(delayedBackend.sends, 1)
        clock.date = clock.date.addingTimeInterval(3601)
        XCTAssertEqual(restored.automaticTargets(settings: settings, profiles: [profile], samples: [sample(.idle)]), [profile.id])
        // Upgrade an old in-flight journal without losing its durable send barrier.
        let oldRecord = #"{"records":["\#(profile.id.uuidString)",{"phase":"sending","message":"Old pending request","date":\#(clock.date.timeIntervalSinceReferenceDate),"day":"2026-10-07"}],"consumed":[]}"#
        try Disk.write(Data(oldRecord.utf8), delayedRoot.appendingPathComponent("trigger-journal.json"))
        let upgraded = try TriggerEngine(root: delayedRoot, backend: delayedBackend, now: { self.clock.date })
        XCTAssertTrue(upgraded.automaticTargets(settings: settings, profiles: [profile], samples: [sample(.idle)]).isEmpty)
        clock.date = clock.date.addingTimeInterval(5 * 3600 + 1)
        XCTAssertEqual(upgraded.automaticTargets(settings: settings, profiles: [profile], samples: [sample(.idle)]), [profile.id])
        print("PASS delayed confirmation, restart and old journal migration prevent duplicate sends without daily lockout")

        let busyBackend = TriggerStub(); busyBackend.sample = sample(.idle); busyBackend.after = sample(.active); busyBackend.delay = 100_000_000
        let busy = try TriggerEngine(root: directory(), backend: busyBackend, now: { self.clock.date })
        let first = Task { try await busy.run(profiles: [self.profile], ids: [self.profile.id]) }
        await Task.yield()
        try await busy.run(profiles: [profile], ids: [profile.id])
        try await first.value
        XCTAssertEqual(busyBackend.sends, 1)
        let badRoot = try directory(); try Disk.directory(badRoot.appendingPathComponent("trigger-journal.json"))
        XCTAssertThrowsError(try TriggerEngine(root: badRoot, backend: backend))
        let failRoot = try directory(), fail = try TriggerEngine(root: failRoot, backend: busyBackend)
        try Disk.directory(failRoot.appendingPathComponent("trigger-journal.json"))
        do { try await fail.run(profiles: [profile], ids: [profile.id]); XCTFail("Storage barrier ignored") } catch {}
        XCTAssertEqual(busyBackend.sends, 1)
        print("PASS overlapping clicks coalesced and unreadable/unwritable journal fails closed")

        let env = TriggerProcess.environment(token: "FAKE", config: root)
        XCTAssertNil(env["ANTHROPIC_API_KEY"]); XCTAssertNil(env["ANTHROPIC_BASE_URL"]); XCTAssertNil(env["CLAUDE_CODE_USE_BEDROCK"])
        XCTAssertEqual(env["CLAUDE_CODE_OAUTH_TOKEN"], "FAKE")
        XCTAssertTrue(TriggerProcess.arguments.contains("--safe-mode")); XCTAssertTrue(TriggerProcess.arguments.contains("--no-session-persistence"))
        let child = try await TriggerProcess.child(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["OK"], environment: [:], directory: root, timeout: 2)
        XCTAssertEqual(String(decoding: child.data, as: UTF8.self), "OK")
        let timeout = try await TriggerProcess.child(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: [:], directory: root, timeout: 0.1)
        XCTAssertTrue(timeout.timedOut)
        print("PASS isolated child environment, output capture and bounded process timeout")
    }
}
