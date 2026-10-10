import Foundation

public enum KeychainAccessState: Equatable, Sendable {
    case unchecked, checking, granted, needsPermission, denied, missing, unavailable
}

/// One startup authorization flow; usage/trigger requests remain noninteractive.
/// Only permission state is retained, never the password or derived key.
@MainActor public final class KeychainAccess {
    public private(set) var state: KeychainAccessState = .unchecked
    public var onChange: (() -> Void)?
    public var beforePrompt: (() -> Void)?
    private var task: Task<KeychainAccessState, Never>?
    private let reader: @Sendable (Bool) async -> KeychainAccessState
    public var isChecking: Bool { task != nil }

    public init() {
        reader = { allowPrompt in
            await Task.detached(priority: .userInitiated) {
                ClaudeUsageCredentials.access(allowPrompt: allowPrompt)
            }.value
        }
    }
    // Synthetic tests inject a reader; production never invokes a shell or logs secrets.
    init(reader: @escaping @Sendable (Bool) async -> KeychainAccessState) { self.reader = reader }

    @discardableResult public func authorize(manual: Bool = false) async -> KeychainAccessState {
        if let task { return await task.value }
        // Once per app launch, including after denial. Only an explicit menu action retries.
        guard manual || state == .unchecked else { return state }
        state = .checking
        let task = Task { [reader, weak self] in
            let probe = await reader(false)
            guard probe == .needsPermission else { return probe }
            self?.beforePrompt?()
            return await reader(true)
        }
        self.task = task; onChange?()
        let result = await task.value
        self.task = nil; state = result; onChange?()
        return result
    }

    public func noteDenied() {
        guard !isChecking else { return }
        state = .denied; onChange?()
    }
}
