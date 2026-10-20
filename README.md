# AI Session Sync

A native macOS app that exports [Claude Code](https://claude.com/claude-code) and
[OpenCode](https://opencode.ai) session transcripts into a permanent, browsable Markdown archive.
Both tools prune their own raw session history after a while, and once that happens the original
transcript is gone for good.

## Install

**[Download the latest .dmg](https://github.com/RaviJari/ai-session-sync/releases/latest)**, open
it, and drag **Session Sync** into Applications. Runs on Apple Silicon and Intel, macOS 12+.

It isn't notarized (no Apple Developer account behind it), so the first launch shows an
"unidentified developer" warning. Right-click the app → **Open** → **Open**, once.

## Using it

On first launch it asks where your sessions live (detected automatically) and where exports should
go. You can change these later in **Settings (⌘,)**.

- **Sync** re-renders every session already in your archive from its live source, so later messages
  are picked up. It only rewrites `conversation.md`, never your `plan.md`, `summary.md` or artifacts.
- **Export All Sessions** archives every session of a project into a folder you name.

Archive layout:

```
~/AI Sessions/Claude Sessions/
  _index.md                      # table of every exported session
  my-project/
    _context.md
    2026-07-15_some-session-title/
      conversation.md            # YAML frontmatter + transcript, Obsidian-friendly
      plan.md
      summary.md
      artifacts/
```

## Build from source

```bash
./build.sh 1.1.0   # → build/Session Sync.app and build/SessionSync-1.1.0.dmg
```

Needs the Xcode command line tools. No dependencies. Everything lives in `Sources/`.

## Python CLI

`claude_session_exporter.py` and `opencode_session_exporter.py` are the original command-line
exporters the app was ported from. The app produces byte-identical output, so you can use either
one against the same archive.

```bash
python3 claude_session_exporter.py --project my-project --all
python3 claude_session_exporter.py --sync
```

| Variable | Default |
|---|---|
| `CLAUDE_PROJECTS_DIR` | `~/.config/claude/projects` |
| `SESSION_SYNC_CLAUDE_OUTPUT_DIR` | `~/AI Sessions/Claude Sessions` |
| `OPENCODE_DB` | `~/.local/share/opencode/opencode.db` |
| `SESSION_SYNC_OPENCODE_OUTPUT_DIR` | `~/AI Sessions/Opencode Sessions` |

## License

MIT
