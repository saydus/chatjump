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
                let item = ChatItem(source: .codex, title: String(v.name.prefix(140)), detail: "Thread", recency: v.updated) {
                    if let url = URL(string: "codex://threads/\(id)") { NSWorkspace.shared.open(url) }
                }
                if let file = rollouts[id] {
                    let tail = Transcripts.tail(of: file, format: .codex)
                    item.lastExchange = tail.exchange
                    // The index updates on renames too; the last message stamp is when the chat was really active.
                    item.recency = tail.lastAt ?? v.updated
                    item.transcript = (file, .codex)
                }
                return item
            }
    }
}

// MARK: - Last messages from local transcripts

/// Reads the tail of agent transcripts so Jev can match on what a chat is actually about,
/// not just its title. Results are cached per file and modification time.
enum Transcripts {
    enum Format { case claude, codex }

    /// path -> (mtime, what the file holds)
    private static var cache: [String: (Date, Tail)] = [:]

    /// What the end of a transcript says: its title, its last exchange, and when that last message was sent.
    struct Tail { var title: String?; var exchange: String?; var lastAt: Date? }
    private static let lock = NSLock()

    /// Claude Code transcripts keyed by session title, so Claude sidebar sessions can be matched to their contents.
    static func claudeByTitle(maxAgeDays: Double = 30) -> [String: (url: URL, exchange: String, lastAt: Date?)] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-maxAgeDays * 86400)
        var out: [String: (Date, URL, String, Date?)] = [:]
        for file in jsonlFiles(under: root, depth: 2) where file.1 > cutoff {
            let tail = read(file.0, mtime: file.1, format: .claude)
            guard let title = tail.title, let exchange = tail.exchange else { continue }
            if (out[title]?.0 ?? .distantPast) < file.1 { out[title] = (file.1, file.0, exchange, tail.lastAt) }
        }
        return out.mapValues { ($0.1, $0.2, $0.3) }
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

    static func tail(of file: URL, format: Format) -> Tail {
        let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return read(file, mtime: mtime, format: format)
    }

    private static func read(_ file: URL, mtime: Date, format: Format) -> Tail {
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[file.path], hit.0 == mtime { return hit.1 }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return Tail() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)

        var title: String?, lastUser: String?, lastAssistant: String?, lastAt: Date?
        // Both formats stamp every line; the stamp on the last message line is when the chat was last active.
        func stamp(_ obj: [String: Any]) { if let t = (obj["timestamp"] as? String).flatMap(isoDate) { lastAt = t } }
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch format {
            case .claude:
                if let t = obj["customTitle"] as? String { title = t }
                guard let role = obj["type"] as? String, role == "user" || role == "assistant",
                      let msg = obj["message"] as? [String: Any], let s = typedText(msg["content"]) else { continue }
                stamp(obj)
                if role == "user" { lastUser = s } else { lastAssistant = s }
            case .codex:
                guard let p = obj["payload"] as? [String: Any], p["type"] as? String == "message",
                      let role = p["role"] as? String, let s = typedText(p["content"]) else { continue }
                stamp(obj)
                if role == "user" { lastUser = s } else if role == "assistant" { lastAssistant = s }
            }
        }
        let parts = [lastUser.map { "User: " + $0.prefix(300) }, lastAssistant.map { "Assistant: " + $0.prefix(450) }].compactMap { $0 }
        let exchange = parts.isEmpty ? nil : parts.joined(separator: "\n")
        let tail = Tail(title: title, exchange: exchange, lastAt: lastAt)
        cache[file.path] = (mtime, tail)
        return tail
    }

    /// Every user and assistant message in a transcript, cut into ~400-character passages for full-content search.
    /// Only the bytes appended since the last call are parsed, so a growing session costs little to keep current.
    static func passages(in file: URL, format: Format) -> [Passage] {
        let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        lock.lock(); defer { lock.unlock() }
        var entry = fullCache[file.path] ?? FullEntry(mtime: .distantPast, offset: 0, passages: [])
        if entry.mtime == mtime { return entry.passages }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return entry.passages }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < entry.offset { entry = FullEntry(mtime: .distantPast, offset: 0, passages: []) }   // file was rewritten
        try? handle.seek(toOffset: entry.offset)
        let data = handle.readDataToEndOfFile()

        // Cheap byte checks pick out message lines so tool calls, tool output and metadata never reach the JSON parser.
        let needles: [[UInt8]] = format == .claude
            ? [#""type":"assistant""#, #""type":"text""#, #""type":"user""#, #""tool_use_id""#, #""isSidechain":true"#].map { Array($0.utf8) }
            : [#""type":"response_item""#, #""type":"message""#].map { Array($0.utf8) }
        var consumed = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var start = 0
            while start < buf.count, let nl = memchr(base + start, 0x0A, buf.count - start) {
                let end = base.distance(to: UnsafeRawPointer(nl))
                defer { start = end + 1; consumed = start }
                let line = UnsafeRawBufferPointer(rebasing: buf[start..<end])
                func has(_ i: Int) -> Bool { contains(line, needles[i]) }
                let wanted = format == .claude
                    ? !has(4) && ((has(0) && has(1)) || (has(2) && !has(3)))
                    : has(0) && has(1)
                guard wanted, let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                var role: String?, text: String?
                switch format {
                case .claude:
                    role = obj["type"] as? String
                    text = typedText((obj["message"] as? [String: Any])?["content"])
                case .codex:
                    guard let p = obj["payload"] as? [String: Any], p["type"] as? String == "message" else { continue }
                    role = p["role"] as? String
                    text = typedText(p["content"])
                }
                guard let role, role == "user" || role == "assistant", let text else { continue }
                entry.passages += Passage.cut(text, label: role == "user" ? "User: " : "Assistant: ")
            }
        }
        entry.offset += UInt64(consumed)
        entry.mtime = mtime
        fullCache[file.path] = entry
        return entry.passages
    }

    private struct FullEntry { var mtime: Date; var offset: UInt64; var passages: [Passage] }
    private static var fullCache: [String: FullEntry] = [:]

    private static func contains(_ hay: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        guard let base = hay.baseAddress, hay.count >= needle.count else { return false }
        return needle.withUnsafeBytes { memmem(base, hay.count, $0.baseAddress, needle.count) != nil }
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

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

/// Parses transcript timestamps, with or without fractional seconds.
func isoDate(_ s: String) -> Date? {
    isoFormatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

// MARK: - How long ago

enum Ago {
    /// Compact form for the result list: "now", "5m", "3h", "yesterday", "4d", "Oct 3".
    static func short(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 60 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if Calendar.current.isDateInToday(date) { return "\(Int(s / 3600))h ago" }
        if Calendar.current.isDateInYesterday(date) { return "yesterday" }
        if s < 7 * 86400 { return "\(Int(s / 86400))d ago" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(Calendar.current.isDate(date, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d yyyy")
        return f.string(from: date)
    }

    /// Full form for Jev: "3 hours ago (Thu Oct 23, 14:05)", so both "recent" and "on Monday" can be judged.
    static func long(_ date: Date, now: Date = Date()) -> String {
        "\(RelativeDateTimeFormatter().localizedString(for: date, relativeTo: now)) (\(stamp(date)))"
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d, HH:mm"
        return f.string(from: date)
    }
}
