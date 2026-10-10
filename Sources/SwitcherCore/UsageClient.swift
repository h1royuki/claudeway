import Foundation
import Security
import CommonCrypto
import LocalAuthentication

public enum UsageFailure: Error, LocalizedError {
    case keychain, format, login, identity, network, unavailable, rateLimited(TimeInterval)
    public var errorDescription: String? {
        switch self {
        case .keychain: return L10n.text("Keychain access required")
        case .format: return L10n.text("Login format changed")
        case .login: return L10n.text("Open the account in Claude")
        case .identity: return L10n.text("Account mismatch")
        case .network: return L10n.text("Cannot connect to Claude")
        case .unavailable: return L10n.text("Usage limits unavailable")
        case .rateLimited: return L10n.text("Claude asks you to wait")
        }
    }
}

/// Read-only adapter for Electron's macOS v10 storage. Never writes credentials,
/// rotates refresh tokens, changes ACLs, or queries another application's keychain item.
enum ClaudeUsageCredentials {
    private enum ReadFailure: Error { case status(OSStatus) }
    private static let keychainLock = NSLock()
    private static func password(allowPrompt: Bool) throws -> Data {
        // Electron uses a legacy login-keychain item; LAContext alone does not
        // suppress its ACL prompt. Serialize the process-wide legacy UI flag too.
        keychainLock.lock()
        defer { keychainLock.unlock() }
        var previous: DarwinBoolean = true
        guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
              SecKeychainSetUserInteractionAllowed(allowPrompt) == errSecSuccess else {
            throw ReadFailure.status(errSecInteractionNotAllowed)
        }
        defer { SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        let context = LAContext()
        context.interactionNotAllowed = !allowPrompt
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage", kSecAttrAccount as String: "Claude Key",
            kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnData as String: true,
            kSecUseAuthenticationContext as String: context]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw ReadFailure.status(status) }
        guard let password = item as? Data, !password.isEmpty else { throw ReadFailure.status(errSecDecode) }
        return password
    }

    static func access(allowPrompt: Bool) -> KeychainAccessState {
        do {
            var value = try password(allowPrompt: allowPrompt)
            value.resetBytes(in: 0..<value.count)
            return .granted
        } catch ReadFailure.status(let status) {
            switch status {
            case errSecItemNotFound: return .missing
            case errSecInteractionNotAllowed, errSecAuthFailed: return .needsPermission
            case errSecUserCanceled: return .denied
            default: return .unavailable
            }
        } catch { return .unavailable }
    }

    static func key() throws -> Data {
        var password: Data
        do { password = try self.password(allowPrompt: false) }
        catch { throw UsageFailure.keychain }
        defer { password.resetBytes(in: 0..<password.count) }
        let salt = Array("saltysalt".utf8)
        var key = Data(count: 16)
        let result = key.withUnsafeMutableBytes { output in password.withUnsafeBytes { input in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), input.bindMemory(to: Int8.self).baseAddress, password.count,
                                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                output.bindMemory(to: UInt8.self).baseAddress, 16)
        } }
        guard result == kCCSuccess else { throw UsageFailure.format }
        return key
    }

    static func decrypt(_ data: Data, key: Data) throws -> Data {
        guard data.starts(with: Data("v10".utf8)), data.count > 3,
              (data.count - 3) % 16 == 0, key.count == 16 else { throw UsageFailure.format }
        let cipher = Data(data.dropFirst(3)), iv = [UInt8](repeating: 32, count: 16)
        var output = Data(count: cipher.count + 16), written = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { destination in key.withUnsafeBytes { key in cipher.withUnsafeBytes { source in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                    key.baseAddress, 16, iv, source.baseAddress, cipher.count, destination.baseAddress, capacity, &written)
        } } }
        guard status == kCCSuccess else { throw UsageFailure.format }
        output.count = written
        return output
    }

    static func candidates(fields: [String: Any], account: UUID, org: UUID, key: Data, now: Date, inferenceOnly: Bool = false) throws -> [String] {
        var entries: [String: Any] = [:]
        // V2 overwrites legacy entries, including revoked/tombstoned entries.
        for field in ["oauth:tokenCache", "oauth:tokenCacheV2"] {
            guard let encoded = fields[field] as? String, !encoded.isEmpty else { continue }
            guard let ciphertext = Data(base64Encoded: encoded) else { throw UsageFailure.format }
            var plaintext = try decrypt(ciphertext, key: key)
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else { throw UsageFailure.format }
            entries.merge(object) { _, new in new }
        }
        let prefix = "acct:\(account.uuidString.lowercased())|"
        let clients = ["a473d7bb-17ac-43a7-abc0-a1343d7c2805", "9d1c250a-e61b-44d9-88ed-5944d1962f5e"]
        var found: [(String, Double, Int)] = []
        for (entryKey, value) in entries {
            guard entryKey.lowercased().hasPrefix(prefix),
                  let row = value as? [String: Any], let token = row["token"] as? String, !token.isEmpty,
                  let expires = row["expiresAt"] as? Double, expires > now.timeIntervalSince1970 * 1000 + 30_000 else { continue }
            let rest = String(entryKey.dropFirst(prefix.count))
            for (rank, client) in clients.enumerated() {
                let binding = "\(client):\(org.uuidString.lowercased()):https://api.anthropic.com:"
                guard rest.lowercased().hasPrefix(binding) else { continue }
                let scopes = Set(rest.dropFirst(binding.count).split(separator: " ").map(String.init))
                guard scopes.contains("user:profile") else { continue }
                if inferenceOnly && (!scopes.contains("user:inference") || expires < now.timeIntervalSince1970 * 1000 + 90_000) { continue }
                found.append((token, expires, rank + (scopes.contains("user:inference") ? 0 : 10)))
            }
        }
        var seen = Set<String>()
        return found.sorted { $0.2 == $1.2 ? $0.1 > $1.1 : $0.2 < $1.2 }.compactMap { seen.insert($0.0).inserted ? $0.0 : nil }
    }
}

