# AI Session Sync

Exports [Claude Code](https://claude.com/claude-code) and [OpenCode](https://opencode.ai) session
transcripts into a browsable, permanent Markdown archive — because both tools prune their own raw
session history after a while, and once that happens the original transcript is gone for good.

## Install (macOS)

**[Download the latest .dmg](https://github.com/RaviJari/ai-session-sync/releases/latest)**, open
it, drag **Session Sync** into Applications.

This isn't notarized (no Apple Developer account behind it), so the first launch will show an
"unidentified developer" warning — right-click the app → **Open** → **Open**, once. After that it
opens normally.

The app is a thin native front end; the actual export logic is the Python scripts below, bundled
inside it. Everything in this repo also runs standalone from the command line if you'd rather skip
the app entirely.

## What's here

- **`claude_session_exporter.py`** — reads Claude Code's JSONL transcripts (`~/.config/claude/projects/`)
  and writes Markdown into `~/AI Sessions/Claude Sessions/{project}/{date}_{slug}/`.
- **`opencode_session_exporter.py`** — same idea for OpenCode, reading its SQLite session DB.
- **`sync_ui.py`** — a local web UI (stdlib only, no dependencies) wrapping both scripts: one-click
  "sync everything already archived" and "export this project's sessions."
- **`SessionSyncNative.swift`** — a real native macOS AppKit app (no WebView, no browser) that talks
  to `sync_ui.py`'s HTTP endpoints over JSON. Compile with `swiftc`.
- **`generate_icon.swift`** — generates the app icon natively via Core Graphics + SF Symbols.

## Why

Both tools' local session storage isn't meant as permanent history — Claude Code in particular can
prune old `.jsonl` transcripts under retention settings, silently, with no warning before the file
is gone. These scripts turn ephemeral local session state into a permanent, greppable, Obsidian-
friendly archive.

## Usage

```bash
# Export the current project's latest Claude Code session
python3 claude_session_exporter.py --project my-project

# Refresh every already-exported session's content from its live source
python3 claude_session_exporter.py --sync

# Same for OpenCode
python3 opencode_session_exporter.py --project my-project
python3 opencode_session_exporter.py --sync
```

### Configuration (env vars, all optional — sensible defaults match each tool's real location)

| Variable | Default | Purpose |
|---|---|---|
| `CLAUDE_PROJECTS_DIR` | `~/.config/claude/projects` | Where Claude Code stores session JSONL |
| `SESSION_SYNC_CLAUDE_OUTPUT_DIR` | `~/AI Sessions/Claude Sessions` | Where exported Markdown goes |
| `OPENCODE_DB` | `~/.local/share/opencode/opencode.db` | OpenCode's session database |
| `SESSION_SYNC_OPENCODE_OUTPUT_DIR` | `~/AI Sessions/Opencode Sessions` | Where exported Markdown goes |

### Web UI

```bash
python3 sync_ui.py   # open http://127.0.0.1:8765
```

### Native macOS app (optional)

```bash
swiftc -O SessionSyncNative.swift -o session-sync-native
./session-sync-native   # requires sync_ui.py running on 127.0.0.1:8765
```

## License

MIT
