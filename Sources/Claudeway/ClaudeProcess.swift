import AppKit
import SwitcherCore

@MainActor final class ClaudeProcess: ClaudeLifecycle {
    static let bundleID = "com.anthropic.claudefordesktop"
    private var watched = Set<Int32>()
    private let workspace = NSWorkspace.shared

    private func applicationURL() throws -> URL {
        guard let url = workspace.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            throw StoreError.message(L10n.text("Claude was not found. Install Claude in Applications."))
        }
        return url
    }

    private struct ProcessRow {
        let pid: Int32
        let parent: Int32
        let command: String
    }

    private func rows() throws -> [ProcessRow] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        // comm excludes arguments, prompts and tokens.
        task.arguments = ["-Aww", "-o", "pid=,ppid=,comm="]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw StoreError.message(L10n.text("Could not check Claude processes. Switching cancelled."))
        }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count == 3, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { return nil }
            return ProcessRow(pid: pid, parent: parent, command: String(parts[2]))
        }
    }

    private func remaining() throws -> Set<Int32> {
        let all = try rows()
        let application = try applicationURL().path + "/Contents/"
        var current = Set(all.filter { $0.command.hasPrefix(application) }.map(\.pid))
        current.formUnion(NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).map(\.processIdentifier))
        // Remember descendants across reparenting when the main process exits.
        current.formUnion(watched.intersection(Set(all.map(\.pid))))
        var changed = true
        while changed {
            let before = current.count
            current.formUnion(all.filter { current.contains($0.parent) }.map(\.pid))
            changed = before != current.count
        }
        watched = current
        return current
    }

    func stop() async throws {
        _ = try remaining()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID) {
            _ = app.terminate()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !(try remaining()).isEmpty {
            guard ContinuousClock.now < deadline else {
                throw StoreError.message(L10n.text("Claude or its background tasks did not quit within 30 seconds. Stop the tasks, quit Claude and try again. The profile was not switched."))
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    func requireStopped() throws {
        guard try remaining().isEmpty else {
            throw StoreError.message(L10n.text("Claude is running again. Data changes stopped; quit Claude and choose Recover."))
        }
    }

    func launch(openCode: Bool) async throws {
        let url = try applicationURL()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            workspace.openApplication(at: url, configuration: config) { app, error in
                if let error { continuation.resume(throwing: error) }
                else if let app { continuation.resume(returning: app) }
                else { continuation.resume(throwing: StoreError.message(L10n.text("macOS did not confirm that Claude launched."))) }
            }
        }
        if openCode {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                workspace.open([URL(string: "claude://code/new")!], withApplicationAt: url, configuration: config) { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        guard !app.isTerminated else { throw StoreError.message(L10n.text("Claude quit immediately after launch.")) }
    }
}

/// Runs only when explicitly passed --demo, with disposable profile data.
@MainActor final class DemoLifecycle: ClaudeLifecycle {
    func stop() async throws { try await Task.sleep(nanoseconds: 200_000_000) }
    func requireStopped() throws {}
    func launch(openCode: Bool) async throws {}
}