/// Refuse every redirect, even same-origin, so authorization never follows one.
final class UsageNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct UsageClient {
    public init() {}
    public func fetch(profile: Profile, activeID: UUID?, root: URL, live: URL) async throws -> AccountUsage {
        let tokens = try await credentials(profile: profile, root: root, live: live)
        try Task.checkCancellation()
        guard !tokens.isEmpty else { throw UsageFailure.login }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: UsageNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await verifiedUsage(tokens: tokens, profile: profile, session: session)
    }

    func credentials(profile: Profile, root: URL, live: URL, inferenceOnly: Bool = false) async throws -> [String] {
        guard let auth = profile.auth, let account = auth.accountID, let org = profile.organizationID else { throw UsageFailure.login }
        // All Keychain and filesystem work stays off the menu/main thread.
        return try await Task.detached(priority: .utility) {
            let file: URL
            // The user may also sign in/out directly in Desktop. Its actual identity
            // takes priority over the switcher's last selected label, without editing it.
            if try AuthVault.account(in: live) == account { file = live.appendingPathComponent("config.json") }
            else {
                let vault = AuthVault(root: root.appendingPathComponent("auth-snapshots"))
                try vault.validate(auth)
                file = vault.url(auth).appendingPathComponent("auth-fields.json")
            }
            let fields = try Disk.object(file)
            guard (fields["lastKnownAccountUuid"] as? String).flatMap(UUID.init(uuidString:)) == account else { throw UsageFailure.identity }
            var key = try ClaudeUsageCredentials.key()
            defer { key.resetBytes(in: 0..<key.count) }
            return try ClaudeUsageCredentials.candidates(fields: fields, account: account, org: org, key: key, now: Date(), inferenceOnly: inferenceOnly)
        }.value
    }

    public func prepareTrigger(profile: Profile, root: URL, live: URL) async throws -> TriggerPreparation {
        let tokens = try await credentials(profile: profile, root: root, live: live, inferenceOnly: true)
        guard !tokens.isEmpty else { throw UsageFailure.login }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: UsageNoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for token in tokens.prefix(2) {
            do {
                let usage = try await verifiedUsage(tokens: [token], profile: profile, session: session)
                return TriggerPreparation(usage: usage, token: token)
            } catch UsageFailure.login { continue }
        }
        throw UsageFailure.login
    }

    func verifiedUsage(tokens: [String], profile: Profile, session: URLSession) async throws -> AccountUsage {
        guard let account = profile.auth?.accountID, let org = profile.organizationID else { throw UsageFailure.login }
        // At most two existing scoped credentials; no refresh/mint operations.
        for token in tokens.prefix(2) {
            do {
                let identity = try await request("profile", token: token, session: session)
                guard let object = try JSONSerialization.jsonObject(with: identity) as? [String: Any],
                      let user = object["account"] as? [String: Any], let organization = object["organization"] as? [String: Any],
                      (user["uuid"] as? String).flatMap(UUID.init(uuidString:)) == account,
                      (organization["uuid"] as? String).flatMap(UUID.init(uuidString:)) == org else { throw UsageFailure.identity }
                let data = try await request("usage", token: token, session: session)
                let windows: [UsageWindow]
                do { windows = try UsageParser.windows(from: data) } catch { throw UsageFailure.unavailable }
                return AccountUsage(profileID: profile.id, accountID: account, organizationID: org, observedAt: Date(), source: "server", windows: windows)
            } catch UsageFailure.login { continue }
        }
        throw UsageFailure.login
    }

    private func request(_ endpoint: String, token: String, session: URLSession) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/\(endpoint)")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw UsageFailure.network }
        guard let http = response as? HTTPURLResponse else { throw UsageFailure.network }
        switch http.statusCode {
        case 200: guard data.count < 1_000_000 else { throw UsageFailure.unavailable }; return data
        case 401, 403: throw UsageFailure.login
        case 429: throw UsageFailure.rateLimited(UsagePolling.retryDelay(http.value(forHTTPHeaderField: "Retry-After")))
        default: throw UsageFailure.unavailable
        }
    }
}
