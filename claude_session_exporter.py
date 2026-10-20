#!/usr/bin/env python3
"""
Claude Session Exporter
-----------------------
Reads Claude Code's JSONL transcripts and exports them into a structured
folder at ~/AI Sessions/Claude Sessions/{project}/{date}_{slug}/

Usage:
    claude_session_exporter.py --project phavum
    claude_session_exporter.py --project phavum --slug schema-migration
    claude_session_exporter.py --project phavum --all
    claude_session_exporter.py --project phavum --list
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path


# ── Config ────────────────────────────────────────────────────────────────────
# Both overridable via env vars; defaults match Claude Code's own locations.

CLAUDE_PROJECTS_DIR = Path(os.environ.get(
    "CLAUDE_PROJECTS_DIR", Path.home() / ".config" / "claude" / "projects"))
OUTPUT_BASE_DIR = Path(os.environ.get(
    "SESSION_SYNC_CLAUDE_OUTPUT_DIR", Path.home() / "AI Sessions" / "Claude Sessions"))

NOISE_TYPES = {
    "queue-operation", "system", "last-prompt", "mode",
    "permission-mode", "file-history-snapshot", "ai-title",
    "token-count", "debug",
}

INDEX_HEADER = (
    "# Claude Sessions — Index\n\n"
    "| Date | Project | Session ID | Folder | Title | Created | Updated |\n"
    "|------|---------|------------|--------|-------|---------|--------|\n"
)


# ── JSONL helpers ─────────────────────────────────────────────────────────────

def encode_project_path(project_path: str) -> str:
    return project_path.replace("/", "-").replace(" ", "-")


def find_project_dir(cwd: Path) -> Path | None:
    encoded   = encode_project_path(str(cwd))
    candidate = CLAUDE_PROJECTS_DIR / encoded
    if candidate.exists():
        return candidate
    if CLAUDE_PROJECTS_DIR.exists():
        for d in CLAUDE_PROJECTS_DIR.iterdir():
            if d.is_dir() and d.name == encoded:
                return d
    return None


def list_sessions(project_dir: Path) -> list[Path]:
    return sorted(project_dir.glob("*.jsonl"), key=lambda p: p.stat().st_mtime)


def parse_jsonl(path: Path) -> list[dict]:
    entries = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return entries


def session_timestamp(entries: list[dict], fallback_path: Path) -> datetime:
    for e in entries:
        ts = e.get("timestamp")
        if ts:
            try:
                return datetime.fromisoformat(str(ts).replace("Z", "+00:00"))
            except (ValueError, TypeError):
                pass
    return datetime.fromtimestamp(fallback_path.stat().st_mtime)


# ── Content extraction ────────────────────────────────────────────────────────

def extract_ai_title(entries: list[dict]) -> str | None:
    for e in entries:
        if e.get("type") == "ai-title" and e.get("aiTitle"):
            return e["aiTitle"]
    return None


def slugify(text: str, max_len: int = 45) -> str:
    text = text.lower().strip()
    text = re.sub(r"[^\w\s-]", "", text)
    text = re.sub(r"[\s_]+", "-", text)
    text = re.sub(r"-+", "-", text).strip("-")
    return text[:max_len].rstrip("-")


def content_to_text(content) -> str:
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                t = block.get("text", "").strip()
                if t:
                    parts.append(t)
        return "\n\n".join(parts)
    return ""


def tool_summary(content: list) -> list[str]:
    lines = []
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_use":
            continue
        name = block.get("name", "unknown")
        inp  = block.get("input", {})
        line = f"*🔧 `{name}`*"
        if isinstance(inp, dict):
            shown = 0
            for k, v in inp.items():
                val = str(v)
                if len(val) > 120:
                    val = val[:120] + "…"
                line += f"\n  - `{k}`: {val}"
                shown += 1
                if shown >= 3:
                    break
        lines.append(line)
    return lines


# ── Markdown renderer ─────────────────────────────────────────────────────────

def entries_to_markdown(
    entries: list[dict],
    session_id: str,
    project_name: str,
    ts: datetime,
    ai_title: str | None,
) -> str:
    title = ai_title or f"Session {session_id}"

    # YAML frontmatter — makes sessions queryable in Obsidian (Dataview etc.).
    # json.dumps gives safe YAML double-quoted scalars for arbitrary titles.
    lines = [
        "---",
        f"project: {project_name}",
        "tool: claude-code",
        f"date: {ts.strftime('%Y-%m-%d')}",
        f"session_id: {session_id}",
        f"title: {json.dumps(title)}",
        "---",
        "",
        f"# {title}",
        f"**Project:** {project_name}  ",
        f"**Date:** {ts.strftime('%Y-%m-%d %H:%M')}  ",
        f"**Session ID:** `{session_id}`",
        "",
        "---",
        "",
    ]

    msg_count = 0

    for entry in entries:
        etype = entry.get("type", "")
        if etype in NOISE_TYPES:
            continue
        if entry.get("isMeta"):
            continue
        if "attachment" in entry and "message" not in entry:
            continue

        msg = entry.get("message")
        if not msg:
            continue

        role    = msg.get("role", "")
        content = msg.get("content", "")

        if role == "user":
            text = content_to_text(content)
            if text:
                lines += ["## 👤 You", "", text, ""]
                msg_count += 1

        elif role == "assistant":
            if isinstance(content, str):
                text = content.strip()
                if text:
                    lines += ["## 🤖 Claude", "", text, ""]
                    msg_count += 1
            elif isinstance(content, list):
                text  = content_to_text(content)
                tools = tool_summary(content)
                if text or tools:
                    lines += ["## 🤖 Claude", ""]
                    if text:
                        lines += [text, ""]
                    for t in tools:
                        lines += [t, ""]
                    msg_count += 1

    lines += ["---", "", f"*{msg_count} exchange(s) · claude_session_exporter.py*"]
    return "\n".join(lines)


# ── Templates ─────────────────────────────────────────────────────────────────

def plan_template(project_name: str, date_str: str) -> str:
    return f"""# Plan — {project_name} · {date_str}

