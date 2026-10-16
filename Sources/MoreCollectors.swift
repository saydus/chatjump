import Cocoa

// MARK: - Codex threads (~/.codex/session_index.jsonl), opened with codex://threads/<id>

enum CodexCollector {
    static func collect(maxAgeDays: Double = 30) -> [ChatItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let text = try? String(contentsOf: home.appendingPathComponent(".codex/session_index.jsonl"), encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86400)

        // Later lines update earlier ones (renames), so keep the last entry per thread.
        var latest: [String: (name: String, updated: Date)] = [:]
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? String, let name = obj["thread_name"] as? String else { continue }
            let updated = (obj["updated_at"] as? String).flatMap { iso.date(from: $0) } ?? .distantPast
            latest[id] = (name, updated)
        }
        let rollouts = Transcripts.codexRollouts()
        return latest.filter { $0.value.updated > cutoff }
            .sorted { $0.value.updated > $1.value.updated }
            .map { id, v in
                let item = ChatItem(source: .codex, title: String(v.name.prefix(140)), detail: relative(v.updated), recency: v.updated) {
                    if let url = URL(string: "codex://threads/\(id)") { NSWorkspace.shared.open(url) }
                }
                item.lastExchange = rollouts[id].flatMap { Transcripts.lastExchange(in: $0, format: .codex) }
                return item
            }
    }

    static func relative(_ d: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Last messages from local transcripts

/// Reads the tail of agent transcripts so Jev can match on what a chat is actually about,
/// not just its title. Results are cached per file and modification time.
enum Transcripts {
    enum Format { case claude, codex }

    private static var cache: [String: (Date, String?, String?)] = [:]   // path -> (mtime, title, last exchange)
    private static let lock = NSLock()

    /// Claude Code transcripts keyed by session title, so Claude sidebar sessions can be matched to their contents.
    static func claudeByTitle(maxAgeDays: Double = 30) -> [String: String] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86400)
        var out: [String: (Date, String)] = [:]
        for file in jsonlFiles(under: root, depth: 2) where file.1 > cutoff {
            let (title, exchange) = read(file.0, mtime: file.1, format: .claude)
            guard let title, let exchange else { continue }
            if (out[title]?.0 ?? .distantPast) < file.1 { out[title] = (file.1, exchange) }
        }
        return out.mapValues(\.1)
    }

    /// Codex rollout files keyed by thread id (the id ends each file name).
    static func codexRollouts() -> [String: URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        var out: [String: URL] = [:]
        for (url, _) in jsonlFiles(under: root, depth: 4) {
            let name = url.deletingPathExtension().lastPathComponent
            if name.count > 36 { out[String(name.suffix(36))] = url }
        }
        return out
    }

    static func lastExchange(in file: URL, format: Format) -> String? {
        let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return read(file, mtime: mtime, format: format).1
    }

    private static func read(_ file: URL, mtime: Date, format: Format) -> (String?, String?) {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[file.path], hit.0 == mtime { return (hit.1, hit.2) }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return (nil, nil) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)

        var title: String?, lastUser: String?, lastAssistant: String?
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch format {
            case .claude:
                if let t = obj["customTitle"] as? String { title = t }
                guard let role = obj["type"] as? String, role == "user" || role == "assistant",
                      let msg = obj["message"] as? [String: Any], let s = typedText(msg["content"]) else { continue }
                if role == "user" { lastUser = s } else { lastAssistant = s }
            case .codex:
                guard let p = obj["payload"] as? [String: Any], p["type"] as? String == "message",
                      let role = p["role"] as? String, let s = typedText(p["content"]) else { continue }
                if role == "user" { lastUser = s } else if role == "assistant" { lastAssistant = s }
            }
        }
        let parts = [lastUser.map { "User: " + $0.prefix(300) }, lastAssistant.map { "Assistant: " + $0.prefix(450) }].compactMap { $0 }
        let exchange = parts.isEmpty ? nil : parts.joined(separator: "\n")
        cache[file.path] = (mtime, title, exchange)
        return (title, exchange)
    }

    /// Text a person or the assistant wrote, skipping injected context, tool output and system blocks.
    private static func typedText(_ content: Any?) -> String? {
        var parts: [String] = []
        if let s = content as? String { parts = [s] }
        if let arr = content as? [[String: Any]] {
            parts = arr.compactMap { block in
                let type = block["type"] as? String ?? ""
                guard type == "text" || type == "input_text" || type == "output_text" else { return nil }
                return block["text"] as? String
            }
        }
        let typed = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("<") && !$0.hasPrefix("Caveat:") && !$0.hasPrefix("# AGENTS.md") }
        let s = typed.joined(separator: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.isEmpty ? nil : s
    }

    private static func jsonlFiles(under root: URL, depth: Int) -> [(URL, Date)] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [(URL, Date)] = []
        for case let url as URL in e {
            if e.level > depth { e.skipDescendants(); continue }
            guard url.pathExtension == "jsonl" else { continue }
            out.append((url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast))
        }
        return out
    }
}
