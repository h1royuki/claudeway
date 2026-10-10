import Foundation

/// A global policy for future local-chat imports and metadata updates.
/// Missing settings retain the previous all-project behavior; invalid settings
/// throw instead of silently broadening the user's selection.
public struct TransferSettings: Codable, Equatable {
    public enum Mode: String, Codable, CaseIterable { case all, selected, disabled }
    public var version = 1
    public var mode: Mode = .all
    public var projects = Set<String>()
    public init() {}

    public static func projectPath(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), !value.contains("\0") else { return nil }
        // Do not resolve symlinks or require the project to be mounted today.
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }
    public func includes(_ path: String) -> Bool {
        switch mode {
        case .all: return true
        case .disabled: return false
        case .selected: return projects.contains(path)
        }
    }
    private func validated() throws -> Self {
        guard version == 1, projects.allSatisfy({ Self.projectPath($0) == $0 }) else {
            throw StoreError.message(L10n.text("Invalid chat transfer settings. Choose the projects again."))
        }
        return self
    }
    public static func load(at root: URL) throws -> Self {
        let url = root.appendingPathComponent("chat-transfer-settings.json")
        guard Disk.exists(url) else { return Self() }
        do { return try JSONDecoder().decode(Self.self, from: Disk.read(url)).validated() }
        catch { throw StoreError.message(L10n.text("Invalid chat transfer settings. Choose the projects again.")) }
    }
    public func save(at root: URL) throws {
        try Disk.write(validated(), root.appendingPathComponent("chat-transfer-settings.json"))
    }
}

public struct TransferProject: Equatable {
    public let path: String
    public let chatCount: Int
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public init(path: String, chatCount: Int) { self.path = path; self.chatCount = chatCount }
}
