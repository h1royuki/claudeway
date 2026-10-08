import Foundation
@testable import SwitcherCore

final class LocalizationTests {
    func runAll(defaults: UserDefaults) throws {
        defer { L10n.select(.ru, defaults: defaults) }
        let english = L10n.catalogs[.en] ?? [:]
        XCTAssertTrue(english.count > 100) // Catches missing packaged resources.
        for language in [AppLanguage.en, .ru, .be] {
            let catalog = L10n.catalogs[language] ?? [:]
            XCTAssertEqual(Set(catalog.keys), Set(english.keys))
            for (key, value) in catalog {
                XCTAssertFalse(value.isEmpty)
                XCTAssertEqual(value.components(separatedBy: "%@").count, key.components(separatedBy: "%@").count)
                let count = key.components(separatedBy: "%@").count - 1
                let args = (0..<count).map { "argument-\($0)-100%" }
                let rendered = L10n.render(key, arguments: args, language: language)
                for argument in args { XCTAssertTrue(rendered.contains(argument)) }
            }
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)!
        let calls = try NSRegularExpression(pattern: #"L10n\.text\("((?:\\.|[^"\\])*)""#)
        for case let file as URL in files where file.pathExtension == "swift" {
            let source = try String(contentsOf: file)
            for match in calls.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let escaped = (source as NSString).substring(with: match.range(at: 1))
                let key = try JSONDecoder().decode(String.self, from: Data(("\"" + escaped + "\"").utf8))
                XCTAssertTrue(english[key] != nil, file: #filePath, line: #line)
            }
        }
        print("PASS all localization catalogs, source keys and formatted arguments are complete")

        XCTAssertEqual(AppLanguage.resolve(.system, preferred: ["be-BY", "ru-RU"]), .be)
        XCTAssertEqual(AppLanguage.resolve(.system, preferred: ["ru_BY"]), .ru)
        XCTAssertEqual(AppLanguage.resolve(.system, preferred: ["en-GB"]), .en)
        XCTAssertEqual(AppLanguage.resolve(.system, preferred: ["fr-FR", "be"]), .be)
        XCTAssertEqual(AppLanguage.resolve(.system, preferred: ["fr-FR"]), .en)
        XCTAssertEqual(AppLanguage.resolve(.ru, preferred: ["en"]), .ru)
        for language in AppLanguage.allCases {
            L10n.select(language, defaults: defaults)
            L10n.configure(defaults: defaults)
            XCTAssertEqual(L10n.preference, language)
        }
        defaults.set("unsupported", forKey: L10n.preferenceKey); L10n.configure(defaults: defaults)
        XCTAssertEqual(L10n.preference, .system)
        print("PASS system language resolution, explicit overrides, persistence and fallback")

        let legacy = Data(#"{"phase":"sending","message":"Запрос мог выполниться · Нет связи с Claude","date":123,"retryAt":456}"#.utf8)
        let record = try JSONDecoder().decode(TriggerRecord.self, from: legacy)
        let before = try JSONEncoder().encode(record)
        let cached = UsageWindow(key: "seven_day", title: "Нед.", usedPercent: 12, resetsAt: nil)
        let expected: [(AppLanguage, String, String)] = [
            (.en, "Request may have completed · Cannot connect to Claude", "Week"),
            (.ru, "Запрос мог выполниться · Нет связи с Claude", "Неделя"),
            (.be, "Запыт мог выканацца · Няма сувязі з Claude", "Тыдзень")
        ]
        for (language, message, week) in expected {
            L10n.select(language, defaults: defaults)
            XCTAssertEqual(record.displayMessage, message)
            XCTAssertEqual(cached.displayTitle, week)
            XCTAssertEqual(L10n.canonicalMessage(message), expected[0].1)
            XCTAssertTrue(record.needsVerification)
            XCTAssertEqual(record.date, Date(timeIntervalSinceReferenceDate: 123))
            XCTAssertEqual(record.retryAt, Date(timeIntervalSinceReferenceDate: 456))
        }
        let after = try JSONEncoder().encode(record)
        XCTAssertTrue(NSDictionary(dictionary: try JSONSerialization.jsonObject(with: before) as! [String: Any])
            .isEqual(to: try JSONSerialization.jsonObject(with: after) as! [String: Any]))
        XCTAssertEqual(L10n.message("Customer 100% custom text"), "Customer 100% custom text")
        print("PASS legacy-only Russian statuses and usage titles relocalize without mutating the send barrier")

        let now = Date(timeIntervalSince1970: 1800000000)
        var report = SessionTransferReport(); report.added = 2; report.updated = 3; report.skipped = 999
        for (language, countdown, body) in [(AppLanguage.en, "1h 24m", "Added: 2 · Updated: 3"),
                                             (.ru, "1ч 24м", "Добавлено: 2 · Обновлено: 3"),
                                             (.be, "1г 24хв", "Дададзена: 2 · Абноўлена: 3")] {
            L10n.select(language, defaults: defaults)
            XCTAssertEqual(UsageText.countdown(to: now.addingTimeInterval(5040), now: now), countdown)
            XCTAssertEqual(report.notificationBody, body)
            XCTAssertEqual(L10n.text("Account “%@”", "Personal 100%"), L10n.render("Account “%@”", arguments: ["Personal 100%"], language: language))
            let formatter = DateFormatter(); formatter.locale = L10n.locale; formatter.dateFormat = "EE HH:mm"
            XCTAssertEqual(UsageText.reset(now.addingTimeInterval(3 * 86400), now: now), formatter.string(from: now.addingTimeInterval(3 * 86400)))
            XCTAssertFalse((report.notificationBody ?? "").contains("999"))
        }
        print("PASS localized countdowns, reset weekdays, transfer counts and account-name interpolation")
    }
}
