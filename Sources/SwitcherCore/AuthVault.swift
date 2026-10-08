import Foundation
import CryptoKit
import Darwin

enum Disk {
    static let fm = FileManager.default
    static func exists(_ url: URL) -> Bool { (try? fm.attributesOfItem(atPath: url.path)) != nil }
    static func directory(_ url: URL) throws {
        if !exists(url) { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory,
              url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
            throw StoreError.message("Небезопасный каталог: \(url.lastPathComponent)")
        }
    }
    static func read(_ url: URL) throws -> Data {
        guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular,
              url.standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
            throw StoreError.message("Ожидался обычный файл: \(url.lastPathComponent)")
        }
        return try Data(contentsOf: url)
    }
    static func object(_ url: URL) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: read(url)) as? [String: Any] else {
            throw StoreError.message("Неверный формат \(url.lastPathComponent).")
        }
        return result
    }
    static func write(_ data: Data, _ url: URL) throws {
        try directory(url.deletingLastPathComponent())
        let temp = url.deletingLastPathComponent().appendingPathComponent(".write-\(UUID().uuidString)")
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StoreError.message("Не удалось создать файл состояния.") }
        defer { close(fd); try? fm.removeItem(at: temp) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw StoreError.message("Не удалось записать файл состояния.") }
                offset += n
            }
        }
        guard fsync(fd) == 0, Darwin.rename(temp.path, url.path) == 0 else { throw StoreError.message("Не удалось сохранить файл состояния.") }
        sync(url.deletingLastPathComponent())
    }
    static func write<T: Encodable>(_ value: T, _ url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(value), url)
    }
    static func writeObject(_ value: [String: Any], _ url: URL) throws {
        try write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), url)
    }
    static func sync(_ directory: URL) {
        let fd = open(directory.path, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }
    static func syncTree(_ url: URL) throws {
        let kind = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        if kind == .typeDirectory {
            for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try syncTree(child) }
            sync(url)
        } else if kind == .typeRegular {
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { throw StoreError.message("Не удалось синхронизировать сохранённый вход.") }
            defer { close(fd) }
            guard fsync(fd) == 0 else { throw StoreError.message("Не удалось синхронизировать сохранённый вход.") }
        } else { throw StoreError.message("Специальный файл в состоянии входа.") }
    }
    static func move(_ from: URL, _ to: URL) throws {
        guard !exists(to) else { throw StoreError.message("Каталог назначения уже существует.") }
        try directory(to.deletingLastPathComponent())
        guard Darwin.rename(from.path, to.path) == 0 else { throw StoreError.message("Не удалось переместить \(from.lastPathComponent).") }
        sync(from.deletingLastPathComponent()); sync(to.deletingLastPathComponent())
    }
    static func clone(_ from: URL, _ to: URL) throws {
        guard !exists(to) else { throw StoreError.message("Резервная копия уже существует.") }
        try directory(to.deletingLastPathComponent())
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/cp")
        task.arguments = ["-cRp", from.path, to.path]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw StoreError.message("Не удалось создать APFS-копию. Исходные данные сохранены.") }
        sync(to.deletingLastPathComponent())
    }
    static func mergeMissing(_ preferred: [String: Any], _ other: [String: Any]) -> [String: Any] {
        var result = preferred
        for (key, value) in other {
            if let a = result[key] as? [String: Any], let b = value as? [String: Any] { result[key] = mergeMissing(a, b) }
            else if result[key] == nil { result[key] = value }
        }
        return result
    }
}

public struct AuthReference: Codable, Equatable {
    public let generation: UUID
    public let accountID: UUID?
}

private struct AuthManifest: Codable {
    var version = 1
    let reference: AuthReference
    let parts: [String]
    let hashes: [String: String]
}

/// Keeps the encrypted blobs exactly as Claude wrote them. No Keychain access,
/// decryption, token refresh, API calls, or plaintext token export.
final class AuthVault {
    static let keys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"]
    static let parts = ["Cookies", "Cookies-journal", "Cookies-wal", "Cookies-shm",
                        "Network/Cookies", "Network/Cookies-journal", "Network/Cookies-wal", "Network/Cookies-shm",
                        "Local Storage", "Session Storage", "IndexedDB"]
    static let transient = "bridge-state.json"
    let root: URL
    init(root: URL) { self.root = root }
    func url(_ reference: AuthReference) -> URL { root.appendingPathComponent(reference.generation.uuidString) }

    static func account(in directory: URL) throws -> UUID? {
        let file = directory.appendingPathComponent("config.json")
        guard Disk.exists(file) else { return nil }
        let object = try Disk.object(file)
        guard let value = object["lastKnownAccountUuid"] as? String else { return nil }
        return UUID(uuidString: value)
    }

