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

// MARK: - Full-content passage search over local transcripts

/// A ~400-character slice of one transcript message, with its words pre-counted for BM25.
struct Passage {
    let text: String
    let terms: [String: UInt16]
    let length: Int

    static let size = 400, step = 300

    /// Cuts one message into overlapping windows so a match near a boundary still lands in one passage.
    static func cut(_ message: String, label: String) -> [Passage] {
        let words = message.split(separator: " ")
        var out: [Passage] = []
        var i = 0
        while i < words.count {
            var j = i, chars = 0, next = words.count
            while j < words.count, chars + words[j].utf8.count <= size || j == i {
                chars += words[j].utf8.count + 1
                if chars > step, next == words.count { next = j + 1 }
                j += 1
            }
            let body = words[i..<j].joined(separator: " ")
            let tokens = PassageIndex.tokens(body)
            var terms: [String: UInt16] = [:]
            for t in tokens { terms[t, default: 0] &+= 1 }
            out.append(Passage(text: label + body.prefix(size + 80), terms: terms, length: tokens.count))
            if j >= words.count { break }
            i = max(i + 1, min(next, j))
        }
        return out
    }
}

/// BM25 over every passage of every transcript-backed chat, as an inverted index so a query only touches
/// passages that contain one of its words.
final class PassageIndex {
    struct Hit { let passage: String; let score: Double; let coverage: Double }

    private var texts: [String] = []
    private var owner: [Int32] = []                       // passage -> transcript slot
    private var lengths: [Float] = []
    private var postings: [String: [(Int32, UInt16)]] = [:]
    private var slots: [String: Int32] = [:]              // transcript path -> slot
    private var avgLength: Float = 1
    let signature: [String]

    static let k1: Float = 1.2, b: Float = 0.75

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap { $0.count >= 2 ? String($0) : nil }
    }

    /// Builds the index for these transcripts. Reads only what changed since the last build (see `Transcripts.passages`).
    init(transcripts: [(url: URL, format: Transcripts.Format)], signature: [String]) {
        self.signature = signature
        var seen = Set<String>()
        for t in transcripts where seen.insert(t.url.path).inserted {
            let slot = Int32(slots.count)
            slots[t.url.path] = slot
            for p in Transcripts.passages(in: t.url, format: t.format) {
                let id = Int32(texts.count)
                texts.append(p.text); owner.append(slot); lengths.append(Float(p.length))
                for (term, tf) in p.terms { postings[term, default: []].append((id, tf)) }
            }
        }
        avgLength = max(1, lengths.reduce(0, +) / Float(max(1, lengths.count)))
    }

    /// Identifies a set of transcripts by path and modification time, so an unchanged set reuses its index.
    static func signature(_ transcripts: [(url: URL, format: Transcripts.Format)]) -> [String] {
        transcripts.map { t in
            let m = (try? t.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return "\(t.url.path)@\(m.timeIntervalSince1970)"
        }.sorted()
    }

    /// The best passage per transcript path, scored with BM25. `coverage` is the share of query words it contains.
    /// The last query word also matches as a prefix, since it may still be half-typed.
    func search(_ query: String) -> [String: Hit] {
        let words = Array(Set(Self.tokens(query)))
        guard !words.isEmpty, !texts.isEmpty else { return [:] }
        let last = Self.tokens(query).last
        var scores = [Float](repeating: 0, count: texts.count)
        var matched = [UInt32](repeating: 0, count: texts.count)
        var touched: [Int32] = []
        let n = Float(texts.count)
        for (w, word) in words.prefix(32).enumerated() {
            var lists: [[(Int32, UInt16)]] = postings[word].map { [$0] } ?? []
            if lists.isEmpty, word == last, word.count >= 3 {
                lists = postings.lazy.filter { $0.key.hasPrefix(word) }.prefix(20).map(\.value)
            }
            for list in lists {
                let idf = log(1 + (n - Float(list.count) + 0.5) / (Float(list.count) + 0.5))
                for (id, tf) in list {
                    let i = Int(id), f = Float(tf)
                    if scores[i] == 0 { touched.append(id) }
                    scores[i] += idf * f * (Self.k1 + 1) / (f + Self.k1 * (1 - Self.b + Self.b * lengths[i] / avgLength))
                    matched[i] |= 1 << UInt32(w)
                }
            }
        }
        var best: [Int32: Int32] = [:]   // slot -> passage
        for id in touched {
            let slot = owner[Int(id)]
            if let cur = best[slot], scores[Int(cur)] >= scores[Int(id)] { continue }
            best[slot] = id
        }
        let pathOf = Dictionary(uniqueKeysWithValues: slots.map { ($1, $0) })
        var out: [String: Hit] = [:]
        for (slot, id) in best {
            let i = Int(id)
            out[pathOf[slot]!] = Hit(passage: texts[i], score: Double(scores[i]),
                                     coverage: Double(matched[i].nonzeroBitCount) / Double(min(words.count, 32)))
        }
        return out
    }
}

