import Foundation
import SwitcherCore

final class UsageTests {
    func runAll() throws {
        let windows = try UsageParser.windows(from: Data(#"{"five_hour":{"utilization":72,"resets_at":"2026-10-06T15:00:00Z"},"seven_day":{"utilization":0,"resets_at":"2026-10-09T09:00:00.000Z"},"seven_day_opus":null}"#.utf8))
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].usedPercent, 72)
        XCTAssertEqual(windows[1].usedPercent, 0)
        XCTAssertTrue(windows[0].resetsAt != nil)
        XCTAssertTrue(windows[1].resetsAt != nil)
        XCTAssertThrowsError(try UsageParser.windows(from: Data(#"{"five_hour":{"utilization":null},"seven_day":{"utilization":true}}"#.utf8)))
        XCTAssertThrowsError(try UsageParser.windows(from: Data(#"{"five_hour":{"utilization":-1}}"#.utf8)))
        let missing = try UsageParser.windows(from: Data(#"{"five_hour":{"utilization":18,"resets_at":"not-a-date"}}"#.utf8))
        XCTAssertNil(missing[0].resetsAt)
        let newer = try UsageParser.windows(from: Data(#"{"five_hour":{"utilization":1},"limits":[{"kind":"session","percent":90,"resets_at":1800000000},{"kind":"weekly_all","percent":43,"resets_at":1800400000},{"kind":"weekly_scoped","percent":75,"scope":{"model":{"display_name":"Sonnet"}}}]}"#.utf8))
        XCTAssertEqual(newer.count, 3)
        XCTAssertEqual(newer[0].usedPercent, 90)
        XCTAssertEqual(newer[2].title, "Sonnet")
        let now = Date(timeIntervalSince1970: 1791293760)
        let usage = AccountUsage(profileID: UUID(), accountID: UUID(), organizationID: UUID(), observedAt: now, source: "test", windows: windows)
        XCTAssertEqual(usage.nearestReset(at: now), windows[0].resetsAt)
        XCTAssertFalse(usage.isStale(at: now))
        XCTAssertTrue(usage.isStale(at: now.addingTimeInterval(901)))
        XCTAssertTrue(windows[0].hasElapsed(at: windows[0].resetsAt!))
        XCTAssertEqual(UsageText.countdown(to: now.addingTimeInterval(5040), now: now), "1ч 24м")
        XCTAssertEqual(UsageText.reset(nil, now: now), "—")
        XCTAssertEqual(UsageText.reset(now, now: now), "обновить")
        XCTAssertEqual(UsageText.age(now.addingTimeInterval(-7200), now: now), "2ч назад")
        let profile = try JSONDecoder().decode(Profile.self, from: Data(#"{"id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","name":"Test","auth":{"generation":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","accountID":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"},"organizationID":"dddddddd-dddd-4ddd-8ddd-dddddddddddd"}"#.utf8))
        let history = Data(#"{"version":2,"samples":[{"t":1791290000000,"org":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","u":{"fh":42,"sd":64}},{"t":1791290000010,"org":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee","u":{"fh":99}},{"t":1999999999999,"org":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","u":{"fh":100}},{"t":1791280000000,"org":"dddddddd-dddd-4ddd-8ddd-dddddddddddd","u":{"fh":1}}]}"#.utf8)
        let local = try UsageParser.history(history, profile: profile, now: now)
        XCTAssertEqual(local?.windows.first?.usedPercent, 42)
        XCTAssertNil(local?.nearestReset(at: now))
        XCTAssertEqual(local?.accountID, profile.auth?.accountID)
        XCTAssertNil(try UsageParser.history(Data(#"{"version":1,"samples":[]}"#.utf8), profile: profile))
        print("PASS usage parsing, nulls, extra model caps, server resets, expiry and organization isolation")
    }
}
