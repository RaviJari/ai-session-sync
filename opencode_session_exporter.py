#!/usr/bin/env python3
"""
OpenCode Session Exporter
-------------------------
Reads OpenCode's SQLite database and exports sessions into a structured
folder at ~/AI Sessions/Opencode Sessions/{project}/{date}_{slug}/

Mirror of claude_session_exporter.py — same CLI, same folder layout,
same index/dedup behaviour; only the source format differs
(SQLite session/message/part tables instead of JSONL).

Usage:
    opencode_session_exporter.py --project phokus
    opencode_session_exporter.py --project phokus --slug schema-migration
    opencode_session_exporter.py --project phokus --all
    opencode_session_exporter.py --project phokus --list
"""

import argparse
import json
import os
import re
import sqlite3
import sys
from datetime import datetime
from pathlib import Path


# ── Config ────────────────────────────────────────────────────────────────────
# Both overridable via env vars; defaults match OpenCode's own locations.

OPENCODE_DB = Path(os.environ.get(
    "OPENCODE_DB", Path.home() / ".local" / "share" / "opencode" / "opencode.db"))
OUTPUT_BASE_DIR = Path(os.environ.get(
    "SESSION_SYNC_OPENCODE_OUTPUT_DIR", Path.home() / "AI Sessions" / "Opencode Sessions"))

# Part types that carry no conversational content
NOISE_PART_TYPES = {"step-start", "step-finish", "snapshot", "patch", "compaction", "file"}

INDEX_HEADER = (
    "# Opencode Sessions — Index\n\n"
    "| Date | Project | Session ID | Folder | Title | Created | Updated |\n"
    "|------|---------|------------|--------|-------|---------|--------|\n"
)


# ── DB helpers ────────────────────────────────────────────────────────────────

