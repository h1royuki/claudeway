import Foundation
@testable import SwitcherCore

final class NotificationTests {
    func runAll() {
        var report = SessionTransferReport()
        XCTAssertNil(report.notificationBody)
        report.skipped = 999
        report.note = "Unrecognized source metadata"
        XCTAssertNil(report.notificationBody)
        report.added = 2
        XCTAssertEqual(report.notificationBody, "Добавлено: 2")
        report.updated = 3
        XCTAssertEqual(report.notificationBody, "Добавлено: 2 · Обновлено: 3")
        report.added = 0
        XCTAssertEqual(report.notificationBody, "Обновлено: 3")
        XCTAssertFalse(report.notificationBody!.contains("999"))
        XCTAssertFalse(report.notificationBody!.contains("Unrecognized"))
        report.updated = 0
        XCTAssertNil(report.notificationBody)
        print("PASS transfer notification includes only actual additions/updates; empty and skipped-only transfers are silent")
    }
}
