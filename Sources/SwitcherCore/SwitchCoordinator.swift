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
        guard !isBusy else { throw StoreError.message("Операция уже выполняется.") }
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
        guard !isBusy else { throw StoreError.message("Переключение уже выполняется.") }
        isBusy = true; defer { isBusy = false }
        lastTransferReport = nil
        let previous = try store.load().activeID
        if previous == id { try await lifecycle.launch(openCode: false); return }
        try await lifecycle.stop()
        do {
            try store.switchProfile(to: id, requireStopped: lifecycle.requireStopped)
            let report = try store.transferSessions(requireStopped: lifecycle.requireStopped)
            try await lifecycle.launch(openCode: true)
            lastTransferReport = report
        } catch {
            let cause = error.localizedDescription
            do {
                try await lifecycle.stop()
                if store.needsRecovery { try store.recover(requireStopped: lifecycle.requireStopped) }
                if try store.load().activeID != previous { try store.switchProfile(to: previous, requireStopped: lifecycle.requireStopped) }
                try await lifecycle.launch(openCode: false)
            } catch { throw StoreError.message("\(cause)\nВосстановление не завершено: \(error.localizedDescription)") }
            throw StoreError.message("\(cause)\nПредыдущий аккаунт восстановлен.")
        }
    }

    public func finishAdding() async throws {
        guard !isBusy else { throw StoreError.message("Операция уже выполняется.") }
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
    public func recover() async throws {
        try await prepare()
    }
}