extension PassageIndex {
    /// Chats whose best passage goes into the Jev request; the rest send only title and last exchange.
    static let maxSent = 40
    /// Weight of passage coverage in the instant local score (a full title match scores 3).
    static let localWeight = 1.5

    /// The best passage for each item that has a transcript, in item order.
    func hits(for items: [ChatItem], query: String) -> [Hit?] {
        let byPath = search(query)
        return items.map { $0.transcript.flatMap { byPath[$0.url.path] } }
    }

    /// Passages to send, keeping only the `maxSent` highest-scoring ones so the request stays small.
    static func forRequest(_ hits: [Hit?]) -> [String?] {
        let keep = Set(hits.indices.filter { hits[$0] != nil }
            .sorted { hits[$0]!.score > hits[$1]!.score }.prefix(maxSent))
        return hits.indices.map { keep.contains($0) ? hits[$0]?.passage : nil }
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
    /// Each chat carries its title, its last exchange and best-matching passage when a transcript exists,
    /// when its last message was sent (so queries like "yesterday" work),
    /// and the local keyword score as a hint.
    static func rank(query: String, candidates: [ChatItem], keywordScores: [Double], passages: [String?],
                     completion: @escaping (JevResult?) -> Void) -> URLSessionTask? {
        guard let key = apiKey, !candidates.isEmpty else { completion(nil); return nil }
        let pool = Array(candidates.prefix(255))
        func id(_ i: Int) -> String { "c\(i)" }

        let chats: [[String: Any]] = pool.enumerated().map { i, c in
            var chat: [String: Any] = ["id": id(i), "app": c.source.rawValue, "title": c.title, "detail": c.detail,
                                       "keyword_overlap": keywordOverlap(i < keywordScores.count ? keywordScores[i] : 0)]
            if let last = c.lastExchange { chat["last_exchange"] = last }
            if i < passages.count, let passage = passages[i] { chat["best_passage"] = passage }
            if let when = c.recency { chat["last_activity"] = Ago.long(when) }
            return chat
        }
        let state: [String: Any] = ["now": Ago.stamp(Date()), "chats": chats]
        let typed: [String: Any] = ["query": query]
        let questions: [String: Any] = [
            "best": [
                "type": "choice",
                "instructions": typed.merging([
                    "question": "The user typed `query` into a quick launcher to jump back to one of their open AI chats in Claude, ChatGPT or Codex, listed in `chats`. The query may be loose keywords, fragments, a topic, a name, or misspelled. Judge each chat by what it is about: its `title`, its `last_exchange` (the latest user and assistant messages) when present, and its `best_passage` when present: the passage from anywhere earlier in that conversation that best matches the query words, so a chat can be the right one because of something said mid-conversation even when its title and last exchange are about something else. `keyword_overlap` says how many query words literally appear in the title; treat it as a hint, not the answer. `last_activity`, when present, says when the chat's last message was sent, relative to `now`: when the query refers to time (today, yesterday, last week, on Monday, latest, recent, old), prefer chats whose `last_activity` fits it; otherwise use it only to break near-ties in favor of more recent chats. Which chat id is the conversation they most likely want?"
                ]) { $1 },
                "criteria": Dictionary(uniqueKeysWithValues: pool.indices.map { (id($0), NSNull()) }),
            ],
            "exists": [
                "type": "noul",
                "instructions": typed.merging([
                    "question": "Is any chat in `chats` plausibly the conversation the user means by `query`?"
                ]) { $1 },
                "criteria": [
                    "true": "At least one chat's title, last exchange or best passage is about what the query describes",
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
