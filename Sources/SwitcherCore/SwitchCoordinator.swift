import Foundation

@MainActor public protocol ClaudeLifecycle: AnyObject {
    func stop() async throws
    func requireStopped() throws
    func launch(openCode: Bool) async throws
}

@MainActor public final class SwitchCoordinator {
    public private(set) var isBusy = false
    public private(set) var lastTransferReport: SessionTransferReport?
    public func takeTransferReport() -> SessionTransferReport? {
        defer { lastTransferReport = nil }
        return lastTransferReport
    }
    public let store: ProfileStore
    private let lifecycle: ClaudeLifecycle
    public init(store: ProfileStore, lifecycle: ClaudeLifecycle) { self.store = store; self.lifecycle = lifecycle }

    public func prepare(settingsBaseID: UUID? = nil) async throws {
        guard !isBusy else { throw StoreError.message(L10n.text("An operation is already running.")) }
        isBusy = true; defer { isBusy = false }
        lastTransferReport = nil
        if !store.needsPreparation && !store.needsRecovery { _ = try store.load(); return }
        try await lifecycle.stop()
        do {
            if store.needsRecovery { try store.recover(requireStopped: lifecycle.requireStopped) }
            _ = try store.initialize(requireStopped: lifecycle.requireStopped, settingsBaseID: settingsBaseID)
            let report = try store.transferSessions(requireStopped: lifecycle.requireStopped)
            try await lifecycle.launch(openCode: true)
            lastTransferReport = report
        } catch {
            let original = error
            if store.needsRecovery { _ = try? store.recover(requireStopped: lifecycle.requireStopped) }
            if !store.needsRecovery { try? await lifecycle.launch(openCode: false) }
            throw original
        }
    }

    public func select(_ id: UUID) async throws {
        guard !isBusy else { throw StoreError.message(L10n.text("Account switching is already in progress.")) }
        isBusy = true; defer { isBusy = false }
        lastTransferReport = nil
        let previous = try store.load().activeID
        if previous == id { try await lifecycle.launch(openCode: false); return }
        try await lifecycle.stop()
        var detached: AuthReference?
        do {
            if previous == nil { detached = try store.captureDetachedLogin(requireStopped: lifecycle.requireStopped) }
            try store.switchProfile(to: id, requireStopped: lifecycle.requireStopped)
            let report = try store.transferSessions(requireStopped: lifecycle.requireStopped)
            try await lifecycle.launch(openCode: true)
            lastTransferReport = report
        } catch {
            let cause = error.localizedDescription
            do {
                try await lifecycle.stop()
                if store.needsRecovery { try store.recover(requireStopped: lifecycle.requireStopped) }
                if try store.load().activeID != previous {
                    if let previous { try store.switchProfile(to: previous, requireStopped: lifecycle.requireStopped) }
                    else if let detached { try store.restoreDetachedLogin(detached, requireStopped: lifecycle.requireStopped) }
                }
                try await lifecycle.launch(openCode: false)
            } catch { throw StoreError.message(L10n.text("%@\nRecovery is incomplete: %@", cause, error.localizedDescription)) }
            throw StoreError.message(L10n.text("%@\nThe previous account was restored.", cause))
        }
    }

    public func finishAdding() async throws {
        guard !isBusy else { throw StoreError.message(L10n.text("An operation is already running.")) }
        isBusy = true; defer { isBusy = false }
        lastTransferReport = nil
        try await lifecycle.stop()
        do {
            _ = try store.finishAdding(requireStopped: lifecycle.requireStopped)
            let report = try store.transferSessions(requireStopped: lifecycle.requireStopped)
            try await lifecycle.launch(openCode: true)
            lastTransferReport = report
        } catch {
            try? await lifecycle.launch(openCode: false)
            throw error
        }
    }
    public func beginAdding(_ name: String) async throws {
        guard !isBusy else { throw StoreError.message(L10n.text("An operation is already running.")) }
        lastTransferReport = nil
        let state = try store.add(name)
        guard let pending = state.pending else { return }
        // For the first account, keep the existing Desktop login and let the user
        // sign in if necessary. Finishing explicitly captures that login.
        if pending.previousID == nil {
            isBusy = true; defer { isBusy = false }
            try await lifecycle.launch(openCode: true)
        } else { try await select(pending.id) }
    }
    public func cancelAdding() async throws {
        guard !isBusy else { throw StoreError.message(L10n.text("An operation is already running.")) }
        lastTransferReport = nil
        if let previous = try store.load().pending?.previousID { try await select(previous) }
        _ = try store.cancelAdding()
    }
    public func recover() async throws {
        try await prepare()
    }
}