## Goal
<!-- What are you trying to accomplish this session? -->

## Scope
<!-- What's in and what's out? -->

## Starting context
<!-- Anything not already in _context.md that Claude needs to know? -->
"""

def summary_template(project_name: str, date_str: str) -> str:
    return f"""# Summary — {project_name} · {date_str}

## What we did
<!-- Brief description of what was accomplished -->

## Key decisions
<!-- Decisions worth carrying forward into _context.md -->

## Blockers / unresolved
<!-- What's left open or needs a follow-up session? -->

## Handoff prompt
<!-- Paste this at the start of the next session to resume immediately -->

>
"""

def context_template(project_name: str) -> str:
    return f"""# {project_name} — Project Context

_Last updated: {datetime.now().strftime('%Y-%m-%d')}_

## Stack
<!-- Key technologies, versions, architecture decisions -->

## Current state
<!-- Where things stand right now -->

## Active work
<!-- What's in progress -->

## Key decisions
<!-- Important decisions already made — keep this current -->
"""


# ── Index ─────────────────────────────────────────────────────────────────────

def now_str() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M")


def update_index(
    base_dir: Path,
    project_name: str,
    session_id: str,
    folder_name: str,
    date_str: str,
    title: str,
) -> None:
    index_path = base_dir / "_index.md"

    if not index_path.exists():
        index_path.write_text(INDEX_HEADER, encoding="utf-8")

    content = index_path.read_text(encoding="utf-8")
    now     = now_str()

    if session_id in content:
        # Session already indexed — update the Updated column and folder name only
        lines     = content.split("\n")
        new_lines = []
        for line in lines:
            if session_id in line:
                parts = line.split("|")
                # Row format: | date | project | session_id | folder | title | created | updated |
                # parts[0]='' parts[1]=date ... parts[7]=updated parts[8]=''
                if len(parts) >= 8:
                    parts[4] = f" `{folder_name}` "   # folder (may have changed via --slug)
                    parts[7] = f" {now} "              # updated
                line = "|".join(parts)
            new_lines.append(line)
        index_path.write_text("\n".join(new_lines), encoding="utf-8")
    else:
        # New session — append a row
        row = (
            f"| {date_str} | {project_name} | `{session_id}` "
            f"| `{folder_name}` | {title} | {now} | {now} |\n"
        )
        with open(index_path, "a", encoding="utf-8") as f:
            f.write(row)


# ── Folder deduplication ──────────────────────────────────────────────────────

def find_existing_session_folder(project_out_dir: Path, session_id: str) -> Path | None:
    """
    Scan exported session folders to find one already containing this session_id.
    Checks the Session ID line in conversation.md.
    """
    if not project_out_dir.exists():
        return None
    for folder in project_out_dir.iterdir():
        if not folder.is_dir():
            continue
        conv = folder / "conversation.md"
        if not conv.exists():
            continue
        # Only read the first ~300 bytes — session_id is always in the header
        try:
            head = conv.read_bytes()[:800].decode("utf-8", errors="ignore")
            if session_id in head:
                return folder
        except OSError:
            continue
    return None


# ── Scaffold ──────────────────────────────────────────────────────────────────

def scaffold_project(project_dir: Path, project_name: str) -> None:
    project_dir.mkdir(parents=True, exist_ok=True)
    context_path = project_dir / "_context.md"
    if not context_path.exists():
        context_path.write_text(context_template(project_name), encoding="utf-8")
        print(f"  📄  Created _context.md")


# ── Sync mode ─────────────────────────────────────────────────────────────────

def sync_archive(project_filter: str | None = None) -> None:
    """
    Refresh conversation.md for every already-exported session, archive-wide.
    No cwd needed: each folder's session ID (from the conversation.md header) is
    looked up across ALL of ~/.config/claude/projects/. Only conversation.md is
    rewritten; plan.md / summary.md / artifacts are never touched.
    """
    if not OUTPUT_BASE_DIR.exists():
        print(f"❌  Archive not found: {OUTPUT_BASE_DIR}")
        sys.exit(1)

    total = updated = missing = 0
    for proj_dir in sorted(OUTPUT_BASE_DIR.iterdir()):
        if not proj_dir.is_dir() or proj_dir.name.startswith(("_", ".")):
            continue
        if project_filter and proj_dir.name != project_filter:
            continue
        for sess_dir in sorted(proj_dir.iterdir()):
            conv = sess_dir / "conversation.md"
            if not sess_dir.is_dir() or not conv.exists():
                continue
            head = conv.read_bytes()[:800].decode("utf-8", errors="ignore")
            m = re.search(r"session_id: ([0-9a-f-]{36})", head) or \
                re.search(r"\*\*Session ID:\*\* `([0-9a-f-]{36})`", head)
            if not m:
                continue
            sid = m.group(1)
            total += 1

            candidates = list(CLAUDE_PROJECTS_DIR.glob(f"*/{sid}.jsonl"))
            if not candidates:
                print(f"⚠  source gone   {proj_dir.name}/{sess_dir.name}")
                missing += 1
                continue
            # Same session ID can exist under several project keys (copies);
            # the most recently written one is the live/current version.
            src = max(candidates, key=lambda p: p.stat().st_mtime)

            entries  = parse_jsonl(src)
            ts       = session_timestamp(entries, src)
            ai_title = extract_ai_title(entries)
            md  = entries_to_markdown(entries, sid, proj_dir.name, ts, ai_title)
            old = conv.read_text(encoding="utf-8")
            if md != old:
                conv.write_text(md, encoding="utf-8")
                update_index(OUTPUT_BASE_DIR, proj_dir.name, sid, sess_dir.name,
                             ts.strftime("%Y-%m-%d"), ai_title or sess_dir.name)
                print(f"↻  synced       {proj_dir.name}/{sess_dir.name}")
                updated += 1

    print(f"\nSYNC: {total} session(s) checked · {updated} refreshed · {missing} source(s) missing")


# ── Core export ───────────────────────────────────────────────────────────────

def export_session(
    jsonl_path: Path,
    project_name: str,
    project_out_dir: Path,
    slug: str | None = None,
) -> tuple[Path, str]:
    entries    = parse_jsonl(jsonl_path)
    session_id = jsonl_path.stem
    ts         = session_timestamp(entries, jsonl_path)
    ai_title   = extract_ai_title(entries)
    date_str   = ts.strftime("%Y-%m-%d")

    # ── Reuse existing folder if this session was already exported ──
    existing = find_existing_session_folder(project_out_dir, session_id)

    if existing:
        session_dir = existing
        is_update   = True
    else:
        # New export — build folder name
        if slug:
            base_name = f"{date_str}_{slug}"
        elif ai_title:
            base_name = f"{date_str}_{slugify(ai_title)}"
        else:
            base_name = f"{date_str}_{ts.strftime('%H-%M')}_{session_id[:6]}"

        folder_name = base_name
        session_dir = project_out_dir / folder_name

        # Collision guard: a DIFFERENT session (different real ID) already owns this
        # folder name — happens when two sessions get the same AI-generated title on
        # the same day. Without this check the second session silently overwrites the
        # first one's conversation.md every run, since it never finds "itself" there.
        if session_dir.exists():
            existing_conv = session_dir / "conversation.md"
            owner_id = None
            if existing_conv.exists():
                head = existing_conv.read_bytes()[:800].decode("utf-8", errors="ignore")
                m = re.search(r"session_id: ([0-9a-f-]{36})", head) or \
                    re.search(r"\*\*Session ID:\*\* `([0-9a-f-]{36})`", head)
                owner_id = m.group(1) if m else None
            if owner_id and owner_id != session_id:
                folder_name = f"{base_name}-{session_id[:6]}"
                session_dir = project_out_dir / folder_name

        is_update   = False

    artifacts_dir = session_dir / "artifacts"
    session_dir.mkdir(parents=True, exist_ok=True)
    artifacts_dir.mkdir(exist_ok=True)

    # conversation.md — always overwrite with latest transcript
    md = entries_to_markdown(entries, session_id, project_name, ts, ai_title)
    (session_dir / "conversation.md").write_text(md, encoding="utf-8")

    # plan.md + summary.md — only scaffold once, never overwrite
    plan_path = session_dir / "plan.md"
    if not plan_path.exists():
        plan_path.write_text(plan_template(project_name, date_str), encoding="utf-8")

    summary_path = session_dir / "summary.md"
    if not summary_path.exists():
        summary_path.write_text(summary_template(project_name, date_str), encoding="utf-8")

    title_for_index = ai_title or session_dir.name
    return session_dir, title_for_index, session_id, date_str, is_update


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Export Claude Code sessions into ~/AI Sessions/Claude Sessions/{project}/{session}/",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
examples:
  %(prog)s --project phavum
  %(prog)s --project phavum --slug schema-migration
  %(prog)s --project phavum --all
  %(prog)s --project phavum --list
        """,
    )
    parser.add_argument("--project", type=str,
                        help="Project name (folder name under ~/AI Sessions/Claude Sessions/). "
                             "Required except with --sync (where it's an optional filter).")
    parser.add_argument("--sync", action="store_true",
                        help="Refresh conversation.md for every already-exported session "
                             "across the whole archive (no cwd needed); plan/summary/artifacts untouched")
    parser.add_argument("--slug",    type=str,
                        help="Topic slug for the session folder (ignored on --all)")
    parser.add_argument("--all",     action="store_true",
                        help="Export all sessions, not just the latest")
    parser.add_argument("--list",    action="store_true",
                        help="List available sessions without exporting")
    parser.add_argument("--encoded", type=str,
                        help="Select a project by its encoded folder name under "
                             "~/.config/claude/projects/ instead of cwd — for ghost "
                             "projects whose source directory was deleted")
    args = parser.parse_args()

    if args.sync:
        sync_archive(project_filter=args.project)
        return

    if not args.project:
        print("❌  --project is required (except with --sync)")
        sys.exit(1)

    cwd = Path.cwd()
    if args.encoded:
        project_dir = CLAUDE_PROJECTS_DIR / args.encoded
        if not project_dir.exists():
            print(f"❌  No project dir named: {args.encoded}")
            print("    Available:")
            for d in sorted(CLAUDE_PROJECTS_DIR.iterdir()):
                if d.is_dir():
                    print(f"      {d.name}")
            sys.exit(1)
    else:
        project_dir = find_project_dir(cwd)

    if not project_dir:
        print(f"❌  No Claude project found for: {cwd}")
        print(f"    Expected: {CLAUDE_PROJECTS_DIR / encode_project_path(str(cwd))}")
        print("    Make sure you've run at least one Claude Code session here,")
        print("    or use --encoded <dirname> for a deleted source directory.")
        sys.exit(1)

    project_name    = args.project
    project_out_dir = OUTPUT_BASE_DIR / project_name
    sessions        = list_sessions(project_dir)

    if not sessions:
        print("No sessions found.")
        sys.exit(0)

    # ── List mode ──────────────────────────────────────────────────────────────
    if args.list:
        print(f"\nSessions for: {cwd.name}\n")
        print(f"  {'DATE':<12}  {'SESSION ID':<38}  TITLE")
        print(f"  {'-'*12}  {'-'*38}  {'-'*40}")
        for s in sessions:
            entries    = parse_jsonl(s)
            title      = extract_ai_title(entries) or "—"
            mtime      = datetime.fromtimestamp(s.stat().st_mtime).strftime("%Y-%m-%d")
            print(f"  {mtime:<12}  {s.stem:<38}  {title[:60]}")
        print(f"\n{len(sessions)} session(s) total.")
        return

    # ── Export mode ────────────────────────────────────────────────────────────
    scaffold_project(project_out_dir, project_name)

    to_export = sessions if args.all else [sessions[-1]]
    slug      = None if args.all else args.slug

    if args.slug and args.all:
        print("⚠️   --slug ignored with --all")

    for s in to_export:
        session_dir, title, session_id, date_str, is_update = export_session(
            s, project_name, project_out_dir, slug=slug
        )
        update_index(OUTPUT_BASE_DIR, project_name, session_id, session_dir.name, date_str, title)
        tag = "↻  updated" if is_update else "✅  created"
        print(f"{tag}  {session_dir.name}  —  {title[:50]}")

    print(f"\n→  {project_out_dir}")


if __name__ == "__main__":
    main()