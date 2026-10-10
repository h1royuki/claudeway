import Foundation
import SwitcherCore

private enum Injected: Error { case failure }

final class ProfileStoreTests: TestCase {
    var root: URL!
    var store: ProfileStore!
    var a: UUID!
    var b: UUID!
    let accountA = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    let accountB = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SharedClaudeTests-\(UUID().uuidString)")
        store = ProfileStore(root: root.appendingPathComponent("Switcher"), live: root.appendingPathComponent("Claude"))
        try store.acquireLock()
        try login(accountA, token: "A")
        a = try store.initialize(requireStopped: {}).activeID
        b = try store.add("B").pending!.id
        try store.switchProfile(to: b, requireStopped: {})
        try login(accountB, token: "B")
        _ = try store.finishAdding(requireStopped: {})
        try store.switchProfile(to: a, requireStopped: {})
        try Data("shared-config".utf8).write(to: store.live.appendingPathComponent("claude_desktop_config.json"))
        try Data("shared-artifact".utf8).write(to: store.live.appendingPathComponent("artifact.txt"))
    }
    override func tearDownWithError() throws {
        store = nil
        if let root { try FileManager.default.removeItem(at: root) }
    }
    func login(_ account: UUID, token: String) throws {
        try FileManager.default.createDirectory(at: store.live, withIntermediateDirectories: true)
        var object: [String: Any] = ["theme": "shared", "preferences": ["keep": true]]
        if let data = try? Data(contentsOf: store.live.appendingPathComponent("config.json")), let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { object = old }
        object["lastKnownAccountUuid"] = account.uuidString
        object["oauth:tokenCache"] = "encrypted-\(token)"
        object["oauth:tokenCacheV2"] = "encrypted-v2-\(token)"
        try JSONSerialization.data(withJSONObject: object).write(to: store.live.appendingPathComponent("config.json"))
        try Data("cookies-\(token)".utf8).write(to: store.live.appendingPathComponent("Cookies"))
        let dir = store.live.appendingPathComponent("Local Storage/leveldb")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("storage-\(token)".utf8).write(to: dir.appendingPathComponent("test.ldb"))
    }
    func config() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: store.live.appendingPathComponent("config.json"))) as! [String: Any] }
    func token() throws -> String? { try config()["oauth:tokenCache"] as? String }

    func testStoredTransferPolicyUsedAcrossAccounts() throws {
        let org = UUID().uuidString
        let source = store.live.appendingPathComponent("claude-code-sessions/\(accountA.uuidString)/\(org)")
        let target = store.live.appendingPathComponent("claude-code-sessions/\(accountB.uuidString)/\(org)")
        for directory in [source, target] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let id = "local_" + UUID().uuidString
        var chat: [String: Any] = ["sessionId": id, "cliSessionId": UUID().uuidString, "cwd": "/tmp/chosen", "lastActivityAt": 100, "completedTurns": 1]
        let sourceFile = source.appendingPathComponent(id + ".json"), targetFile = target.appendingPathComponent(id + ".json")
        try JSONSerialization.data(withJSONObject: chat).write(to: sourceFile)
        var settings = TransferSettings(); settings.mode = .selected; settings.projects = ["/tmp/other"]
        try store.saveTransferSettings(settings)
        try store.switchProfile(to: b, requireStopped: {})
        XCTAssertEqual(try store.transferSessions(requireStopped: {}).added, 0)
        settings.projects = ["/tmp/chosen"]; try store.saveTransferSettings(settings)
        XCTAssertEqual(try store.transferSessions(requireStopped: {}).added, 1)
        chat["lastActivityAt"] = 200
        try JSONSerialization.data(withJSONObject: chat).write(to: targetFile)
        let before = try Data(contentsOf: sourceFile)
        settings.mode = .disabled; try store.saveTransferSettings(settings)
        try store.switchProfile(to: a, requireStopped: {})
        XCTAssertEqual(try store.transferSessions(requireStopped: {}).updated, 0)
        XCTAssertEqual(try Data(contentsOf: sourceFile), before)
        settings.mode = .selected; try store.saveTransferSettings(settings)
        XCTAssertEqual(try store.transferSessions(requireStopped: {}).updated, 1)
        XCTAssertEqual(try store.transferProjects(), [TransferProject(path: "/tmp/chosen", chatCount: 1)])
        try Data("invalid".utf8).write(to: store.root.appendingPathComponent("chat-transfer-settings.json"))
        XCTAssertThrowsError(try store.transferSessions(requireStopped: {}))
    }

    func testRoundTripKeepsCommonRootAndSettings() throws {
        let inode = try FileManager.default.attributesOfItem(atPath: store.live.path)[.systemFileNumber] as? NSNumber
        let settings = try Data(contentsOf: store.live.appendingPathComponent("claude_desktop_config.json"))
        try store.switchProfile(to: b, requireStopped: {})
        XCTAssertEqual(try token(), "encrypted-B")
        XCTAssertEqual(try String(contentsOf: store.live.appendingPathComponent("Cookies")), "cookies-B")
        XCTAssertEqual(try config()["theme"] as? String, "shared")
        try store.switchProfile(to: a, requireStopped: {})
        XCTAssertEqual(try token(), "encrypted-A")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.live.path)[.systemFileNumber] as? NSNumber, inode)
        XCTAssertEqual(try Data(contentsOf: store.live.appendingPathComponent("claude_desktop_config.json")), settings)
        XCTAssertEqual(try String(contentsOf: store.live.appendingPathComponent("artifact.txt")), "shared-artifact")
    }
    func testEveryAuthCheckpointRecovers() throws {
        let points = ["journal", "config", "Cookies", "Cookies-journal", "Cookies-wal", "Cookies-shm", "Network/Cookies", "Network/Cookies-journal", "Network/Cookies-wal", "Network/Cookies-shm", "Local Storage", "Session Storage", "IndexedDB", "bridge-state.json", "auth", "commit"]
        for point in points {
            XCTAssertThrowsError(try store.switchProfile(to: b, requireStopped: {}, checkpoint: { if $0 == point { throw Injected.failure } }))
            let recovered = try store.recover(requireStopped: {})
            XCTAssertEqual(recovered.activeID, point == "commit" ? b : a)
            XCTAssertEqual(try token(), point == "commit" ? "encrypted-B" : "encrypted-A")
            XCTAssertFalse(store.needsRecovery)
            if point == "commit" { try store.switchProfile(to: a, requireStopped: {}) }
        }
    }
    func testRefreshedCredentialsAreCapturedBeforeLeaving() throws {
        try login(accountA, token: "A-refreshed")
        try store.switchProfile(to: b, requireStopped: {})
        try store.switchProfile(to: a, requireStopped: {})
        XCTAssertEqual(try token(), "encrypted-A-refreshed")
    }
    func testCommonPreferenceEditSurvivesBothAccounts() throws {
        var c = try config(); c["theme"] = "new-theme"
        try JSONSerialization.data(withJSONObject: c).write(to: store.live.appendingPathComponent("config.json"))
        try store.switchProfile(to: b, requireStopped: {})
        XCTAssertEqual(try config()["theme"] as? String, "new-theme")
        try store.switchProfile(to: a, requireStopped: {})
        XCTAssertEqual(try config()["theme"] as? String, "new-theme")
    }
    func testAddAndCancelPreserveSettingsWithoutLogout() throws {
        let p = try store.add("New").pending!
        try store.switchProfile(to: p.id, requireStopped: {})
        XCTAssertNil(try token())
        XCTAssertEqual(try config()["theme"] as? String, "shared")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.live.appendingPathComponent("Cookies").path))
        XCTAssertThrowsError(try store.finishAdding(requireStopped: {}))
        try store.switchProfile(to: p.previousID!, requireStopped: {})
        let result = try store.cancelAdding()
        XCTAssertNil(result.pending)
        XCTAssertEqual(result.profiles.count, 2)
        XCTAssertEqual(try token(), "encrypted-A")
    }
    func testDuplicateLoginCannotBeRegistered() throws {
        let p = try store.add("Duplicate").pending!
        try store.switchProfile(to: p.id, requireStopped: {})
        try login(accountA, token: "A-again")
        XCTAssertThrowsError(try store.finishAdding(requireStopped: {}))
        XCTAssertTrue(try store.load().pending != nil)
    }
    func testExternalLoginCannotOverwriteNamedAccount() throws {
        try login(UUID(), token: "unexpected")
        XCTAssertThrowsError(try store.switchProfile(to: b, requireStopped: {}))
        XCTAssertFalse(store.needsRecovery)
        XCTAssertEqual(try token(), "encrypted-unexpected")
    }
    func testDamagedAuthSnapshotFailsBeforeMutation() throws {
        let snapshot = try store.load().profiles.first { $0.id == b }!.auth!
        let file = store.root.appendingPathComponent("auth-snapshots/\(snapshot.generation.uuidString)/Cookies")
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try store.switchProfile(to: b, requireStopped: {}))
        XCTAssertFalse(store.needsRecovery)
        XCTAssertEqual(try token(), "encrypted-A")
    }
    func testRunningClaudeBlocksSwitchAndRecovery() throws {
        XCTAssertThrowsError(try store.switchProfile(to: b, requireStopped: { throw Injected.failure }))
        XCTAssertFalse(store.needsRecovery)
        XCTAssertThrowsError(try store.switchProfile(to: b, requireStopped: {}, checkpoint: { if $0 == "config" { throw Injected.failure } }))
        XCTAssertThrowsError(try store.recover(requireStopped: { throw Injected.failure }))
        XCTAssertTrue(store.needsRecovery)
        XCTAssertEqual(try store.recover(requireStopped: {}).activeID, a)
    }
    func testRecoveryItselfCanBeInterrupted() throws {
        XCTAssertThrowsError(try store.switchProfile(to: b, requireStopped: {}, checkpoint: { if $0 == "auth" { throw Injected.failure } }))
        var count = 0
        XCTAssertThrowsError(try store.recover(requireStopped: { count += 1; if count == 5 { throw Injected.failure } }))
        XCTAssertEqual(try store.recover(requireStopped: {}).activeID, a)
        XCTAssertEqual(try token(), "encrypted-A")
    }
    func testVolatileBridgeIsNotRestoredOnNormalSwitch() throws {
        try Data("old-bridge".utf8).write(to: store.live.appendingPathComponent("bridge-state.json"))
        try store.switchProfile(to: b, requireStopped: {})
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.live.appendingPathComponent("bridge-state.json").path))
        try store.switchProfile(to: a, requireStopped: {})
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.live.appendingPathComponent("bridge-state.json").path))
    }
    func testSameAccountIsNoop() throws {
        try store.switchProfile(to: a, requireStopped: { XCTFail("must not stop") })
        XCTAssertFalse(store.needsRecovery)
    }
    func testLockNamesAndPendingState() throws {
        let other = ProfileStore(root: store.root, live: store.live)
        XCTAssertThrowsError(try other.acquireLock())
        XCTAssertThrowsError(try other.load())
        XCTAssertThrowsError(try store.rename(a, to: "B"))
        XCTAssertThrowsError(try store.rename(a, to: " \n"))
        _ = try store.add("Pending")
        XCTAssertThrowsError(try store.add("Another"))
        XCTAssertTrue(try store.load().pending != nil)
    }
    func testSymlinkAuthComponentIsRejected() throws {
        try FileManager.default.removeItem(at: store.live.appendingPathComponent("Cookies"))
        try FileManager.default.createSymbolicLink(at: store.live.appendingPathComponent("Cookies"), withDestinationURL: store.live.appendingPathComponent("artifact.txt"))
        XCTAssertThrowsError(try store.switchProfile(to: b, requireStopped: {}))
        XCTAssertFalse(store.needsRecovery)
    }
    func testSecretSnapshotsHavePrivatePermissions() throws {
        let state = try store.load()
        let path = store.root.appendingPathComponent("auth-snapshots/\(state.profiles[0].auth!.generation.uuidString)/auth-fields.json")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber, 0o600)
    }
}

