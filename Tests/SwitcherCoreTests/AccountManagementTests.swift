import Foundation
@testable import SwitcherCore

private enum ManagementFailure: Error { case injected }
@MainActor private final class ManagementLifecycle: ClaudeLifecycle {
    var stops = 0
    var launches = 0
    var failLaunches = 0
    func stop() async throws { stops += 1 }
    func requireStopped() throws {}
    func launch(openCode: Bool) async throws {
        launches += 1
        if failLaunches > 0 { failLaunches -= 1; throw ManagementFailure.injected }
    }
}

final class AccountManagementTests {
    private let points = ["journal", "config", "Cookies", "Cookies-journal", "Cookies-wal", "Cookies-shm",
                          "Network/Cookies", "Network/Cookies-journal", "Network/Cookies-wal", "Network/Cookies-shm",
                          "Local Storage", "Session Storage", "IndexedDB", "bridge-state.json", "auth", "commit"]
    private func fixture(_ body: (ProfileStoreTests) throws -> Void) throws {
        let f = ProfileStoreTests(); try f.setUpWithError(); defer { try? f.tearDownWithError() }
        try body(f)
    }
    @MainActor func runAll() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EmptyAccounts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var store: ProfileStore? = ProfileStore(root: root.appendingPathComponent("Switcher"), live: root.appendingPathComponent("Claude"))
        try store!.acquireLock()
        XCTAssertTrue(try store!.initializeEmpty().profiles.isEmpty)
        XCTAssertNil(try store!.load().activeID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store!.live.path))
        XCTAssertFalse(store!.needsPreparation)
        let first = try store!.add("First")
        XCTAssertNil(first.pending?.previousID)
        XCTAssertEqual(first.activeID, first.pending?.id)
        XCTAssertTrue(try store!.cancelAdding().profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store!.live.path))
        store = nil
        store = ProfileStore(root: root.appendingPathComponent("Switcher"), live: root.appendingPathComponent("Claude"))
        try store!.acquireLock()
        XCTAssertTrue(try store!.initializeEmpty().profiles.isEmpty)
        XCTAssertTrue(try store!.initialize(requireStopped: { XCTFail("empty restart must not inspect Claude") }).profiles.isEmpty)
        print("PASS empty first launch, first-account cancellation and empty restart never touch Claude")

        try fixture { f in
            let config = try Data(contentsOf: f.store.live.appendingPathComponent("config.json"))
            let cookie = try Data(contentsOf: f.store.live.appendingPathComponent("Cookies"))
            let inode = try FileManager.default.attributesOfItem(atPath: f.store.live.path)[.systemFileNumber] as? NSNumber
            let renamed = try f.store.rename(f.b, to: "  Other name  ")
            XCTAssertEqual(renamed.profiles.first(where: { $0.id == f.b })?.name, "Other name")
            XCTAssertEqual(renamed.activeID, f.a)
            XCTAssertThrowsError(try f.store.rename(f.b, to: renamed.profiles.first(where: { $0.id == f.a })!.name))
            XCTAssertThrowsError(try f.store.rename(f.b, to: "\n"))
            XCTAssertEqual(try f.store.remove(f.b).activeID, f.a)
            let empty = try f.store.remove(f.a)
            XCTAssertTrue(empty.profiles.isEmpty); XCTAssertNil(empty.activeID); XCTAssertNil(empty.settingsBaseID)
            XCTAssertTrue(try f.store.load().profiles.isEmpty)
            XCTAssertEqual(try Data(contentsOf: f.store.live.appendingPathComponent("config.json")), config)
            XCTAssertEqual(try Data(contentsOf: f.store.live.appendingPathComponent("Cookies")), cookie)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: f.store.live.path)[.systemFileNumber] as? NSNumber, inode)
            XCTAssertEqual(try String(contentsOf: f.store.live.appendingPathComponent("artifact.txt")), "shared-artifact")
        }
        print("PASS inactive rename, name validation and removal through zero preserve login, chats and the shared root")

        try fixture { f in
            _ = try f.store.remove(f.a)
            try f.login(f.accountB, token: "B-refreshed")
            let live = try Data(contentsOf: f.store.live.appendingPathComponent("config.json"))
            try f.store.switchProfile(to: f.b, requireStopped: {})
            XCTAssertEqual(try f.store.load().activeID, f.b)
            XCTAssertEqual(try f.token(), "encrypted-B-refreshed")
            XCTAssertEqual(try Data(contentsOf: f.store.live.appendingPathComponent("config.json")), live)
            XCTAssertFalse(f.store.needsRecovery)
        }
        print("PASS selecting the current untracked login preserves refreshed credentials")

        try fixture { f in
            XCTAssertThrowsError(try f.store.remove(UUID()))
            let pending = try f.store.add("Pending").pending!
            XCTAssertThrowsError(try f.store.remove(f.a))
            XCTAssertThrowsError(try f.store.rename(f.b, to: "Blocked"))
            _ = try f.store.cancelAdding()
            XCTAssertFalse(try f.store.load().profiles.contains { $0.id == pending.id })
            XCTAssertThrowsError(try f.store.switchProfile(to: f.b, requireStopped: {}, checkpoint: { if $0 == "journal" { throw ManagementFailure.injected } }))
            XCTAssertThrowsError(try f.store.remove(f.a))
            _ = try f.store.recover(requireStopped: {})
            XCTAssertEqual(try f.store.load().profiles.count, 2)
        }
        print("PASS management rejects unknown accounts, pending additions and unfinished recovery")

        for point in ["before-remove-commit", "remove-commit"] {
            try fixture { f in
                XCTAssertThrowsError(try f.store.remove(f.a, checkpoint: { if $0 == point { throw ManagementFailure.injected } }))
                let state = try f.store.load()
                XCTAssertEqual(state.profiles.count, point == "remove-commit" ? 1 : 2)
                XCTAssertEqual(state.activeID, point == "remove-commit" ? nil : f.a)
                XCTAssertEqual(try f.token(), "encrypted-A")
                XCTAssertFalse(f.store.needsRecovery)
            }
        }
        print("PASS removal is atomic before/after commit and never partially changes Desktop data")

        for point in points {
            try fixture { f in
                _ = try f.store.remove(f.a)
                XCTAssertThrowsError(try f.store.switchProfile(to: f.b, requireStopped: {}, checkpoint: { if $0 == point { throw ManagementFailure.injected } }))
                let state = try f.store.recover(requireStopped: {})
                XCTAssertEqual(state.activeID, point == "commit" ? f.b : nil)
                XCTAssertEqual(try f.token(), point == "commit" ? "encrypted-B" : "encrypted-A")
                XCTAssertFalse(f.store.needsRecovery)
            }
        }
        print("PASS all 16 switch crash points recover after removing the active account")

        for point in points {
            try fixture { f in
                let detached = try f.store.captureDetachedLogin(requireStopped: {})
                _ = try f.store.remove(f.a)
                try f.store.switchProfile(to: f.b, requireStopped: {})
                XCTAssertThrowsError(try f.store.restoreDetachedLogin(detached, requireStopped: {}, checkpoint: { if $0 == point { throw ManagementFailure.injected } }))
                let state = try f.store.recover(requireStopped: {})
                XCTAssertEqual(state.activeID, point == "commit" ? nil : f.b)
                XCTAssertEqual(try f.token(), point == "commit" ? "encrypted-A" : "encrypted-B")
                XCTAssertFalse(f.store.needsRecovery)
            }
        }
        print("PASS all 16 detached-login rollback crash points preserve a valid login and profile state")

        let f = ProfileStoreTests(); try f.setUpWithError(); defer { try? f.tearDownWithError() }
        let life = ManagementLifecycle(); let coordinator = SwitchCoordinator(store: f.store, lifecycle: life)
        _ = try f.store.remove(f.a)
        life.failLaunches = 1
        do { try await coordinator.select(f.b); XCTFail("launch should fail") } catch {}
        XCTAssertNil(try f.store.load().activeID)
        XCTAssertEqual(try f.token(), "encrypted-A")
        try await coordinator.beginAdding("Adopt current")
        XCTAssertNil(try f.store.load().pending?.previousID)
        try await coordinator.cancelAdding()
        XCTAssertEqual(try f.store.load().profiles.count, 1)
        XCTAssertNil(try f.store.load().activeID)
        XCTAssertEqual(try f.token(), "encrypted-A")
        _ = try f.store.remove(f.b)
        let stops = life.stops
        try await coordinator.beginAdding("First")
        XCTAssertEqual(life.stops, stops)
        XCTAssertEqual(try f.token(), "encrypted-A")
        try await coordinator.cancelAdding()
        XCTAssertTrue(try f.store.load().profiles.isEmpty)
        XCTAssertEqual(life.stops, stops)
        try await coordinator.beginAdding("First")
        try await coordinator.finishAdding()
        let completed = try f.store.load()
        XCTAssertEqual(completed.profiles.count, 1)
        XCTAssertEqual(completed.profiles.first?.auth?.accountID, f.accountA)
        XCTAssertNil(completed.pending)
        XCTAssertEqual(try f.token(), "encrypted-A")
        print("PASS coordinator restores an untracked login on launch failure and supports initial/untracked add/cancel/finish")
    }
}