    func capture(_ directory: URL?, requireLogin: Bool = false) throws -> AuthReference {
        var fields: [String: Any] = [:]
        if let directory, Disk.exists(directory.appendingPathComponent("config.json")) {
            let config = try Disk.object(directory.appendingPathComponent("config.json"))
            for key in Self.keys { if let value = config[key] { fields[key] = value } }
        }
        let account = (fields["lastKnownAccountUuid"] as? String).flatMap(UUID.init(uuidString:))
        let hasToken = Self.keys.prefix(2).contains { !(fields[$0] as? String ?? "").isEmpty }
        if requireLogin && (account == nil || !hasToken) { throw StoreError.message("Войдите в Claude, затем нажмите «Готово, я вошёл».") }
        let reference = AuthReference(generation: UUID(), accountID: account)
        let output = url(reference)
        try Disk.directory(output)
        try Disk.writeObject(fields, output.appendingPathComponent("auth-fields.json"))
        var present: [String] = []
        if let directory {
            for name in Self.parts + [Self.transient] {
                let from = directory.appendingPathComponent(name)
                if Disk.exists(from) {
                    try validateTree(from)
                    let to = output.appendingPathComponent(name)
                    try Disk.directory(to.deletingLastPathComponent())
                    try Disk.fm.copyItem(at: from, to: to)
                    present.append(name)
                }
            }
        }
        let hashes = try fileHashes(output)
        try Disk.syncTree(output)
        try Disk.write(AuthManifest(reference: reference, parts: present, hashes: hashes), output.appendingPathComponent("manifest.json"))
        try validate(reference)
        return reference
    }

    func validate(_ reference: AuthReference) throws {
        let folder = url(reference)
        try Disk.directory(folder)
        let manifest = try JSONDecoder().decode(AuthManifest.self, from: Disk.read(folder.appendingPathComponent("manifest.json")))
        guard manifest.version == 1, manifest.reference == reference,
              Set(manifest.parts).count == manifest.parts.count,
              Set(manifest.parts).isSubset(of: Set(Self.parts + [Self.transient])) else {
            throw StoreError.message("Некорректная сохранённая авторизация.")
        }
        let fields = try Disk.object(folder.appendingPathComponent("auth-fields.json"))
        guard Set(fields.keys).isSubset(of: Set(Self.keys)),
              fields.values.allSatisfy({ $0 is String || $0 is NSNull }),
              (fields["lastKnownAccountUuid"] as? String).flatMap(UUID.init(uuidString:)) == reference.accountID else {
            throw StoreError.message("Некорректные поля авторизации.")
        }
        for name in manifest.parts { guard Disk.exists(folder.appendingPathComponent(name)) else { throw StoreError.message("Сохранённое состояние входа неполное.") } }
        guard try fileHashes(folder) == manifest.hashes else { throw StoreError.message("Сохранённое состояние входа повреждено. Переключение отменено.") }
    }

    func apply(_ reference: AuthReference, to live: URL, restoreTransient: Bool = false,
               requireStopped: () throws -> Void, checkpoint: (String) throws -> Void = { _ in }) throws {
        try validate(reference)
        try requireStopped()
        let folder = url(reference)
        let file = live.appendingPathComponent("config.json")
        var config = Disk.exists(file) ? try Disk.object(file) : [:]
        for key in Self.keys { config.removeValue(forKey: key) }
        let fields = try Disk.object(folder.appendingPathComponent("auth-fields.json"))
        for (key, value) in fields { config[key] = value }
        try Disk.writeObject(config, file)
        try checkpoint("config")
        for name in Self.parts + [Self.transient] {
            try requireStopped()
            let destination = live.appendingPathComponent(name)
            if Disk.exists(destination) {
                try validateTree(destination)
                try Disk.fm.removeItem(at: destination)
            }
            let source = folder.appendingPathComponent(name)
            if (name != Self.transient || restoreTransient) && Disk.exists(source) {
                try Disk.directory(destination.deletingLastPathComponent())
                try Disk.fm.copyItem(at: source, to: destination)
                try Disk.syncTree(destination)
            }
            Disk.sync(destination.deletingLastPathComponent())
            try checkpoint(name)
        }
    }

    private func validateTree(_ root: URL) throws {
        let type = try Disk.fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType
        guard type == .typeDirectory || type == .typeRegular,
              root.standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL else { throw StoreError.message("Ссылка или специальный файл в состоянии входа.") }
        if type == .typeDirectory {
            for child in try Disk.fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) { try validateTree(child) }
        }
    }
    private func fileHashes(_ folder: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        func visit(_ directory: URL, prefix: String) throws {
            for child in try Disk.fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if prefix.isEmpty && child.lastPathComponent == "manifest.json" { continue }
                let relative = prefix + child.lastPathComponent
                let kind = try Disk.fm.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType
                if kind == .typeDirectory { try validateTree(child); try visit(child, prefix: relative + "/") }
                else if kind == .typeRegular {
                    try validateTree(child)
                    let handle = try FileHandle(forReadingFrom: child); defer { try? handle.close() }
                    var hash = SHA256()
                    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
                    result[relative] = hash.finalize().map { String(format: "%02x", $0) }.joined()
                } else { throw StoreError.message("Специальный файл в сохранённой авторизации.") }
            }
        }
        try visit(folder, prefix: "")
        return result
    }
}
