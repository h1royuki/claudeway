import Foundation
@testable import SwitcherCore

private actor AccessReader {
    private var results: [KeychainAccessState]
    private var calls: [Bool] = []
    private let delayed: Bool
    init(_ results: [KeychainAccessState], delayed: Bool = false) { self.results = results; self.delayed = delayed }
    func read(_ interactive: Bool) async -> KeychainAccessState {
        calls.append(interactive)
        let result = results.isEmpty ? KeychainAccessState.unavailable : results.removeFirst()
        if delayed { try? await Task.sleep(nanoseconds: 20_000_000) }
        return result
    }
    func history() -> [Bool] { calls }
}

final class KeychainAccessTests {
    @MainActor func runAll() async {
        let allowed = AccessReader([.granted, .needsPermission, .granted])
        let existing = KeychainAccess(reader: { await allowed.read($0) })
        var prompts = 0
        existing.beforePrompt = { prompts += 1 }
        let result = await existing.authorize()
        XCTAssertEqual(result, .granted)
        let already = await existing.authorize()
        XCTAssertEqual(already, .granted)
        XCTAssertEqual(prompts, 0)
        var history = await allowed.history(); XCTAssertEqual(history, [false])
        existing.noteDenied()
        let revoked = await existing.authorize()
        XCTAssertEqual(revoked, .denied)
        history = await allowed.history(); XCTAssertEqual(history, [false])
        let recovered = await existing.authorize(manual: true)
        XCTAssertEqual(recovered, .granted)
        history = await allowed.history(); XCTAssertEqual(history, [false, false, true])
        XCTAssertEqual(prompts, 1)
        print("PASS granted Keychain startup is silent; revocation requires an explicit retry")

        let denied = AccessReader([.needsPermission, .denied, .needsPermission, .granted])
        let access = KeychainAccess(reader: { await denied.read($0) })
        let refused = await access.authorize()
        XCTAssertEqual(refused, .denied)
        for _ in 0..<5 { _ = await access.authorize() }
        history = await denied.history(); XCTAssertEqual(history, [false, true])
        let retry = await access.authorize(manual: true)
        XCTAssertEqual(retry, .granted)
        history = await denied.history(); XCTAssertEqual(history, [false, true, false, true])
        print("PASS startup asks once after a silent probe; denial never loops during later refreshes")

        for failure in [KeychainAccessState.missing, .unavailable, .denied] {
            let reader = AccessReader([failure])
            let gate = KeychainAccess(reader: { await reader.read($0) })
            gate.beforePrompt = { XCTFail("missing/unavailable storage must not prompt") }
            let result = await gate.authorize()
            XCTAssertEqual(result, failure)
            history = await reader.history(); XCTAssertEqual(history, [false])
        }
        print("PASS missing or unavailable Keychain items never create spurious startup prompts")

        let slow = AccessReader([.needsPermission, .granted], delayed: true)
        let shared = KeychainAccess(reader: { await slow.read($0) })
        var shown = 0
        shared.beforePrompt = { shown += 1 }
        async let a = shared.authorize()
        async let b = shared.authorize()
        let values = await [a, b]
        XCTAssertEqual(values, [.granted, .granted])
        history = await slow.history(); XCTAssertEqual(history, [false, true])
        XCTAssertEqual(shown, 1)
        XCTAssertFalse(shared.isChecking)
        XCTAssertEqual(shared.state, .granted)
        print("PASS overlapping startup checks share one Keychain prompt without real credentials")
    }
}
