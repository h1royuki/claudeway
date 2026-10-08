import AppKit
import SwitcherCore

@main struct ClaudewayApplication {
    @MainActor static func main() {
        L10n.configure()
        if CommandLine.arguments.contains("--check-localizations") {
            let keys = Set(L10n.catalogs[.en]?.keys.map { $0 } ?? [])
            guard !keys.isEmpty, [AppLanguage.ru, .be].allSatisfy({ Set(L10n.catalogs[$0]?.keys.map { $0 } ?? []) == keys }) else {
                fputs("Missing localization resources\n", stderr); exit(1)
            }
            print("Localization resources OK: en, ru, be (\(keys.count) strings each)")
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
