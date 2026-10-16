import Foundation

// MARK: - Instant local match (runs on every keystroke)

enum LocalRanker {
    static func score(_ item: ChatItem, query: String) -> Double {
        let tokens = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return 0 }
        let hay = (item.title + " " + item.detail + " " + item.source.rawValue).lowercased()
        let words = hay.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var s = 0.0
        for t in tokens {
            if words.contains(t) { s += 3 }
            else if words.contains(where: { $0.hasPrefix(t) }) { s += 2 }
            else if hay.contains(t) { s += 1.2 }
            else if isSubsequence(t, of: hay) { s += 0.4 }
        }
        return s / Double(tokens.count)
    }

    private static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        return needle.allSatisfy { c in while let h = it.next() { if h == c { return true } }; return false }
    }
}

// MARK: - Jev semantic rerank (runs once typing pauses)

struct JevResult {
    let probabilities: [Int: Double]   // index into the candidate list -> probability
    let matchExists: Double
}

enum JevRanker {
    static let keyFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/chatjump/typesafe_key")

    static var apiKey: String? {
        if let env = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !env.isEmpty { return env }
        return (try? String(contentsOf: keyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    static func saveKey(_ key: String) {
        try? FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? key.write(to: keyFile, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    }

    /// Ranks up to 255 candidates (the Choice option limit) against the query in one request.
    /// Each chat carries its title, its last exchange when a transcript exists, and the local keyword score as a hint.
    static func rank(query: String, candidates: [ChatItem], keywordScores: [Double],
                     completion: @escaping (JevResult?) -> Void) -> URLSessionTask? {
        guard let key = apiKey, !candidates.isEmpty else { completion(nil); return nil }
        let pool = Array(candidates.prefix(255))
        func id(_ i: Int) -> String { "c\(i)" }

        let chats: [[String: Any]] = pool.enumerated().map { i, c in
            var chat: [String: Any] = ["id": id(i), "app": c.source.rawValue, "title": c.title, "detail": c.detail,
                                       "keyword_overlap": keywordOverlap(i < keywordScores.count ? keywordScores[i] : 0)]
            if let last = c.lastExchange { chat["last_exchange"] = last }
            return chat
        }
        let state: [String: Any] = ["chats": chats]
        let typed: [String: Any] = ["query": query]
        let questions: [String: Any] = [
            "best": [
                "type": "choice",
                "instructions": typed.merging([
                    "question": "The user typed `query` into a quick launcher to jump back to one of their open AI chats in Claude, ChatGPT or Codex, listed in `chats`. The query may be loose keywords, fragments, a topic, a name, or misspelled. Judge each chat by what it is about: its `title`, and its `last_exchange` (the latest user and assistant messages) when present. `keyword_overlap` says how many query words literally appear in the title; treat it as a hint, not the answer. Which chat id is the conversation they most likely want?"
                ]) { $1 },
                "criteria": Dictionary(uniqueKeysWithValues: pool.indices.map { (id($0), NSNull()) }),
            ],
            "exists": [
                "type": "noul",
                "instructions": typed.merging([
                    "question": "Is any chat in `chats` plausibly the conversation the user means by `query`?"
                ]) { $1 },
                "criteria": [
                    "true": "At least one chat's title or last exchange is about what the query describes",
                    "false": "No chat is about what the query describes",
                ],
            ],
        ]
        let body: [String: Any] = ["model": "jev-latest", "state": state, "questions": questions]

        var req = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            guard error == nil, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = json["answers"] as? [String: Any],
                  let best = answers["best"] as? [String: Any],
                  let probs = best["probabilities"] as? [String: Double] else {
                if let data, let text = String(data: data, encoding: .utf8) { NSLog("ChatJump Jev error: \(text.prefix(300))") }
                completion(nil); return
            }
            var byIndex: [Int: Double] = [:]
            for (k, v) in probs { if let i = Int(k.dropFirst()) { byIndex[i] = v } }
            let exists = (answers["exists"] as? [String: Any])?["noul"] as? Double ?? 1
            completion(JevResult(probabilities: byIndex, matchExists: exists))
        }
        task.resume()
        return task
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension JevRanker {
    /// Coarse label for the local score so Jev sees a hint rather than a raw number.
    static func keywordOverlap(_ score: Double) -> String {
        switch score {
        case 2.5...: "all words match"
        case 1...: "some words match"
        case 0.01...: "loose letter match"
        default: "none"
        }
    }
}
