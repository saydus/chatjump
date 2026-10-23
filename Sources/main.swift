import Cocoa
import Carbon
import ServiceManagement

// MARK: - Global hotkey (Carbon; needs no extra permission)

final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handler: (() -> Void)?

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        HotKey.handler = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x434A4D50), id: 1) // "CJMP"
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - Panel

final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Called for ⌘C when the search box has no text selected; returns true if it copied something.
    var copyWithoutSelection: (() -> Bool)?

    /// A menu-bar app has no Edit menu, so nothing routes ⌘X/C/V/A/Z to the search box. Route them here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = mods.contains(.shift)
        let action: Selector? = switch (key, shift) {
        case ("x", false): #selector(NSText.cut(_:))
        case ("c", false): #selector(NSText.copy(_:))
        case ("v", false): #selector(NSText.paste(_:))
        case ("a", false): #selector(NSText.selectAll(_:))
        case ("z", false): Selector(("undo:"))
        case ("z", true): Selector(("redo:"))
        default: nil
        }
        guard let action else { return super.performKeyEquivalent(with: event) }
        if key == "c", let editor = firstResponder as? NSTextView, editor.selectedRange().length == 0,
           copyWithoutSelection?() == true { return true }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

final class ResultCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        badge.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        badge.textColor = .tertiaryLabelColor
        badge.alignment = .right
        for v in [icon, title, subtitle, badge] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 26), icon.heightAnchor.constraint(equalToConstant: 26),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 11),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -8),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 64),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class Launcher: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let panel: LauncherPanel
    let field = NSTextField()
    let status = NSTextField(labelWithString: "")
    let table = NSTableView()
    let scroll = NSScrollView()

    let width: CGFloat = 700, fieldHeight: CGFloat = 58, rowHeight: CGFloat = 46, maxRows = 9

    var allItems: [ChatItem] = []
    var shown: [(item: ChatItem, badge: String)] = []
    var jevCache: [String: JevResult] = [:]
    /// Full-content index over the transcripts behind `allItems`, rebuilt in the background after each reload.
    var passageIndex: PassageIndex?
    var jevTask: URLSessionTask?
    var debounce: DispatchWorkItem?
    var iconCache: [ChatItem.Source: NSImage] = [:]
    let collectQueue = DispatchQueue(label: "chatjump.collect")

    override init() {
        panel = LauncherPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 58),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.copyWithoutSelection = { [weak self] in self?.copySelectedChat() ?? false }

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 22, weight: .light)
        field.placeholderString = "Find a chat in Claude, ChatGPT or Codex…"
        field.delegate = self
        field.cell?.usesSingleLineMode = true

        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .tertiaryLabelColor
        status.alignment = .right

        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        table.action = #selector(openClicked)
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay

        let divider = NSBox(); divider.boxType = .separator
        for v in [field, status, divider, scroll] { v.translatesAutoresizingMaskIntoConstraints = false; bg.addSubview(v) }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: bg.topAnchor, constant: fieldHeight / 2),
            status.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
            status.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 120),
            divider.topAnchor.constraint(equalTo: bg.topAnchor, constant: fieldHeight),
            divider.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -6),
        ])
    }

    // MARK: show / hide

    func toggle() { panel.isVisible ? hide() : show() }

    func show() {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        panel.setFrameTopLeftPoint(NSPoint(x: vf.midX - width / 2, y: vf.maxY - vf.height * 0.2))
        field.stringValue = ""
        refreshResults()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        reload()
    }

    func hide() {
        jevTask?.cancel()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    /// Re-read every source in the background; the previous list stays on screen meanwhile.
    func reload() {
        status.stringValue = "refreshing…"
        collectQueue.async {
            let items = ClaudeDesktopCollector.collect() + ChatGPTDesktopCollector.collect() + ChromeCollector.collect()
                + CodexCollector.collect()
            DispatchQueue.main.async {
                self.allItems = items
                self.jevCache = [:]
                self.refreshResults()
                self.reindex(items)
            }
        }
    }

    /// Indexes every message of the transcripts behind `items`; only new or changed files are read.
    func reindex(_ items: [ChatItem]) {
        let transcripts = items.compactMap(\.transcript)
        let previous = passageIndex
        collectQueue.async {
            let signature = PassageIndex.signature(transcripts)
            guard previous?.signature != signature else { return }
            let index = PassageIndex(transcripts: transcripts, signature: signature)
            DispatchQueue.main.async {
                guard self.allItems.first === items.first else { return }   // a newer reload has landed
                self.passageIndex = index
                self.jevCache = [:]
                if !self.field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { self.refreshResults() }
            }
        }
    }

    // MARK: ranking

    func controlTextDidChange(_ obj: Notification) { refreshResults() }

    func refreshResults() {
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        jevTask?.cancel()
        debounce?.cancel()

        if q.isEmpty {
            // Sidebar order for Claude and ChatGPT, then Codex threads by recency.
            shown = allItems.map { ($0, "") }
            status.stringValue = allItems.isEmpty ? (AXIsProcessTrusted() ? "" : "needs Accessibility") : "\(allItems.count) chats"
            render(); return
        }

        // Title keywords plus how much of the query the chat's best transcript passage covers.
        let hits = passageIndex?.hits(for: allItems, query: q) ?? allItems.map { _ in nil }
        let scored: [(ChatItem, Double, PassageIndex.Hit?)] = zip(allItems, hits).map { item, hit in
            (item, LocalRanker.score(item, query: q) + PassageIndex.localWeight * (hit?.coverage ?? 0), hit)
        }
        .sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return (a.0.recency ?? .distantFuture) > (b.0.recency ?? .distantFuture)
        }

        if let cached = jevCache[q] { applyJev(cached, candidates: scored.map(\.0)); return }

        shown = scored.filter { $0.1 > 0 }.map { ($0.0, "") }
        render()

        guard JevRanker.apiKey != nil else { status.stringValue = "no Jev key: keywords"; return }
        status.stringValue = "Jev…"
        let candidates = scored.map(\.0)
        let keywordScores = scored.map { LocalRanker.score($0.0, query: q) }
        let passages = PassageIndex.forRequest(Array(scored.prefix(255).map(\.2)))
        let work = DispatchWorkItem { [weak self] in
            self?.jevTask = JevRanker.rank(query: q, candidates: candidates, keywordScores: keywordScores,
                                           passages: passages) { result in
                DispatchQueue.main.async {
                    guard let self, let result else { self?.status.stringValue = "Jev unavailable"; return }
                    self.jevCache[q] = result
                    if self.field.stringValue.trimmingCharacters(in: .whitespaces) == q {
                        self.applyJev(result, candidates: candidates)
                    }
                }
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    func applyJev(_ r: JevResult, candidates: [ChatItem]) {
        let pool = Array(candidates.prefix(255))
        let ranked = pool.indices.map { ($0, r.probabilities[$0] ?? 0) }.sorted { $0.1 > $1.1 }
        // Keep anything Jev gives real weight to; drop the long tail of near-zero options.
        shown = ranked.filter { $0.1 >= 0.01 }.prefix(25).map { (pool[$0.0], "\(Int(($0.1 * 100).rounded()))%") }
        status.stringValue = r.matchExists < 0.35 ? "✦ Jev · weak match" : "✦ Jev"
        render()
    }

    func render() {
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false); table.scrollRowToVisible(0) }
        let rows = min(shown.count, maxRows)
        let h = fieldHeight + (rows > 0 ? CGFloat(rows) * rowHeight + 8 : 0)
        var f = panel.frame
        f.origin.y += f.height - h
        f.size.height = h
        panel.setFrame(f, display: true)
    }

    // MARK: keys & actions

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): openSelected(); return true
        case #selector(NSResponder.cancelOperation(_:)): hide(); return true
        default: return false
        }
    }

    func move(_ d: Int) {
        guard !shown.isEmpty else { return }
        let r = max(0, min(shown.count - 1, table.selectedRow + d))
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    @objc func openClicked() { if table.clickedRow >= 0 { openSelected() } }

    @objc func openSelected() {
        let r = table.selectedRow
        guard r >= 0, r < shown.count else { return }
        let item = shown[r].item
        hide()
        DispatchQueue.main.async { item.open() }
    }

    /// ⌘C with nothing selected in the search box copies the highlighted chat's title.
    func copySelectedChat() -> Bool {
        let r = table.selectedRow
        guard r >= 0, r < shown.count else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shown[r].item.title, forType: .string)
        status.stringValue = "copied title"
        return true
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: .init("cell"), owner: nil) as? ResultCell
            ?? { let c = ResultCell(); c.identifier = .init("cell"); return c }()
        let (item, badge) = shown[row]
        cell.icon.image = icon(for: item.source)
        cell.title.stringValue = item.title
        // Time since the last message, worked out at draw time so it stays current while the panel is open.
        let when = item.recency.map { "last message \(Ago.short($0))" }
        cell.subtitle.stringValue = [item.source.rawValue, when, item.detail].compactMap { $0 }.joined(separator: " · ")
        cell.badge.stringValue = badge
        return cell
    }

    func icon(for source: ChatItem.Source) -> NSImage? {
        if let i = iconCache[source] { return i }
        let bundle: String = switch source {
        case .claude: ClaudeDesktopCollector.bundleID
        case .chatgpt, .codex: ChatGPTDesktopCollector.bundleID
        case .chrome: "com.google.Chrome"
        }
        let img = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { NSWorkspace.shared.icon(forFile: $0.path) }
        iconCache[source] = img
        return img
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var launcher: Launcher!
    var hotKey: HotKey!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        if CommandLine.arguments.contains("--dump") { dumpAndQuit(); return }

        launcher = Launcher()
        // ⌃⌥Space
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.launcher.toggle()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "ChatJump")
        let menu = NSMenu()
        menu.addItem(withTitle: "Find a chat   ⌃⌥Space", action: #selector(showLauncher), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Set Jev API key…", action: #selector(setKey), keyEquivalent: "")
        let ax = menu.addItem(withTitle: AXIsProcessTrusted() ? "Accessibility: on" : "Accessibility: OFF — sidebars hidden", action: nil, keyEquivalent: "")
        ax.isEnabled = false
        menu.addItem(withTitle: "Grant Accessibility access…", action: #selector(askAccessibility), keyEquivalent: "")
        let login = menu.addItem(withTitle: "Open at login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ChatJump", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu

        if !AXIsProcessTrusted() { askAccessibility() }
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        launcher.reload()
    }

    @objc func showLauncher() { launcher.show() }

    @objc func askAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
        sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func setKey() {
        let alert = NSAlert()
        alert.messageText = "TypeSafe API key"
        alert.informativeText = "Jev uses this key to rank chats by meaning. It's stored in ~/.config/chatjump/typesafe_key (readable only by you)."
        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = JevRanker.apiKey == nil ? "paste key" : "key saved — paste to replace"
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = input
        if alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty {
            JevRanker.saveKey(input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// `open ChatJump.app --args --dump` writes the sidebar trees and parsed items for tuning, then quits.
    func dumpAndQuit() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ChatJump")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var summary = "trusted=\(AXIsProcessTrusted())\n"
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            for (name, id) in [("claude", ClaudeDesktopCollector.bundleID), ("chatgpt", ChatGPTDesktopCollector.bundleID)] {
                try? AXDump.dump(bundleID: id).write(to: dir.appendingPathComponent("ax-\(name).txt"), atomically: true, encoding: .utf8)
            }
            let sources: [(String, () -> [ChatItem])] = [("Claude", ClaudeDesktopCollector.collect), ("ChatGPT", ChatGPTDesktopCollector.collect),
                                                         ("Chrome", ChromeCollector.collect), ("Codex", { CodexCollector.collect() })]
            for (name, collect) in sources {
                let items = collect()
                summary += "\n== \(name): \(items.count)\n" + items.prefix(40).map { "  \($0.title)  |  \($0.detail)  ||  \(($0.lastExchange ?? "-").prefix(120))" }.joined(separator: "\n") + "\n"
            }
            try? summary.write(to: dir.appendingPathComponent("items.txt"), atomically: true, encoding: .utf8)
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