def open_db() -> sqlite3.Connection:
    if not OPENCODE_DB.exists():
        print(f"❌  OpenCode database not found at: {OPENCODE_DB}")
        sys.exit(1)
    # Read-only so we can never corrupt live OpenCode state
    conn = sqlite3.connect(f"file:{OPENCODE_DB}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def find_project_id(conn: sqlite3.Connection, cwd: Path) -> str | None:
    """Match cwd against project worktrees (exact, then longest prefix)."""
    rows = conn.execute("SELECT id, worktree FROM project").fetchall()
    cwd_str = str(cwd)
    for r in rows:
        if r["worktree"] == cwd_str:
            return r["id"]
    best = None
    for r in rows:
        wt = r["worktree"]
        if wt != "/" and cwd_str.startswith(wt.rstrip("/") + "/"):
            if best is None or len(wt) > len(best[1]):
                best = (r["id"], wt)
    return best[0] if best else None


def list_sessions(conn: sqlite3.Connection, project_id: str, include_subagents: bool) -> list[sqlite3.Row]:
    q = (
        "SELECT id, slug, title, directory, parent_id, time_created, time_updated "
        "FROM session WHERE project_id = ?"
    )
    if not include_subagents:
        q += " AND parent_id IS NULL"
    q += " ORDER BY time_created ASC"
    return conn.execute(q, (project_id,)).fetchall()


def load_messages(conn: sqlite3.Connection, session_id: str) -> list[dict]:
    """Return ordered messages, each with its ordered parts attached."""
    msgs = conn.execute(
        "SELECT id, time_created, data FROM message WHERE session_id = ? ORDER BY time_created ASC, id ASC",
        (session_id,),
    ).fetchall()
    parts_by_msg: dict[str, list[dict]] = {}
    for p in conn.execute(
        "SELECT message_id, data FROM part WHERE session_id = ? ORDER BY time_created ASC, id ASC",
        (session_id,),
    ):
        try:
            parts_by_msg.setdefault(p["message_id"], []).append(json.loads(p["data"]))
        except json.JSONDecodeError:
            pass
    out = []
    for m in msgs:
        try:
            data = json.loads(m["data"])
        except json.JSONDecodeError:
            continue
        data["_parts"] = parts_by_msg.get(m["id"], [])
        data["_time"] = m["time_created"]
        out.append(data)
    return out


# ── Content extraction ────────────────────────────────────────────────────────

def slugify(text: str, max_len: int = 45) -> str:
    text = text.lower().strip()
    text = re.sub(r"[^\w\s-]", "", text)
    text = re.sub(r"[\s_]+", "-", text)
    text = re.sub(r"-+", "-", text).strip("-")
    return text[:max_len].rstrip("-")


def parts_to_text(parts: list[dict]) -> str:
    chunks = []
    for p in parts:
        if p.get("type") == "text" and not p.get("synthetic"):
            t = (p.get("text") or "").strip()
            if t:
                chunks.append(t)
    return "\n\n".join(chunks)


def tool_summary(parts: list[dict]) -> list[str]:
    lines = []
    for p in parts:
        if p.get("type") != "tool":
            continue
        name = p.get("tool", "unknown")
        inp = (p.get("state") or {}).get("input", {})
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

def session_to_markdown(
    messages: list[dict],
    session_id: str,
    project_name: str,
    ts: datetime,
    title: str,
    directory: str | None = None,
) -> str:
    # YAML frontmatter — makes sessions queryable in Obsidian (Dataview etc.).
    lines = [
        "---",
        f"project: {project_name}",
        "tool: opencode",
        f"date: {ts.strftime('%Y-%m-%d')}",
        f"session_id: {session_id}",
        f"title: {json.dumps(title)}",
    ]
    if directory:
        lines.append(f"directory: {json.dumps(directory)}")
    lines += [
        "---",
        "",
        f"# {title}",
        f"**Project:** {project_name}  ",
        f"**Date:** {ts.strftime('%Y-%m-%d %H:%M')}  ",
        f"**Session ID:** `{session_id}`",
    ]
    if directory:
        lines.append(f"**Directory:** `{directory}`")
    lines += [
        "",
        "---",
        "",
    ]

    msg_count = 0
    for msg in messages:
        role = msg.get("role", "")
        parts = msg.get("_parts", [])
        text = parts_to_text(parts)

        if role == "user":
            if text:
                lines += ["## 👤 You", "", text, ""]
                msg_count += 1
        elif role == "assistant":
            tools = tool_summary(parts)
            if text or tools:
                lines += ["## 🤖 Assistant", ""]
                if text:
                    lines += [text, ""]
                for t in tools:
                    lines += [t, ""]
                msg_count += 1

    lines += ["---", "", f"*{msg_count} exchange(s) · opencode_session_exporter.py*"]
    return "\n".join(lines)


# ── Templates (identical to the Claude exporter) ──────────────────────────────

def plan_template(project_name: str, date_str: str) -> str:
    return f"""# Plan — {project_name} · {date_str}

## Goal
<!-- What are you trying to accomplish this session? -->

## Scope
<!-- What's in and what's out? -->

## Starting context
<!-- Anything not already in _context.md that the assistant needs to know? -->
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
    now = now_str()

    if session_id in content:
        lines = content.split("\n")
        new_lines = []
        for line in lines:
            if session_id in line:
                parts = line.split("|")
                if len(parts) >= 8:
                    parts[4] = f" `{folder_name}` "
                    parts[7] = f" {now} "
                line = "|".join(parts)
            new_lines.append(line)
        index_path.write_text("\n".join(new_lines), encoding="utf-8")
    else:
        row = (
            f"| {date_str} | {project_name} | `{session_id}` "
            f"| `{folder_name}` | {title} | {now} | {now} |\n"
        )
        with open(index_path, "a", encoding="utf-8") as f:
            f.write(row)


# ── Folder deduplication ──────────────────────────────────────────────────────

def find_existing_session_folder(project_out_dir: Path, session_id: str) -> Path | None:
    if not project_out_dir.exists():
        return None
    for folder in project_out_dir.iterdir():
        if not folder.is_dir():
            continue
        conv = folder / "conversation.md"
        if not conv.exists():
            continue
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
        print("  📄  Created _context.md")


# ── Core export ───────────────────────────────────────────────────────────────

def export_session(
    conn: sqlite3.Connection,
    session_row: sqlite3.Row,
    project_name: str,
    project_out_dir: Path,
    slug: str | None = None,
):
    session_id = session_row["id"]
    title = session_row["title"] or f"Session {session_id}"
    ts = datetime.fromtimestamp(session_row["time_created"] / 1000)
    date_str = ts.strftime("%Y-%m-%d")

    messages = load_messages(conn, session_id)

    existing = find_existing_session_folder(project_out_dir, session_id)
    if existing:
        session_dir = existing
        is_update = True
    else:
        if slug:
            base_name = f"{date_str}_{slug}"
        elif title and not title.startswith("Session "):
            base_name = f"{date_str}_{slugify(title)}"
        else:
            base_name = f"{date_str}_{ts.strftime('%H-%M')}_{session_id[-6:]}"

        folder_name = base_name
        session_dir = project_out_dir / folder_name

        # Collision guard: a DIFFERENT session already owns this folder name (two
        # sessions with the same title on the same day) — disambiguate instead of
        # silently overwriting the other session's export every run.
        if session_dir.exists():
            existing_conv = session_dir / "conversation.md"
            owner_id = None
            if existing_conv.exists():
                head = existing_conv.read_bytes()[:800].decode("utf-8", errors="ignore")
                m = re.search(r"session_id: (ses_[A-Za-z0-9]+)", head) or \
                    re.search(r"\*\*Session ID:\*\* `(ses_[A-Za-z0-9]+)`", head)
                owner_id = m.group(1) if m else None
            if owner_id and owner_id != session_id:
                folder_name = f"{base_name}-{session_id[-6:]}"
                session_dir = project_out_dir / folder_name

        is_update = False

    artifacts_dir = session_dir / "artifacts"
    session_dir.mkdir(parents=True, exist_ok=True)
    artifacts_dir.mkdir(exist_ok=True)

    md = session_to_markdown(
        messages, session_id, project_name, ts, title,
        directory=session_row["directory"],
    )
    (session_dir / "conversation.md").write_text(md, encoding="utf-8")

    plan_path = session_dir / "plan.md"
    if not plan_path.exists():
        plan_path.write_text(plan_template(project_name, date_str), encoding="utf-8")

    summary_path = session_dir / "summary.md"
    if not summary_path.exists():
        summary_path.write_text(summary_template(project_name, date_str), encoding="utf-8")

    return session_dir, title, session_id, date_str, is_update


# ── Sync mode ─────────────────────────────────────────────────────────────────

def sync_archive(conn: sqlite3.Connection, project_filter: str | None = None) -> None:
    """
    Refresh conversation.md for every already-exported session, archive-wide.
    Each folder's session ID (from the conversation.md header) is looked up in
    the DB directly — no cwd/worktree matching, so ghosts and global sessions
    sync the same as everything else. Only conversation.md is rewritten.
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
            m = re.search(r"session_id: (ses_[A-Za-z0-9]+)", head) or \
                re.search(r"\*\*Session ID:\*\* `(ses_[A-Za-z0-9]+)`", head)
            if not m:
                continue
            sid = m.group(1)
            total += 1

            row = conn.execute(
                "SELECT id, title, directory, time_created FROM session WHERE id = ?",
                (sid,),
            ).fetchone()
            if not row:
                print(f"⚠  source gone   {proj_dir.name}/{sess_dir.name}")
                missing += 1
                continue

            messages = load_messages(conn, sid)
            ts    = datetime.fromtimestamp(row["time_created"] / 1000)
            title = row["title"] or f"Session {sid}"
            md  = session_to_markdown(messages, sid, proj_dir.name, ts, title,
                                      directory=row["directory"])
            old = conv.read_text(encoding="utf-8")
            if md != old:
                conv.write_text(md, encoding="utf-8")
                update_index(OUTPUT_BASE_DIR, proj_dir.name, sid, sess_dir.name,
                             ts.strftime("%Y-%m-%d"), title)
                print(f"↻  synced       {proj_dir.name}/{sess_dir.name}")
                updated += 1

    print(f"\nSYNC: {total} session(s) checked · {updated} refreshed · {missing} source(s) missing")


# ── CLI ───────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Export OpenCode sessions into ~/AI Sessions/Opencode Sessions/{project}/{session}/",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
examples:
  %(prog)s --project phokus
  %(prog)s --project phokus --slug schema-migration
  %(prog)s --project phokus --all
  %(prog)s --project phokus --list
        """,
    )
    parser.add_argument("--project", type=str,
                        help="Project name (folder name under ~/AI Sessions/Opencode Sessions/). "
                             "Not used with --global (folders are derived per-session from each "
                             "session's originating directory).")
    parser.add_argument("--slug", type=str,
                        help="Topic slug for the session folder (ignored on --all)")
    parser.add_argument("--all", action="store_true",
                        help="Export all sessions, not just the latest")
    parser.add_argument("--list", action="store_true",
                        help="List available sessions without exporting")
    parser.add_argument("--include-subagents", action="store_true",
                        help="Also export subagent child sessions (skipped by default)")
    parser.add_argument("--global", dest="global_", action="store_true",
                        help="Export the 'global' pseudo-project (sessions started outside "
                             "any registered worktree) — bypasses cwd matching")
    parser.add_argument("--worktree", type=str,
                        help="Select a project by its registered worktree path (exact match) "
                             "instead of cwd — for projects whose directory was deleted")
    parser.add_argument("--sync", action="store_true",
                        help="Refresh conversation.md for every already-exported session "
                             "across the whole archive (no cwd needed); plan/summary/artifacts untouched")
    args = parser.parse_args()

    cwd = Path.cwd()
    conn = open_db()

    if args.sync:
        sync_archive(conn, project_filter=args.project)
        conn.close()
        return

    if args.global_ and args.worktree:
        print("❌  --global and --worktree are mutually exclusive")
        sys.exit(1)
    if not args.global_ and not args.project:
        print("❌  --project is required (except with --global or --sync)")
        sys.exit(1)

    if args.global_:
        project_id = "global"
    elif args.worktree:
        row = conn.execute(
            "SELECT id FROM project WHERE worktree = ?", (args.worktree,)
        ).fetchone()
        if not row:
            print(f"❌  No OpenCode project registered with worktree: {args.worktree}")
            print("    Registered worktrees:")
            for r in conn.execute("SELECT worktree FROM project WHERE worktree != '/'"):
                print(f"      {r['worktree']}")
            sys.exit(1)
        project_id = row["id"]
    else:
        project_id = find_project_id(conn, cwd)

    if not project_id:
        print(f"❌  No OpenCode project found for: {cwd}")
        print("    Known projects:")
        for r in conn.execute("SELECT worktree FROM project WHERE worktree != '/'"):
            print(f"      {r['worktree']}")
        print("    Run from inside a directory where you've used OpenCode,")
        print("    or use --worktree <path> / --global for unreachable projects.")
        sys.exit(1)

    project_name = args.project or "global"
    project_out_dir = OUTPUT_BASE_DIR / project_name
    sessions = list_sessions(conn, project_id, args.include_subagents)

    if not sessions:
        print("No sessions found.")
        sys.exit(0)

    # ── List mode ──────────────────────────────────────────────────────────────
    if args.list:
        print(f"\nSessions for: {cwd.name}\n")
        print(f"  {'DATE':<12}  {'SESSION ID':<32}  TITLE")
        print(f"  {'-'*12}  {'-'*32}  {'-'*40}")
        for s in sessions:
            mtime = datetime.fromtimestamp(s["time_created"] / 1000).strftime("%Y-%m-%d")
            print(f"  {mtime:<12}  {s['id']:<32}  {(s['title'] or '—')[:60]}")
        print(f"\n{len(sessions)} session(s) total.")
        return

    # ── Export mode ────────────────────────────────────────────────────────────
    to_export = sessions if args.all else [sessions[-1]]
    slug = None if args.all else args.slug

    if args.slug and args.all:
        print("⚠️   --slug ignored with --all")

    out_dirs = set()
    for s in to_export:
        # Global sessions have no shared project — group each by the directory
        # it actually ran in, so ~/My/Obsidian/R-Jerry sessions land in r-jerry/,
        # not in one undifferentiated bucket.
        if args.global_:
            dir_name = Path(s["directory"]).name if s["directory"] else "unknown"
            per_project_name = slugify(dir_name) or "unknown"
            per_out_dir = OUTPUT_BASE_DIR / per_project_name
        else:
            per_project_name = project_name
            per_out_dir = project_out_dir

        if per_out_dir not in out_dirs:
            scaffold_project(per_out_dir, per_project_name)
            out_dirs.add(per_out_dir)

        session_dir, title, session_id, date_str, is_update = export_session(
            conn, s, per_project_name, per_out_dir, slug=slug
        )
        update_index(OUTPUT_BASE_DIR, per_project_name, session_id, session_dir.name, date_str, title)
        tag = "↻  updated" if is_update else "✅  created"
        print(f"{tag}  {per_project_name}/{session_dir.name}  —  {title[:50]}")

    for d in sorted(out_dirs):
        print(f"\n→  {d}")
    conn.close()


if __name__ == "__main__":
    main()
