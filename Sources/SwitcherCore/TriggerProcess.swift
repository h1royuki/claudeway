import Foundation
import Security
import Darwin

public struct DesktopTriggerBackend: TriggerBackend {
    private let root: URL
    private let live: URL
    public init(root: URL, live: URL) { self.root = root; self.live = live }
    public func prepare(_ profile: Profile, allowPrompt: Bool) async throws -> TriggerPreparation {
        // Validate availability before putting a send barrier into the journal.
        _ = try await Task.detached(priority: .utility) { try TriggerProcess.executable() }.value
        return try await UsageClient().prepareTrigger(profile: profile, root: root, live: live, allowKeychainPrompt: allowPrompt)
    }
    public func send(_ preparation: TriggerPreparation) async throws -> TriggerSendResult {
        try await TriggerProcess.send(token: preparation.token, root: root)
    }
    public func usage(_ profile: Profile) async throws -> AccountUsage {
        try await UsageClient().fetch(profile: profile, activeID: profile.id, root: root, live: live)
    }
}

// Output is bounded and only parsed in memory. Never log child output or environment.
private final class TriggerOutput: @unchecked Sendable {
    let lock = NSLock()
    private var data = Data()
    func append(_ bytes: Data) { lock.lock(); defer { lock.unlock() }; if data.count < 131072 { data.append(bytes.prefix(131072 - data.count)) } }
    func value() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
struct TriggerChildResult { let status: Int32; let data: Data; let timedOut: Bool }

enum TriggerProcess {
    static func executable() throws -> URL {
        let managedFiles = ["/Library/Application Support/ClaudeCode/managed-settings.json", "/Library/Managed Preferences/com.anthropic.claudecode.plist"]
        // This utility cannot safely promise isolated account routing under externally
        // managed Claude Code settings. Keep those policies intact and fail closed.
        if managedFiles.contains(where: { FileManager.default.fileExists(atPath: $0) }) { throw TriggerFailure.managed }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent(".local/bin/claude").path, "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        for path in paths where FileManager.default.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            var code: SecStaticCode?
            var requirement: SecRequirement?
            let constraint = "anchor apple generic and identifier \"com.anthropic.claude-code\" and certificate leaf[subject.OU] = \"Q6L2SF6YDW\""
            guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
                  SecRequirementCreateWithString(constraint as CFString, [], &requirement) == errSecSuccess,
                  let code, SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess else { continue }
            return url
        }
        throw TriggerFailure.missingCLI
    }
    static func environment(token: String, config: URL) -> [String: String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": NSTemporaryDirectory(), "LANG": "en_US.UTF-8", "CLAUDE_CONFIG_DIR": config.path,
                "CLAUDE_CODE_OAUTH_TOKEN": token, "CLAUDE_CODE_SAFE_MODE": "1", "DISABLE_AUTOUPDATER": "1",
                "DISABLE_NONESSENTIAL_TRAFFIC": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
                "CLAUDE_CODE_DEBUG_LOGS_DIR": config.appendingPathComponent("debug").path]
    }
    static let arguments = ["--print", "--safe-mode", "--model", "sonnet", "--effort", "low",
                            "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                            "--setting-sources", "", "--settings", "{\"disableAllHooks\":true}",
                            "--no-session-persistence", "--no-chrome", "--disable-slash-commands",
                            "--debug-file", "/dev/null", "--max-turns", "1", "--output-format", "json", "Reply only OK"]

    static func send(token: String, root: URL) async throws -> TriggerSendResult {
        let executable = try await Task.detached(priority: .utility) { try TriggerProcess.executable() }.value
        let runtime = root.appendingPathComponent("trigger-runtime")
        try Disk.directory(runtime)
        let run = runtime.appendingPathComponent(UUID().uuidString)
        try Disk.directory(run)
        defer { try? FileManager.default.removeItem(at: run) }
        let config = run.appendingPathComponent("config"), workspace = run.appendingPathComponent("workspace")
        try Disk.directory(config); try Disk.directory(workspace)
        let env = environment(token: token, config: config)
        let help = try await child(executable: executable, arguments: ["--help"], environment: environment(token: "", config: config), directory: workspace, timeout: 10)
        let helpText = String(decoding: help.data, as: UTF8.self)
        guard help.status == 0, ["--safe-mode", "--no-session-persistence", "--setting-sources", "--tools", "--strict-mcp-config"].allSatisfy(helpText.contains) else { throw TriggerFailure.incompatibleCLI }
        let result = try await child(executable: executable, arguments: arguments, environment: env, directory: workspace, timeout: 60)
        if result.timedOut { return .uncertain }
        guard let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else { return .uncertain }
        if result.status == 0, object["type"] as? String == "result", object["subtype"] as? String == "success", object["is_error"] as? Bool != true { return .completed }
        // Use a closed set of public labels; neither raw output nor exception text is persisted.
        let description = ((object["result"] as? String) ?? "").lowercased()
        if description.contains("oauth") || description.contains("authentication") || description.contains("login") || description.contains("401") {
            return .rejected(L10n.text("Open the account in Claude"))
        }
        if description.contains("limit") || description.contains("429") { return .rateLimited }
        return .uncertain
    }

    static func child(executable: URL, arguments: [String], environment: [String: String], directory: URL, timeout: TimeInterval) async throws -> TriggerChildResult {
        let process = Process(), output = Pipe(), errors = Pipe(), buffer = TriggerOutput()
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in buffer.append(handle.availableData) }
        // Drain stderr without retaining or displaying it (could contain auth context).
        errors.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
            throw TriggerFailure.launch
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline || Task.isCancelled {
                timedOut = true
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace { try? await Task.sleep(nanoseconds: 50_000_000) }
                // Only our disposable tool-free child, never Claude Desktop or a user CLI.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil; errors.fileHandleForReading.readabilityHandler = nil
        buffer.append(output.fileHandleForReading.readDataToEndOfFile())
        return TriggerChildResult(status: process.terminationStatus, data: buffer.value(), timedOut: timedOut)
    }
}
