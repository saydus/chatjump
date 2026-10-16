# ChatJump

**Spotlight for your AI chats.** Press <kbd>⌃</kbd><kbd>⌥</kbd><kbd>Space</kbd>, type whatever you remember, and jump straight to the right conversation in Claude, ChatGPT, or Codex.

ChatJump is a small native macOS menu-bar app. It reads the chats open in your desktop apps, and [Jev](https://docs.typesafe.ai) ranks them by meaning, so `lisbon hotels` finds the thread titled *"Weekend trip ideas"* because that's what its last message was about.

```
┌──────────────────────────────────────────────────────────────┐
│  lisbon hotels                                       ✦ Jev   │
├──────────────────────────────────────────────────────────────┤
│  ◉  Weekend trip ideas                                  97%  │
│     Codex · 2 hours ago                                      │
│  ◉  Compare travel credit cards                          2%  │
│     ChatGPT · Chat                                           │
└──────────────────────────────────────────────────────────────┘
```

## What it searches

| Source | How it's read | What gets matched |
|---|---|---|
| **Claude** desktop app | Sidebar, through macOS Accessibility | Title, plus the last user and assistant message for Code sessions (from `~/.claude/projects`) |
| **ChatGPT** desktop app | Sidebar, through macOS Accessibility | Title |
| **Codex** | `~/.codex/session_index.jsonl` (last 30 days) | Title, plus the last user and assistant message |
| **Chrome** | Tabs on `claude.ai` and `chatgpt.com`, through AppleScript | Tab title |

Picking a result opens it: ChatJump clicks the sidebar row, opens `codex://threads/<id>`, or focuses the Chrome tab.

## How ranking works

1. **As you type**, a local keyword matcher shows results instantly.
2. **When you pause** (about 0.3 s), ChatJump sends one request to Jev with every open chat: its title, its last exchange when there is one, and a coarse keyword-overlap hint.
3. Jev answers two questions in that request:
   - a **Choice** over the chat ids, whose probabilities become the ranking (the percentages you see), and
   - a **Noul** asking whether *any* chat matches, which drives the "weak match" label when nothing does.

A search takes about 0.1 s. Results are cached per query until the chat list refreshes. Without an API key, ChatJump falls back to keyword matching.

## Install

Requires macOS 14 or later and the Xcode command-line tools (`xcode-select --install`).

```bash
git clone https://github.com/saydus/chatjump.git
```

```bash
cd chatjump && ./build.sh
```

`build.sh` compiles the app, signs it locally (ad-hoc), and installs it to `/Applications/ChatJump.app`. Then:

1. **Open ChatJump.** A speech-bubble icon appears in the menu bar. The app also registers itself to open at login; you can turn that off in its menu.
2. **Grant Accessibility.** Go to **System Settings → Privacy & Security → Accessibility**, drag in `/Applications/ChatJump.app`, and turn it on. This is what lets ChatJump read the Claude and ChatGPT sidebars.
3. **Allow Chrome control** when macOS asks. This is only needed for Chrome tabs.
4. **Add a TypeSafe API key.** Choose **Set Jev API key…** from the menu-bar icon, or put it in the environment as `TYPESAFE_API_KEY`. The key is stored in `~/.config/chatjump/typesafe_key` with `0600` permissions.

## Use

| Key | Action |
|---|---|
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>Space</kbd> | Open or close ChatJump from anywhere |
| <kbd>↑</kbd> <kbd>↓</kbd> | Move through results |
| <kbd>Return</kbd> | Open the selected chat |
| <kbd>Esc</kbd> | Close |

With an empty query you see every open chat, in sidebar order for Claude and ChatGPT and by recency for Codex.

## Privacy

Everything runs locally except the ranking call. When Jev is enabled, each search sends your query and, for every open chat, its **title, app name, and last user and assistant messages** (truncated to roughly 750 characters) to `api.typesafe.ai`. Nothing else leaves your Mac, and nothing is stored by ChatJump beyond the API key file.

If that's more than you want to share, leave the key unset and ChatJump uses local keyword matching only.

## Troubleshooting

**The Claude or ChatGPT sidebar shows no chats.** Accessibility is probably off. The menu-bar menu shows `Accessibility: on` or `OFF`.

**It stopped working after I rebuilt it.** macOS ties the Accessibility permission of an ad-hoc-signed app to that exact build. After every `./build.sh`, remove ChatJump from the Accessibility list with **–** and add it again. Signing with a real Developer ID certificate avoids this.

**A source finds nothing.** Run the diagnostic mode, which writes what each source found to `~/Library/Logs/ChatJump/items.txt` and the raw sidebar trees to `ax-claude.txt` and `ax-chatgpt.txt`:

```bash
open /Applications/ChatJump.app --args --dump
```

The sidebar layouts of the Claude and ChatGPT apps change between versions. If one stops parsing, those dumps show what changed. Please include them in an issue, after removing anything private.

## Limitations

- ChatGPT conversations and claude.ai chats are matched on **titles only**, because their messages aren't stored on your Mac.
- Only chats the sidebar has loaded are visible. Chats hidden behind "Show more" or far down a long list may be missed.
- Jev's Choice question takes up to 255 options, so only the top 255 chats by keyword score are ranked.

## Roadmap

- Full-content search over Claude Code and Codex transcripts: find the best-matching passage in each chat locally, then let Jev rank on that passage.
- A configurable hotkey.
- More sources (Safari, Arc, other agent apps).

## Project layout

```
Sources/
  main.swift            App, hotkey, menu bar, search panel
  Collectors.swift      Claude, ChatGPT and Chrome sources, plus Accessibility helpers
  MoreCollectors.swift  Codex source and local transcript reader
  Ranker.swift          Keyword matcher and the Jev request
build.sh                Build, sign and install
```

## License

[MIT](LICENSE)
