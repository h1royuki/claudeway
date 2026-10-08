import Foundation

/// Read-only evidence for a chat whose first assistant turn hasn't finished.
/// Never imports transcript contents, tools, permissions or instructions.
enum LocalTranscript {
    static func hasConversation(cliID: String, cwd: String, root: URL?) -> Bool {
        guard UUID(uuidString: cliID) != nil, cwd.hasPrefix("/") else { return false }
        let projects = root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        // Claude's project directory encoding replaces each non-ASCII-alphanumeric
        // UTF-16 unit, including separators and punctuation, with a dash.
        let project = String(cwd.utf16.map { unit -> Character in
            if (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit) { return Character(UnicodeScalar(unit)!) }
            return "-"
        })
        let file = projects.appendingPathComponent(project).appendingPathComponent(cliID + ".jsonl")
        guard file.standardizedFileURL == file.resolvingSymlinksInPath().standardizedFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        var pending = Data()
        // Bounded streaming: normal history has messages near the start, while a
        // damaged or malicious file cannot force an unbounded allocation/read.
        var remaining = 64 * 1024 * 1024
        while remaining > 0 {
            guard let chunk = try? handle.read(upToCount: min(65536, remaining)), !chunk.isEmpty else { break }
            remaining -= chunk.count; pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                if realMessage(line, cliID: cliID, cwd: cwd) { return true }
                pending.removeSubrange(...newline)
            }
            if pending.count > 4 * 1024 * 1024 { return false }
        }
        return realMessage(pending[...], cliID: cliID, cwd: cwd)
    }
    private static func realMessage(_ line: Data.SubSequence, cliID: String, cwd: String) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              (object["sessionId"] as? String).flatMap(UUID.init(uuidString:)) == UUID(uuidString: cliID),
              object["cwd"] as? String == cwd, object["isSidechain"] as? Bool != true,
              object["isMeta"] as? Bool != true, object["isApiErrorMessage"] as? Bool != true,
              let type = object["type"] as? String, ["user", "assistant"].contains(type),
              let message = object["message"] as? [String: Any], message["role"] as? String == type,
              message["model"] as? String != "<synthetic>" else { return false }
        if let text = message["content"] as? String { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        return blocks.contains { block in
            if block["type"] as? String == "text", let text = block["text"] as? String { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if type == "assistant", block["type"] as? String == "tool_use" { return block["id"] is String && block["name"] is String }
            if type == "user", ["image", "document"].contains(block["type"] as? String ?? "") { return block["source"] is [String: Any] }
            return false
        }
    }
}