@MainActor private final class FakeLifecycle: ClaudeLifecycle {
    var failedLaunches = 0
    var failStop = false
    var stopped = 0
    var launches: [Bool] = []
    var duringStop: (() async -> Void)?
    func stop() async throws { stopped += 1; if let duringStop { await duringStop() }; if failStop { throw Injected.failure } }
    func requireStopped() throws { if failStop { throw Injected.failure } }
    func launch(openCode: Bool) async throws { launches.append(openCode); if failedLaunches > 0 { failedLaunches -= 1; throw Injected.failure } }
}
final class CoordinatorTests: TestCase {
    @MainActor func runAll() async throws {
        let fixture = ProfileStoreTests(); try fixture.setUpWithError(); defer { try? fixture.tearDownWithError() }
        let life = FakeLifecycle(); let coordinator = SwitchCoordinator(store: fixture.store, lifecycle: life)
        life.failedLaunches = 1
        do { try await coordinator.select(fixture.b); XCTFail("launch should fail") } catch {}
        XCTAssertEqual(try fixture.store.load().activeID, fixture.a)
        XCTAssertEqual(life.launches, [true, false])
        XCTAssertNil(coordinator.takeTransferReport())
        life.failStop = true
        do { try await coordinator.select(fixture.b); XCTFail("stop should fail") } catch {}
        XCTAssertEqual(try fixture.store.load().activeID, fixture.a)
        life.failStop = false
        life.duringStop = {
            do { try await coordinator.select(fixture.a); XCTFail("repeat click should fail") } catch {}
        }
        try await coordinator.select(fixture.b)
        life.duringStop = nil
        XCTAssertEqual(try fixture.store.load().activeID, fixture.b)
        XCTAssertTrue(coordinator.takeTransferReport() != nil)
        XCTAssertNil(coordinator.takeTransferReport())
        let stops = life.stopped
        try await coordinator.select(fixture.b)
        XCTAssertEqual(life.stopped, stops)
        XCTAssertNil(coordinator.lastTransferReport)
    }
}
