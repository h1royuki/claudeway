import Foundation
import CommonCrypto
@testable import SwitcherCore

private final class UsageStub: URLProtocol {
    static var handler: (URLRequest) throws -> (Int, [String: String], Data) = { _ in (500, [:], Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class UsageClientTests {
    let account = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    let org = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
    let key = Data(repeating: 7, count: 16)
    func sealed(_ object: [String: Any]) throws -> String {
        let plain = try JSONSerialization.data(withJSONObject: object)
        var output = Data(count: plain.count + 16), count = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { dst in key.withUnsafeBytes { k in plain.withUnsafeBytes { src in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, 16, [UInt8](repeating: 32, count: 16), src.baseAddress, plain.count, dst.baseAddress, capacity, &count)
        } } }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return (Data("v10".utf8) + output.prefix(count)).base64EncodedString()
    }
    func runAll() async throws {
        let now = Date(timeIntervalSince1970: 1800000000)
        let binding = "acct:\(account.uuidString.lowercased())|a473d7bb-17ac-43a7-abc0-a1343d7c2805:\(org.uuidString.lowercased()):https://api.anthropic.com:"
        let cache: [String: Any] = [
            binding + "user:profile user:inference": ["token": "FAKE-valid", "expiresAt": now.timeIntervalSince1970 * 1000 + 100000],
            binding + "user:profile": ["token": "FAKE-expired", "expiresAt": 1],
            binding + "user:inference": ["token": "FAKE-no-profile-scope", "expiresAt": 1999999999999],
            binding.replacingOccurrences(of: "https://api.anthropic.com:", with: "https://untrusted.invalid:") + "user:profile": ["token": "FAKE-wrong-host", "expiresAt": 1999999999999]
        ]
        let fields: [String: Any] = ["oauth:tokenCache": try sealed(cache)]
        XCTAssertEqual(try ClaudeUsageCredentials.candidates(fields: fields, account: account, org: org, key: key, now: now), ["FAKE-valid"])
        XCTAssertEqual(try ClaudeUsageCredentials.candidates(fields: fields, account: UUID(), org: org, key: key, now: now), [])
        XCTAssertEqual(try ClaudeUsageCredentials.candidates(fields: fields, account: account, org: UUID(), key: key, now: now), [])
        let readOnlyAndInference = try sealed([
            binding + "user:profile": ["token": "FAKE-read-only", "expiresAt": now.timeIntervalSince1970 * 1000 + 100000],
            binding.replacingOccurrences(of: "a473d7bb-17ac-43a7-abc0-a1343d7c2805", with: "9d1c250a-e61b-44d9-88ed-5944d1962f5e") + "user:profile user:inference user:sessions:claude_code": ["token": "FAKE-Code", "expiresAt": now.timeIntervalSince1970 * 1000 + 100000]
        ])
        XCTAssertEqual(try ClaudeUsageCredentials.candidates(fields: ["oauth:tokenCacheV2": readOnlyAndInference], account: account, org: org, key: key, now: now, inferenceOnly: true), ["FAKE-Code"])
        var revoked = fields
        revoked["oauth:tokenCacheV2"] = try sealed([binding + "user:profile user:inference": NSNull()])
        XCTAssertEqual(try ClaudeUsageCredentials.candidates(fields: revoked, account: account, org: org, key: key, now: now), [])
        XCTAssertThrowsError(try ClaudeUsageCredentials.decrypt(Data("v20-unsupported".utf8), key: key))
        XCTAssertThrowsError(try ClaudeUsageCredentials.decrypt(Data("v10-broken".utf8), key: key))
        print("PASS credential binding, scoped selection, expiry, revocation and encryption format")

        var gate = UsagePolling()
        XCTAssertTrue(gate.allows(account, force: false, now: now))
        gate.started(account, now: now)
        XCTAssertFalse(gate.allows(account, force: true, now: now.addingTimeInterval(59)))
        XCTAssertTrue(gate.allows(account, force: true, now: now.addingTimeInterval(60)))
        XCTAssertFalse(gate.allows(account, force: false, now: now.addingTimeInterval(299)))
        XCTAssertTrue(gate.allows(account, force: false, now: now.addingTimeInterval(300)))
        gate.rateLimited(account, delay: 7200, now: now)
        XCTAssertFalse(gate.allows(account, force: true, now: now.addingTimeInterval(7199)))
        XCTAssertTrue(gate.allows(account, force: true, now: now.addingTimeInterval(7200)))
        XCTAssertEqual(UsagePolling.retryDelay("7200"), 7200)
        XCTAssertEqual(UsagePolling.retryDelay("invalid"), 900)
        let restored = try JSONDecoder().decode(UsagePolling.self, from: JSONEncoder().encode(gate))
        XCTAssertFalse(restored.allows(account, force: true, now: now.addingTimeInterval(600)))
        print("PASS polling throttle, manual floor and persisted server backoff")

        let profile = Profile(name: "Synthetic", auth: AuthReference(generation: UUID(), accountID: account), organizationID: org)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UsageStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let identity = try JSONSerialization.data(withJSONObject: ["account": ["uuid": account.uuidString], "organization": ["uuid": org.uuidString]])
        var paths: [String] = []
        UsageStub.handler = { req in
            XCTAssertEqual(req.url?.host, "api.anthropic.com")
            XCTAssertEqual(req.httpMethod, "GET")
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer FAKE-valid")
            paths.append(req.url!.path)
            return (200, [:], req.url!.path.hasSuffix("profile") ? identity : Data(#"{"five_hour":{"utilization":20,"resets_at":"2027-01-01T00:00:00Z"}}"#.utf8))
        }
        let result = try await UsageClient().verifiedUsage(tokens: ["FAKE-valid"], profile: profile, session: session)
        XCTAssertEqual(result.windows[0].usedPercent, 20)
        XCTAssertEqual(paths, ["/api/oauth/profile", "/api/oauth/usage"])
        UsageStub.handler = { _ in (200, [:], Data(#"{"account":{"uuid":"cccccccc-cccc-4ccc-8ccc-cccccccccccc"},"organization":{"uuid":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"}}"#.utf8)) }
        do { _ = try await UsageClient().verifiedUsage(tokens: ["FAKE-valid"], profile: profile, session: session); XCTFail("Identity mismatch accepted") }
        catch UsageFailure.identity {} catch { XCTFail("Wrong mismatch error") }
        UsageStub.handler = { _ in (429, ["Retry-After": "7200"], Data("sensitive body must not become an error".utf8)) }
        do { _ = try await UsageClient().verifiedUsage(tokens: ["FAKE-valid"], profile: profile, session: session); XCTFail("429 accepted") }
        catch UsageFailure.rateLimited(let delay) { XCTAssertEqual(delay, 7200) } catch { XCTFail("Wrong rate-limit error") }
        UsageStub.handler = { _ in (302, ["Location": "https://untrusted.invalid"], Data()) }
        do { _ = try await UsageClient().verifiedUsage(tokens: ["FAKE-valid"], profile: profile, session: session); XCTFail("Redirect accepted") }
        catch UsageFailure.unavailable {} catch { XCTFail("Wrong redirect error") }
        var deniedRedirect = false
        UsageNoRedirect().urlSession(session, task: session.dataTask(with: URL(string: "https://api.anthropic.com")!), willPerformHTTPRedirection: HTTPURLResponse(url: URL(string: "https://api.anthropic.com")!, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: URLRequest(url: URL(string: "https://untrusted.invalid")!)) { deniedRedirect = $0 == nil }
        XCTAssertTrue(deniedRedirect)
        print("PASS verified API identities, HTTPS origin, usage response, 429 and redirect refusal")

        let folder = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.json")
        try UsageCache.save([profile.id: result], at: file)
        XCTAssertEqual(UsageCache.load(at: file, profiles: [profile])[profile.id], result)
        XCTAssertEqual(UsageCache.load(at: file, profiles: [Profile(id: profile.id, name: "Different", auth: AuthReference(generation: UUID(), accountID: UUID()), organizationID: org)]).count, 0)
        let content = try String(contentsOf: file)
        XCTAssertFalse(content.contains("FAKE-valid"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        print("PASS private stats cache, identity isolation and no tokens in persistence")
    }
}
