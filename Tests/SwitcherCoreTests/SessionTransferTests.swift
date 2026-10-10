import Foundation
import SwitcherCore

final class SessionTransferTests: TestCase {
    private var root: URL!
    private var source: URL!
    private var target: URL!
    private var sourceSessions: URL!
    private var targetSessions: URL!
    private var backups: URL!
    private let session = "local_11111111-1111-4111-8111-111111111111"
    private let cli = "22222222-2222-4222-8222-222222222222"
    private let account = "33333333-3333-4333-8333-333333333333"
    private let orgA = "44444444-4444-4444-8444-444444444444"
    private let orgB = "55555555-5555-4555-8555-555555555555"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("TransferTests-\(UUID().uuidString)")
        source = root.appendingPathComponent("source")
        target = root.appendingPathComponent("target")
        backups = root.appendingPathComponent("backups")
        sourceSessions = source.appendingPathComponent("claude-code-sessions/\(account)/\(orgA)")
        targetSessions = target.appendingPathComponent("claude-code-sessions/\(account)/\(orgB)")
        for dir in [sourceSessions!, targetSessions!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        for profile in [source!, target!] { try json(["lastKnownAccountUuid": account, "oauth:tokenCache": "FAKE-DO-NOT-COPY"], at: profile.appendingPathComponent("config.json")) }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func json(_ value: [String: Any], at url: URL) throws { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url) }
    private func read(_ url: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any] }
    private var sourceFile: URL { sourceSessions.appendingPathComponent(session + ".json") }
    private var targetFile: URL { targetSessions.appendingPathComponent(session + ".json") }
    private func entry(activity: Int = 200) -> [String: Any] {
        ["sessionId": session, "cliSessionId": cli, "cwd": "/tmp/synthetic-project", "lastActivityAt": activity,
         "completedTurns": 2, "title": "Synthetic chat", "permissionMode": "bypassPermissions",
         "remoteMcpServersConfig": ["source": "SECRET"], "sessionPermissionUpdates": ["allow": "all"],
         "alwaysAllowedReasons": ["source-grant"], "spawnSeed": ["source": "secret"],
         "promptAppendSnapshot": "source instructions", "toolSurfaceSnapshot": "source tools"]
    }
    private func sync(settings: TransferSettings = TransferSettings(), check: () throws -> Void = {}) throws -> SessionTransferReport {
        try SessionTransfer.synchronize(sources: [source], target: target, backupRoot: backups, transcriptRoot: root.appendingPathComponent("transcripts"), settings: settings, requireStopped: check)
    }

    private var transcript: URL { root.appendingPathComponent("transcripts/-tmp-synthetic-project/" + cli + ".jsonl") }
    private func transcriptMessage(sessionID: String? = nil, cwd: String = "/tmp/synthetic-project", synthetic: Bool = false) -> [String: Any] {
        ["type": synthetic ? "assistant" : "user", "sessionId": sessionID ?? cli, "cwd": cwd,
         "message": ["role": synthetic ? "assistant" : "user", "model": synthetic ? "<synthetic>" : "test", "content": "A saved unfinished request"]]
    }
    private func writeTranscript(_ rows: [[String: Any]]) throws {
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: transcript)
    }
    func testUnfinishedConversationTransfersWithoutCounter() throws {
        for counter: Any? in [nil, NSNull(), 0] {
            var chat = entry(); chat["completedTurns"] = counter
            chat["worktreePath"] = chat["cwd"]; chat["worktreeName"] = "example"; chat["branch"] = "claude/example"; chat["sourceBranch"] = "main"
            try json(chat, at: sourceFile)
            try writeTranscript([transcriptMessage()])
            let original = try Data(contentsOf: sourceFile), history = try Data(contentsOf: transcript)
            XCTAssertEqual(try sync().added, 1)
            let imported = try read(targetFile)
            XCTAssertEqual(imported["cliSessionId"] as? String, cli)
            XCTAssertEqual(imported["worktreePath"] as? String, "/tmp/synthetic-project")
            XCTAssertEqual(imported["branch"] as? String, "claude/example")
            XCTAssertEqual(imported["permissionMode"] as? String, "default")
            XCTAssertNil(imported["remoteMcpServersConfig"])
            XCTAssertEqual(try Data(contentsOf: sourceFile), original)
            XCTAssertEqual(try Data(contentsOf: transcript), history)
            XCTAssertEqual(try sync().added, 0)
            try FileManager.default.removeItem(at: targetFile)
        }
    }
    func testUnfinishedConversationNeedsMatchingRealHistory() throws {
        var chat = entry(); chat.removeValue(forKey: "completedTurns"); try json(chat, at: sourceFile)
        XCTAssertEqual(try sync().added, 0)
        for rows in [[], [["type": "queue-operation", "sessionId": cli]], [transcriptMessage(synthetic: true)],
                     [transcriptMessage(sessionID: UUID().uuidString)], [transcriptMessage(cwd: "/another/project")]] {
            try writeTranscript(rows)
            XCTAssertEqual(try sync().added, 0)
        }
        try Data("broken JSON\n".utf8).write(to: transcript)
        XCTAssertEqual(try sync().added, 0)
        try writeTranscript([transcriptMessage()])
        let tombstone = targetSessions.appendingPathComponent("deleted_" + String(session.dropFirst(6)))
        try Data().write(to: tombstone)
        XCTAssertEqual(try sync().added, 0)
        try FileManager.default.removeItem(at: tombstone)
        chat["sshHost"] = "remote"; try json(chat, at: sourceFile)
        XCTAssertEqual(try sync().added, 0)
    }
    func testUnfinishedTargetUpdatesWithoutCopyingPermissions() throws {
        var chat = entry(); chat["completedTurns"] = 0; try json(chat, at: sourceFile)
        try writeTranscript([transcriptMessage()])
        var old = chat; old["lastActivityAt"] = 100; old["permissionMode"] = "default"
        old["remoteMcpServersConfig"] = ["destination": "KEEP"]; try json(old, at: targetFile)
        let original = try Data(contentsOf: targetFile)
        let report = try sync()
        XCTAssertEqual(report.updated, 1)
        let result = try read(targetFile)
        XCTAssertEqual(result["remoteMcpServersConfig"] as? [String: String], ["destination": "KEEP"])
        XCTAssertEqual(result["permissionMode"] as? String, "default")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: report.backupDirectory!).appendingPathComponent(targetFile.lastPathComponent)), original)
    }
    func testUnfinishedTranscriptSymlinkIsRejected() throws {
        var chat = entry(); chat["completedTurns"] = 0; try json(chat, at: sourceFile)
        try writeTranscript([transcriptMessage()])
        let outside = root.appendingPathComponent("outside.jsonl")
        try FileManager.default.moveItem(at: transcript, to: outside)
        try FileManager.default.createSymbolicLink(at: transcript, withDestinationURL: outside)
        XCTAssertEqual(try sync().added, 0)
    }

    func testImportsOnlySafeFieldsWithManualPermissions() throws {
        try json(entry(), at: sourceFile)
        let config = try Data(contentsOf: target.appendingPathComponent("config.json"))
        let report = try sync()
        XCTAssertEqual(report.added, 1)
        let value = try read(targetFile)
        XCTAssertEqual(value["cliSessionId"] as? String, cli)
        XCTAssertEqual(value["permissionMode"] as? String, "default")
        for key in ["remoteMcpServersConfig", "sessionPermissionUpdates", "alwaysAllowedReasons", "spawnSeed", "promptAppendSnapshot", "toolSurfaceSnapshot"] { XCTAssertNil(value[key]) }
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("config.json")), config)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: targetFile.path)[.posixPermissions] as? NSNumber, 0o600)
        XCTAssertTrue(report.backupDirectory != nil)
    }
    func testNewerRecordUpdatesButKeepsDestinationGrants() throws {
        try json(entry(), at: sourceFile)
        var old = entry(activity: 100)
        old["permissionMode"] = "default"
        old["remoteMcpServersConfig"] = ["destination": "KEEP"]
        old["sessionPermissionUpdates"] = ["destination": "grant"]
        try json(old, at: targetFile)
        let original = try Data(contentsOf: targetFile)
        let report = try sync()
        XCTAssertEqual(report.updated, 1)
        let result = try read(targetFile)
        XCTAssertEqual(result["lastActivityAt"] as? Int, 200)
        XCTAssertEqual(result["permissionMode"] as? String, "default")
        XCTAssertEqual(result["remoteMcpServersConfig"] as? [String: String], ["destination": "KEEP"])
        let backup = URL(fileURLWithPath: report.backupDirectory!).appendingPathComponent(targetFile.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }
    func testOlderAndEqualRecordsNeverOverwrite() throws {
        try json(entry(activity: 100), at: sourceFile)
        try json(entry(activity: 200), at: targetFile)
        let original = try Data(contentsOf: targetFile)
        XCTAssertEqual(try sync().updated, 0)
        try json(entry(activity: 200), at: sourceFile)
        XCTAssertEqual(try sync().updated, 0)
        XCTAssertEqual(try Data(contentsOf: targetFile), original)
    }
    func testDeletionInEitherProfilePreventsReimport() throws {
        try json(entry(), at: sourceFile)
        for directory in [sourceSessions!, targetSessions!] {
            let tombstone = directory.appendingPathComponent("deleted_" + String(session.dropFirst(6)))
            try Data().write(to: tombstone)
            XCTAssertEqual(try sync().added, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: targetFile.path))
            try FileManager.default.removeItem(at: tombstone)
        }
    }
    func testAmbiguousOrganizationIsSkipped() throws {
        try json(entry(), at: sourceFile)
        try json(entry(activity: 100), at: targetFile)
        let extra = targetSessions.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: false)
        try json(entry(activity: 100), at: extra.appendingPathComponent(session + ".json"))
        let report = try sync()
        XCTAssertEqual(report.added, 0)
        XCTAssertTrue(report.note != nil)
    }
    func testEmptyAuxiliaryOrganizationDoesNotBlockTransfer() throws {
        try json(entry(), at: sourceFile)
        try json(entry(activity: 100), at: targetFile)
        let extra = targetSessions.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: false)
        try json(["scheduledTasks": []], at: extra.appendingPathComponent("scheduled-tasks.json"))
        XCTAssertEqual(try sync().updated, 1)
    }
    func testNewAccountWithoutNativeSessionIsSkipped() throws {
        try FileManager.default.removeItem(at: targetSessions)
        let report = try sync()
        XCTAssertEqual(report.added, 0)
        XCTAssertTrue(report.note != nil)
    }
    func testMalformedAndRemoteRecordsAreSkipped() throws {
        try Data("malformed".utf8).write(to: sourceFile)
        XCTAssertEqual(try sync().added, 0)
        var remote = entry(); remote["sshConnectionId"] = "ssh-host"
        try json(remote, at: sourceFile)
        XCTAssertEqual(try sync().added, 0)
        var empty = entry(); empty["completedTurns"] = 0
        try json(empty, at: sourceFile)
        XCTAssertEqual(try sync().added, 0)
    }
    func testSymlinkRecordIsNotFollowed() throws {
        let original = root.appendingPathComponent("outside.json")
        try json(entry(), at: original)
        try FileManager.default.createSymbolicLink(at: sourceFile, withDestinationURL: original)
        XCTAssertEqual(try sync().added, 0)
    }
    func testConflictingConversationIsNotOverwritten() throws {
        try json(entry(), at: sourceFile)
        var other = entry(activity: 100); other["cliSessionId"] = UUID().uuidString
        try json(other, at: targetFile)
        let original = try Data(contentsOf: targetFile)
        XCTAssertEqual(try sync().updated, 0)
        XCTAssertEqual(try Data(contentsOf: targetFile), original)
    }
    func testRunningProcessBlocksTransfer() throws {
        try json(entry(), at: sourceFile)
        XCTAssertThrowsError(try sync { throw StoreError.message("running") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetFile.path))
    }
    func testRepeatTransferIsIdempotent() throws {
        try json(entry(), at: sourceFile)
        XCTAssertEqual(try sync().added, 1)
        let original = try Data(contentsOf: targetFile)
        let next = try sync()
        XCTAssertEqual(next.added, 0)
        XCTAssertEqual(next.updated, 0)
        XCTAssertEqual(try Data(contentsOf: targetFile), original)
    }
    func testSharedRootIncludesOnlyRegisteredAccounts() throws {
        let shared = root.appendingPathComponent("shared")
        let targetAccount = UUID()
        let organization = UUID()
        let incoming = shared.appendingPathComponent("claude-code-sessions/\(account)/\(orgA)")
        let outgoing = shared.appendingPathComponent("claude-code-sessions/\(targetAccount.uuidString)/\(organization.uuidString)")
        let unknown = shared.appendingPathComponent("claude-code-sessions/\(UUID().uuidString)/\(UUID().uuidString)")
        for directory in [incoming, outgoing, unknown] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        try json(entry(), at: incoming.appendingPathComponent(session + ".json"))
        var extra = entry(); let extraID = "local_" + UUID().uuidString
        extra["sessionId"] = extraID
        try json(extra, at: unknown.appendingPathComponent(extraID + ".json"))
        let result = try SessionTransfer.synchronizeShared(dataRoot: shared, accounts: [UUID(uuidString: account)!, targetAccount], targetAccount: targetAccount, targetOrganization: organization, backupRoot: backups, requireStopped: {})
        XCTAssertEqual(result.added, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outgoing.appendingPathComponent(session + ".json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outgoing.appendingPathComponent(extraID + ".json").path))
    }
    func testInterruptedTransferRollsBackAppliedChanges() throws {
        try json(entry(), at: sourceFile)
        let secondID = "local_66666666-6666-4666-8666-666666666666"
        var second = entry(); second["sessionId"] = secondID; second["cliSessionId"] = UUID().uuidString
        try json(second, at: sourceSessions.appendingPathComponent(secondID + ".json"))
        var calls = 0
        XCTAssertThrowsError(try sync {
            calls += 1
            if calls == 4 { throw StoreError.message("injected write-stage failure") }
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetSessions.appendingPathComponent(secondID + ".json").path))
    }

    func testSelectedProjectsFilterImportsAndUpdates() throws {
        try json(entry(), at: sourceFile)
        var settings = TransferSettings(); settings.mode = .selected
        settings.projects = ["/tmp/other"]
        XCTAssertEqual(try sync(settings: settings).added, 0)
        settings.projects = ["/tmp/synthetic-project"]
        XCTAssertEqual(try sync(settings: settings).added, 1)
        let original = try Data(contentsOf: targetFile)
        try json(entry(activity: 300), at: sourceFile)
        settings.projects = []
        XCTAssertEqual(try sync(settings: settings).updated, 0)
        XCTAssertEqual(try Data(contentsOf: targetFile), original)
        settings.projects = ["/tmp/synthetic-project"]
        XCTAssertEqual(try sync(settings: settings).updated, 1)
        XCTAssertEqual(try read(targetFile)["permissionMode"] as? String, "default")
        XCTAssertEqual(try sync(settings: settings).updated, 0)
    }
    func testDisabledAndEmptySelectionPreserveData() throws {
        try json(entry(), at: sourceFile)
        try json(entry(activity: 100), at: targetFile)
        let before = try Data(contentsOf: targetFile)
        var settings = TransferSettings(); settings.mode = .disabled
        settings.projects = ["/tmp/synthetic-project"]
        XCTAssertEqual(try sync(settings: settings).updated, 0)
        settings.mode = .selected; settings.projects = []
        XCTAssertEqual(try sync(settings: settings).updated, 0)
        XCTAssertEqual(try Data(contentsOf: targetFile), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }
    func testProjectOriginAndExactMatching() throws {
        var chat = entry(); chat["cwd"] = "/tmp/worktree"; chat["originCwd"] = "/tmp/repo/./"
        try json(chat, at: sourceFile)
        var settings = TransferSettings(); settings.mode = .selected; settings.projects = ["/tmp/repo"]
        XCTAssertEqual(try sync(settings: settings).added, 1)
        try FileManager.default.removeItem(at: targetFile)
        chat["originCwd"] = "/tmp/repo-other"; try json(chat, at: sourceFile)
        XCTAssertEqual(try sync(settings: settings).added, 0)
        chat["originCwd"] = "relative"; try json(chat, at: sourceFile)
        settings.projects = ["/tmp/worktree"]
        XCTAssertEqual(try sync(settings: settings).added, 1)
    }
    func testProjectIdentityConflictsAreSkipped() throws {
        try json(entry(), at: sourceFile)
        var other = entry(activity: 100); other["cwd"] = "/tmp/other"
        try json(other, at: targetFile)
        let before = try Data(contentsOf: targetFile)
        XCTAssertEqual(try sync().updated, 0)
        XCTAssertEqual(try Data(contentsOf: targetFile), before)
        try FileManager.default.removeItem(at: targetFile)
        let second = source.appendingPathComponent("claude-code-sessions/\(account)/\(orgB)")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try json(other, at: second.appendingPathComponent(session + ".json"))
        var settings = TransferSettings(); settings.mode = .selected; settings.projects = ["/tmp/synthetic-project"]
        XCTAssertEqual(try sync(settings: settings).added, 0)
    }
    func testProjectCatalogDeduplicatesAndHonorsBoundaries() throws {
        try json(entry(), at: sourceFile)
        let second = source.appendingPathComponent("claude-code-sessions/\(account)/\(orgB)")
        let unknown = source.appendingPathComponent("claude-code-sessions/\(UUID().uuidString)/\(orgB)")
        for dir in [second, unknown] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try json(entry(), at: dir.appendingPathComponent(session + ".json"))
        }
        var remote = entry(); remote["sshHost"] = "remote"
        let remoteID = "local_" + UUID().uuidString; remote["sessionId"] = remoteID
        try json(remote, at: sourceSessions.appendingPathComponent(remoteID + ".json"))
        var hidden = entry(); hidden["cwd"] = "/tmp/unknown"
        try json(hidden, at: unknown.appendingPathComponent(session + ".json"))
        let accounts = [UUID(uuidString: account)!]
        let projects = try SessionTransfer.projects(dataRoot: source, accounts: accounts, transcriptRoot: root.appendingPathComponent("transcripts"))
        XCTAssertEqual(projects, [TransferProject(path: "/tmp/synthetic-project", chatCount: 1)])
        try Data().write(to: second.appendingPathComponent("deleted_" + session))
        XCTAssertTrue(try SessionTransfer.projects(dataRoot: source, accounts: accounts).isEmpty)
    }
    func testTransferSettingsPersistAndFailClosed() throws {
        XCTAssertEqual(try TransferSettings.load(at: root).mode, .all)
        var settings = TransferSettings(); settings.mode = .selected; settings.projects = ["/tmp/not-mounted", "/tmp/other"]
        try settings.save(at: root)
        XCTAssertEqual(try TransferSettings.load(at: root), settings)
        settings.mode = .disabled; try settings.save(at: root)
        XCTAssertEqual(try TransferSettings.load(at: root), settings)
        let file = root.appendingPathComponent("chat-transfer-settings.json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        for data in ["{}", "broken", "{\"version\":99,\"mode\":\"all\",\"projects\":[]}", "{\"version\":1,\"mode\":\"selected\",\"projects\":[\"relative\"]}"] {
            try Data(data.utf8).write(to: file)
            XCTAssertThrowsError(try TransferSettings.load(at: root))
        }
        settings.mode = .selected; settings.projects = []
        try settings.save(at: root); XCTAssertEqual(try TransferSettings.load(at: root), settings)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: sourceFile)
        XCTAssertThrowsError(try TransferSettings.load(at: root))
    }
}
