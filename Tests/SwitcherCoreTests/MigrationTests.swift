import Foundation
import SwitcherCore

private enum MigrationFault: Error { case injected }
final class MigrationTests: TestCase {
    private var root: URL!
    private var store: ProfileStore!
    private let personal = UUID()
    private let work = UUID()
    private let personalAccount = UUID()
    private let workAccount = UUID()
    private var workData: URL { store.root.appendingPathComponent("profiles/\(work.uuidString)/data") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MigrationTest-\(UUID().uuidString)")
        store = ProfileStore(root: root.appendingPathComponent("Switcher"), live: root.appendingPathComponent("Claude"))
        try store.acquireLock()
        for (directory, account, name) in [(store.live, personalAccount, "personal"), (workData, workAccount, "work")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var config: [String: Any] = ["lastKnownAccountUuid": account.uuidString, "oauth:tokenCache": "opaque-\(name)", "theme": name]
            config[name + "Only"] = true
            try json(config, directory.appendingPathComponent("config.json"))
            try json(["preferences": ["theme": name, name + "Only": true], "mcpServers": [name: ["command": "fake-\(name)"]]], directory.appendingPathComponent("claude_desktop_config.json"))
            try Data("cookies-\(name)".utf8).write(to: directory.appendingPathComponent("Cookies"))
            let sessions = directory.appendingPathComponent("claude-code-sessions/\(account.uuidString)/\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            try Data("synthetic-\(name)".utf8).write(to: sessions.appendingPathComponent("test-marker.txt"))
            try Data(name.utf8).write(to: directory.appendingPathComponent(name + "-artifact.txt"))
        }
        let legacy: [String: Any] = ["version": 1, "activeID": personal.uuidString,
            "profiles": [["id": personal.uuidString, "name": "Личный"], ["id": work.uuidString, "name": "Работа"]]]
        try json(legacy, store.stateURL)
    }
    override func tearDownWithError() throws { store = nil; try FileManager.default.removeItem(at: root) }
    private func json(_ value: [String: Any], _ url: URL) throws { try JSONSerialization.data(withJSONObject: value).write(to: url) }
    private func read(_ url: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }

    func testWorkSettingsBaseAndBothHistoriesPreserved() throws {
        let originalWork = try Data(contentsOf: workData.appendingPathComponent("config.json"))
        let result = try store.initialize(requireStopped: {}, settingsBaseID: work)
        XCTAssertEqual(result.version, 2)
        XCTAssertEqual(result.activeID, personal)
        XCTAssertEqual(result.settingsBaseID, work)
        let config = try read(store.live.appendingPathComponent("config.json"))
        XCTAssertEqual(config["theme"] as? String, "work")
        XCTAssertEqual(config["personalOnly"] as? Bool, true)
        XCTAssertEqual(config["workOnly"] as? Bool, true)
        XCTAssertEqual(config["oauth:tokenCache"] as? String, "opaque-personal")
        let desktop = try read(store.live.appendingPathComponent("claude_desktop_config.json"))
        XCTAssertEqual((desktop["mcpServers"] as? [String: Any])?.count, 2)
        XCTAssertEqual(try Data(contentsOf: workData.appendingPathComponent("config.json")), originalWork)
        for name in ["personal-artifact.txt", "work-artifact.txt"] { XCTAssertTrue(FileManager.default.fileExists(atPath: store.live.appendingPathComponent(name).path)) }
        let dirs = try FileManager.default.contentsOfDirectory(at: store.live.appendingPathComponent("claude-code-sessions"), includingPropertiesForKeys: nil)
        XCTAssertEqual(dirs.count, 2)
        try store.switchProfile(to: work, requireStopped: {})
        XCTAssertEqual(try read(store.live.appendingPathComponent("config.json"))["oauth:tokenCache"] as? String, "opaque-work")
        XCTAssertEqual(try read(store.live.appendingPathComponent("config.json"))["theme"] as? String, "work")
    }
    func testMigrationCrashesRecoverBeforeAndAfterCommit() throws {
        for point in ["migration-journal", "migration-parked", "migration-installed", "migration-commit"] {
            if point != "migration-journal" { try tearDownWithError(); try setUpWithError() }
            XCTAssertThrowsError(try store.initialize(requireStopped: {}, settingsBaseID: work, checkpoint: { if $0 == point { throw MigrationFault.injected } }))
            XCTAssertTrue(store.needsRecovery)
            let recovered = try store.recover(requireStopped: {})
            XCTAssertEqual(recovered.version, point == "migration-commit" ? 2 : 1)
            XCTAssertEqual(try read(store.live.appendingPathComponent("config.json"))["theme"] as? String, point == "migration-commit" ? "work" : "personal")
            XCTAssertEqual(try read(store.live.appendingPathComponent("config.json"))["oauth:tokenCache"] as? String, "opaque-personal")
            XCTAssertFalse(store.needsRecovery)
            if recovered.version == 1 {
                XCTAssertEqual(recovered.settingsBaseID, work)
                _ = try store.initialize(requireStopped: {})
            }
            XCTAssertEqual(try store.load().version, 2)
            XCTAssertEqual(try store.load().settingsBaseID, work)
        }
    }
    func testLegacyUnfinishedSwitchBlocksMigration() throws {
        try Data("{}".utf8).write(to: store.root.appendingPathComponent("switch-journal.json"))
        XCTAssertThrowsError(try store.initialize(requireStopped: {}, settingsBaseID: work))
        XCTAssertEqual(try read(store.live.appendingPathComponent("config.json"))["theme"] as? String, "personal")
    }
}
