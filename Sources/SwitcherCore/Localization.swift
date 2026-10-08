import Foundation

public enum AppLanguage: String, CaseIterable {
    case system, en, ru, be
    public var nativeName: String {
        switch self {
        case .system: return L10n.text("System")
        case .en: return "English"
        case .ru: return "Русский"
        case .be: return "Беларуская"
        }
    }
    public static func resolve(_ preference: AppLanguage, preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard preference == .system else { return preference }
        for identifier in preferred {
            let code = identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init)?.lowercased()
            if let code, let language = AppLanguage(rawValue: code), language != .system { return language }
        }
        return .en
    }
}

public enum L10n {
    public static let preferenceKey = "interfaceLanguage"
    private static let lock = NSLock()
    private static var selection: AppLanguage = .system
    public static var preference: AppLanguage {
        lock.lock(); defer { lock.unlock() }; return selection
    }
    public static var language: AppLanguage { AppLanguage.resolve(preference) }
    public static var locale: Locale { Locale(identifier: language.rawValue) }
    public static func configure(defaults: UserDefaults = .standard) {
        let value = AppLanguage(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .system
        lock.lock(); selection = value; lock.unlock()
    }
    public static func select(_ value: AppLanguage, defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: preferenceKey)
        configure(defaults: defaults)
    }

    // Resolve resources relative to the executable. Referencing SwiftPM's generated
    // Bundle.module accessor embeds the developer's absolute build path in releases.
    private static let resourceBundle: Bundle? = {
        let main = Bundle.main
        for parent in [main.resourceURL, main.bundleURL, main.bundleURL.deletingLastPathComponent()].compactMap({ $0 }) {
            if let bundle = Bundle(url: parent.appendingPathComponent("Claudeway_SwitcherCore.bundle")) { return bundle }
        }
        return nil
    }()
    public static let catalogs: [AppLanguage: [String: String]] = {
        var result: [AppLanguage: [String: String]] = [:]
        for language in AppLanguage.allCases where language != .system {
            guard let root = resourceBundle?.resourceURL,
                  let data = try? Data(contentsOf: root.appendingPathComponent("\(language.rawValue).lproj/Localizable.strings")),
                  let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { continue }
            result[language] = values
        }
        return result
    }()
    public static func text(_ key: String, _ arguments: String...) -> String {
        render(key, arguments: arguments, language: language)
    }
    public static func render(_ key: String, arguments: [String] = [], language: AppLanguage) -> String {
        let resolved = AppLanguage.resolve(language)
        let value = catalogs[resolved]?[key] ?? catalogs[.en]?[key] ?? key
        // Arguments never become format strings (account names may contain "%").
        guard !arguments.isEmpty else { return value }
        return String(format: value, locale: Locale(identifier: resolved.rawValue), arguments: arguments)
    }

    /// Journals written before localization contain Russian messages. Canonicalize
    /// only known app labels; never translate account names, paths or unknown text.
    public static func canonicalMessage(_ value: String) -> String {
        if catalogs[.en]?[value] != nil { return value }
        let prefix = "Request may have completed · "
        for language in [AppLanguage.en, .ru, .be] {
            let localizedPrefix = catalogs[language]?[prefix] ?? prefix
            if value.hasPrefix(localizedPrefix) {
                return prefix + canonicalMessage(String(value.dropFirst(localizedPrefix.count)))
            }
            if let key = catalogs[language]?.first(where: { $0.value == value })?.key { return key }
        }
        return value
    }
    public static func message(_ value: String) -> String {
        let key = canonicalMessage(value)
        let prefix = "Request may have completed · "
        if key.hasPrefix(prefix), key != prefix {
            return text(prefix) + message(String(key.dropFirst(prefix.count)))
        }
        return text(key)
    }
}
