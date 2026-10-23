import Cocoa
import ApplicationServices

/// One chat the launcher can jump to.
final class ChatItem {
    enum Source: String {
        case claude = "Claude", chatgpt = "ChatGPT", codex = "Codex", chrome = "Chrome"
    }

    let source: Source
    let title: String
    let detail: String
    /// Last user and assistant message, when a local transcript exists.
    var lastExchange: String?
    /// The local transcript behind this chat, indexed for full-content search.
    var transcript: (url: URL, format: Transcripts.Format)?
    /// When the last message in the chat was sent, when a source knows it.
    var recency: Date?
    let open: () -> Void

    init(source: Source, title: String, detail: String, recency: Date? = nil, open: @escaping () -> Void) {
        self.source = source
        self.title = title
        self.detail = detail
        self.recency = recency
        self.open = open
    }
}

// MARK: - Accessibility helpers

enum AX {
    static func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ e: AXUIElement, _ name: String) -> String? {
        guard let s = attr(e, name) as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func children(_ e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func role(_ e: AXUIElement) -> String { string(e, kAXRoleAttribute) ?? "" }

    static func url(_ e: AXUIElement) -> URL? {
        if let u = attr(e, kAXURLAttribute) as? URL { return u }
        if let s = attr(e, kAXURLAttribute) as? String { return URL(string: s) }
        return nil
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        guard let posRef = attr(e, kAXPositionAttribute), let sizeRef = attr(e, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    /// All visible text under an element, in reading order.
    static func text(_ e: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        var out: [String] = []
        for key in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            if let s = string(e, key) { out.append(s); break }
        }
        for c in children(e) { out += text(c, depth: depth + 1) }
        return out
    }

    static func walk(_ root: AXUIElement, limit: Int = 30000, visit: (AXUIElement, String) -> Bool) {
        var stack = [root]
        var seen = 0
        while let e = stack.popLast(), seen < limit {
            seen += 1
            // visit returns false to skip descending into this element
            if visit(e, role(e)) { stack.append(contentsOf: children(e).reversed()) }
        }
    }

    static func app(bundleID: String) -> (NSRunningApplication, AXUIElement)? {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let el = AXUIElementCreateApplication(running.processIdentifier)
        // Electron apps only build their accessibility tree when asked to.
        AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(el, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return (running, el)
    }

    static func windows(_ app: AXUIElement) -> [AXUIElement] {
        (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    static func press(_ e: AXUIElement, in app: NSRunningApplication) {
        app.activate()
        if AXUIElementPerformAction(e, kAXPressAction as CFString) != .success {
            // Some rows only respond to a click on their first child.
            for c in children(e) where AXUIElementPerformAction(c, kAXPressAction as CFString) == .success { return }
        }
    }
}

// MARK: - Claude desktop (sidebar links via Accessibility)

enum ClaudeDesktopCollector {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let chrome: Set<String> = ["hide sidebar", "back", "forward", "search", "new", "artifacts", "routines",
                                      "customize", "pinned", "send feedback", "chats", "projects", "recents",
                                      "new chat", "code", "cowork", "chat", "this computer"]
    static let statusSuffix = try! NSRegularExpression(
        pattern: #"\s+(Open|Merged|Closed|Draft|Running|Waiting|Failed)(\s+·\s+\d+ pull requests?)?$"#)

    static func collect() -> [ChatItem] {
        guard let (app, root) = AX.app(bundleID: bundleID) else { return [] }
        var items: [ChatItem] = []
        var seen = Set<String>()
        for window in AX.windows(root) {
            guard let wf = AX.frame(window) else { continue }
            let sidebarMaxX = wf.minX + 300
            var group: String?
            AX.walk(window) { e, role in
                // claude.ai chats are links to /chat/<id>.
                if role == "AXLink", let url = AX.url(e) {
                    let path = url.path
                    guard path.contains("/chat/") || path.contains("/project/") else { return false }
                    if let title = AX.text(e).first, seen.insert(url.absoluteString).inserted {
                        items.append(ChatItem(source: .claude, title: title, detail: path.contains("/project/") ? "Project" : "Chat") {
                            AX.press(e, in: app)
                        })
                    }
                    return false
                }
                // Code sessions are full-width sidebar buttons, grouped under folder headers.
                guard role == "AXButton", let label = AX.string(e, kAXTitleAttribute) ?? AX.string(e, kAXDescriptionAttribute),
                      let f = AX.frame(e), f.minX < sidebarMaxX else { return true }
                if label.hasPrefix("New session in ") { group = String(label.dropFirst("New session in ".count)); return false }
                let lower = label.lowercased()
                guard f.width >= 200, !chrome.contains(lower), !lower.hasPrefix("show "), !lower.hasPrefix("load more"),
                      !lower.contains(", rename") else { return false }
                let range = NSRange(label.startIndex..., in: label)
                let match = statusSuffix.firstMatch(in: label, range: range)
                let title = match.map { (label as NSString).substring(to: $0.range.location) } ?? label
                let status = match.map { (label as NSString).substring(with: $0.range).trimmingCharacters(in: .whitespaces) }
                guard seen.insert(title).inserted else { return false }
                let detail = ["Code session", group, status].compactMap { $0 }.joined(separator: " · ")
                items.append(ChatItem(source: .claude, title: title, detail: detail) { AX.press(e, in: app) })
                return false
            }
        }
        // Code sessions keep transcripts on disk under the same title the sidebar shows.
        let transcripts = Transcripts.claudeByTitle()
        for item in items {
            guard let t = transcripts[item.title] else { continue }
            item.lastExchange = t.exchange
            item.recency = t.lastAt
            item.transcript = (t.url, .claude)
        }
        return items
    }
}

// MARK: - ChatGPT desktop (sidebar rows via Accessibility)

enum ChatGPTDesktopCollector {
    // The current ChatGPT app ships as com.openai.codex; older builds were com.openai.chat.
    static let bundleIDs = ["com.openai.codex", "com.openai.chat"]
    static var bundleID: String {
        bundleIDs.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty } ?? bundleIDs[0]
    }
    static let chrome: Set<String> = ["new chat", "search chats", "search", "library", "gpts", "codex", "sora",
                                      "explore gpts", "projects", "new project", "chats", "today", "yesterday",
                                      "previous 7 days", "previous 30 days", "settings", "upgrade plan", "images",
                                      "apps", "deep research", "agent", "pulse", "atlas", "your dot", "pinned",
                                      "recents", "new voice chat", "voice chat"]

    static func collect() -> [ChatItem] {
        guard let (app, root) = AX.app(bundleID: bundleID) else { return [] }
        let windows = AX.windows(root)
        let links = conversationLinks(windows, app: app)
        return links.isEmpty ? sidebarRows(windows, app: app) : links
    }

    /// Web-based builds expose each conversation as a link to /c/<id> (or /g/…/c/<id> inside a GPT or project).
    private static func conversationLinks(_ windows: [AXUIElement], app: NSRunningApplication) -> [ChatItem] {
        var items: [ChatItem] = []
        var seen = Set<String>()
        for window in windows {
            AX.walk(window) { e, role in
                guard role == "AXLink", let url = AX.url(e) else { return true }
                guard url.path.contains("/c/"), seen.insert(url.path).inserted,
                      let title = AX.text(e).first, !chrome.contains(title.lowercased()) else { return false }
                let detail = url.path.hasPrefix("/g/") ? "Project / GPT chat" : "Chat"
                items.append(ChatItem(source: .chatgpt, title: title, detail: detail) { AX.press(e, in: app) })
                return false
            }
        }
        return items
    }

    /// Native builds: rows in the left sidebar.
    private static func sidebarRows(_ windows: [AXUIElement], app: NSRunningApplication) -> [ChatItem] {
        var items: [ChatItem] = []
        var seen = Set<String>()
        for window in windows {
            guard let wf = AX.frame(window) else { continue }
            let sidebarMaxX = wf.minX + min(420, wf.width * 0.45)
            AX.walk(window) { e, role in
                guard role == "AXRow" || role == "AXCell" || role == "AXButton" || role == "AXLink" else { return true }
                guard let f = AX.frame(e), f.minX < sidebarMaxX, f.height < 80, f.width > 80 else { return role != "AXButton" }
                let parts = AX.text(e)
                guard let title = parts.first, title.count > 2, !chrome.contains(title.lowercased()),
                      seen.insert(title).inserted else { return false }
                items.append(ChatItem(source: .chatgpt, title: title, detail: parts.dropFirst().first(where: { $0 != title }) ?? "Chat") {
                    AX.press(e, in: app)
                })
                return false
            }
        }
        return items
    }
}

// MARK: - Chrome tabs on claude.ai / chatgpt.com

enum ChromeCollector {
    static func collect() -> [ChatItem] {
        // Don't launch Chrome just to look at it.
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty else { return [] }
        let script = """
        set out to ""
        tell application "Google Chrome"
            repeat with w from 1 to count windows
                repeat with t from 1 to count tabs of window w
                    set u to URL of tab t of window w
                    if u contains "claude.ai/" or u contains "chatgpt.com/" then
                        set out to out & w & tab & t & tab & u & tab & (title of tab t of window w) & linefeed
                    end if
                end repeat
            end repeat
        end tell
        return out
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue else { return [] }
        return result.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 3).map(String.init)
            guard f.count == 4, let w = Int(f[0]), let t = Int(f[1]) else { return nil }
            let site = f[2].contains("chatgpt.com") ? "ChatGPT" : "Claude"
            let title = f[3].replacingOccurrences(of: " - Claude", with: "").replacingOccurrences(of: " | ChatGPT", with: "")
            return ChatItem(source: .chrome, title: title, detail: "\(site) tab in Chrome") {
                let focus = """
                tell application "Google Chrome"
                    set active tab index of window \(w) to \(t)
                    set index of window \(w) to 1
                    activate
                end tell
                """
                NSAppleScript(source: focus)?.executeAndReturnError(nil)
            }
        }
    }
}

// MARK: - Debug: dump an app's accessibility tree so the collectors can be tuned

enum AXDump {
    static func dump(bundleID: String) -> String {
        guard let (_, root) = AX.app(bundleID: bundleID) else { return "\(bundleID) is not running\n" }
        var out = ""
        func rec(_ e: AXUIElement, _ depth: Int) {
            guard depth < 45, out.count < 3_000_000 else { return }
            let label = [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute]
                .compactMap { AX.string(e, $0) }.first.map { String($0.prefix(80)) } ?? ""
            let url = AX.url(e).map { " <\($0.absoluteString.prefix(100))>" } ?? ""
            let f = AX.frame(e).map { " @\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? ""
            out += String(repeating: "  ", count: depth) + AX.role(e) + " \"\(label)\"" + url + f + "\n"
            for c in AX.children(e) { rec(c, depth + 1) }
        }
        for w in AX.windows(root) { rec(w, 0) }
        return out
    }
}
