import Foundation
import SwitcherCore

// Standalone assertions so tests also run on Macs with Command Line Tools only.
// XCTest is shipped with full Xcode and is not required to build this app.
class TestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}

func XCTFail(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> Never {
    fputs("FAIL \(file):\(line): \(message)\n", stderr)
    exit(1)
}
func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { let a = try lhs(); let b = try rhs(); if a != b { XCTFail("\(a) != \(b)", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(try value(), true, file: file, line: line)
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(try value(), false, file: file, line: line)
}
func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) {
    if value != nil { XCTFail("Expected nil", file: file, line: line) }
}
func XCTAssertThrowsError<T>(_ action: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try action() } catch { return }
    XCTFail("Expected an error", file: file, line: line)
}

@main struct TestRunner {
    @MainActor static func main() async throws {
        // Do not read or change the user's language preference during tests.
        let suite = "ClaudewayTests-" + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        L10n.select(.ru, defaults: preferences)
        let tests = ProfileStoreTests()
        let cases: [(String, () throws -> Void)] = [
            ("shared root inode, settings and artifacts survive round trip", tests.testRoundTripKeepsCommonRootAndSettings),
            ("all 16 auth transaction crash points", tests.testEveryAuthCheckpointRecovers),
            ("refreshed credentials captured", tests.testRefreshedCredentialsAreCapturedBeforeLeaving),
            ("shared preference edits survive", tests.testCommonPreferenceEditSurvivesBothAccounts),
            ("add/cancel without logout or settings loss", tests.testAddAndCancelPreserveSettingsWithoutLogout),
            ("duplicate account login refused", tests.testDuplicateLoginCannotBeRegistered),
            ("external login mismatch refused", tests.testExternalLoginCannotOverwriteNamedAccount),
            ("corrupt encrypted snapshot rejected", tests.testDamagedAuthSnapshotFailsBeforeMutation),
            ("running process blocks switch and recovery", tests.testRunningClaudeBlocksSwitchAndRecovery),
            ("interrupted auth recovery resumes", tests.testRecoveryItselfCanBeInterrupted),
            ("volatile bridge cleared", tests.testVolatileBridgeIsNotRestoredOnNormalSwitch),
            ("same account no-op", tests.testSameAccountIsNoop),
            ("exclusive lock, names, pending add", tests.testLockNamesAndPendingState),
            ("auth symlink rejected", tests.testSymlinkAuthComponentIsRejected),
            ("encrypted snapshots private permissions", tests.testSecretSnapshotsHavePrivatePermissions)
        ]
        for (name, test) in cases {
            try tests.setUpWithError()
            do { try test() } catch { XCTFail("\(name): \(error)") }
            try tests.tearDownWithError()
            print("PASS \(name)")
        }
        try await CoordinatorTests().runAll()
        print("PASS coordinator launch rollback, stop failure, double click, same-account activation")
        let migration = MigrationTests()
        let migrationCases: [(String, () throws -> Void)] = [
            ("migration uses work preferences, keeps personal login and both histories", migration.testWorkSettingsBaseAndBothHistoriesPreserved),
            ("all four migration crash points and retry", migration.testMigrationCrashesRecoverBeforeAndAfterCommit),
            ("unfinished v1 transaction blocks migration", migration.testLegacyUnfinishedSwitchBlocksMigration)
        ]
        for (name, test) in migrationCases {
            try migration.setUpWithError()
            do { try test() } catch { XCTFail("\(name): \(error)") }
            try migration.tearDownWithError()
            print("PASS \(name)")
        }
        let transfer = SessionTransferTests()
        let transferCases: [(String, () throws -> Void)] = [
            ("unfinished chat with absent/null/zero counter and worktree metadata", transfer.testUnfinishedConversationTransfersWithoutCounter),
            ("unfinished chat requires real matching history; remote/deleted still skipped", transfer.testUnfinishedConversationNeedsMatchingRealHistory),
            ("unfinished target updates retain grants and backups", transfer.testUnfinishedTargetUpdatesWithoutCopyingPermissions),
            ("symlink transcript cannot qualify an unfinished chat", transfer.testUnfinishedTranscriptSymlinkIsRejected),
            ("safe-field import and manual permissions", transfer.testImportsOnlySafeFieldsWithManualPermissions),
            ("newer metadata preserves destination grants and backs up", transfer.testNewerRecordUpdatesButKeepsDestinationGrants),
            ("older/equal records never overwrite", transfer.testOlderAndEqualRecordsNeverOverwrite),
            ("deleted sessions are not resurrected", transfer.testDeletionInEitherProfilePreventsReimport),
            ("ambiguous target organization skipped", transfer.testAmbiguousOrganizationIsSkipped),
            ("empty auxiliary organization ignored", transfer.testEmptyAuxiliaryOrganizationDoesNotBlockTransfer),
            ("new account without native session skipped", transfer.testNewAccountWithoutNativeSessionIsSkipped),
            ("malformed/remote/empty sessions skipped", transfer.testMalformedAndRemoteRecordsAreSkipped),
            ("symlink session ignored", transfer.testSymlinkRecordIsNotFollowed),
            ("conflicting CLI session never overwritten", transfer.testConflictingConversationIsNotOverwritten),
            ("running process blocks import", transfer.testRunningProcessBlocksTransfer),
            ("repeat transfer is idempotent", transfer.testRepeatTransferIsIdempotent),
            ("shared root only includes registered accounts", transfer.testSharedRootIncludesOnlyRegisteredAccounts),
            ("partial transfer rollback", transfer.testInterruptedTransferRollsBackAppliedChanges)
        ]
        for (name, test) in transferCases {
            try transfer.setUpWithError()
            do { try test() } catch { XCTFail("\(name): \(error)") }
            try transfer.tearDownWithError()
            print("PASS \(name)")
        }
        NotificationTests().runAll()
        try UsageTests().runAll()
        try await UsageClientTests().runAll()
        try await TriggerTests().runAll()
        try LocalizationTests().runAll(defaults: preferences)
        print("57 test groups passed (including 16 auth and 4 migration crash points).")
    }
}
