#!/usr/bin/env python3
"""Local web UI over claude_session_exporter.py / opencode_session_exporter.py.

Buttons call the same sync_archive()/CLI those scripts already expose — this
file adds no export logic of its own, just a browser front end.

Run:  python3 sync_ui.py   then open http://127.0.0.1:8765
"""
import io
import json
import sqlite3
import subprocess
import sys
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

SCRIPTS_DIR = Path(__file__).parent
sys.path.insert(0, str(SCRIPTS_DIR))
import claude_session_exporter as cce
import opencode_session_exporter as oce

PORT = 8765

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>Session Sync</title>
<style>
body{font:14px/1.4 -apple-system,sans-serif;max-width:860px;margin:2rem auto;padding:0 1rem;color:#222}
h2{margin-top:2rem}
button{padding:.5rem 1rem;margin:.25rem .25rem .25rem 0;cursor:pointer;border:1px solid #888;border-radius:4px;background:#f6f6f6}
button:hover{background:#eee}
pre{background:#111;color:#0f0;padding:1rem;border-radius:4px;max-height:40vh;overflow:auto;white-space:pre-wrap}
.row{display:flex;align-items:center;gap:.5rem;margin:.25rem 0}
select{padding:.3rem}
</style></head>
<body>
<h1>Session Sync</h1>

<h2>Refresh archive (re-pulls source into already-exported sessions)</h2>
<button onclick="run('/api/sync?tool=claude')">Sync Claude archive</button>
<button onclick="run('/api/sync?tool=opencode')">Sync OpenCode archive</button>
<button onclick="run('/api/sync?tool=both')">Sync both</button>

<h2>Export a project's sessions</h2>
<div class="row">
  <select id="tool" onchange="loadProjects()"><option value="claude">Claude</option><option value="opencode">OpenCode</option></select>
  <select id="project"></select>
  <button onclick="exportProject()">Export all sessions</button>
</div>

<h2>Output</h2>
<pre id="out">(nothing run yet)</pre>

<script>
async function run(url){
  document.getElementById('out').textContent = 'running...';
  const r = await fetch(url, {method:'POST'});
  document.getElementById('out').textContent = await r.text();
}
async function loadProjects(){
  const tool = document.getElementById('tool').value;
  const r = await fetch('/api/projects?tool='+tool);
  const items = await r.json();
  const sel = document.getElementById('project');
  sel.innerHTML = items.map(p => `<option value="${p.key}">${p.name}</option>`).join('');
}
async function exportProject(){
  const tool = document.getElementById('tool').value;
  const key = document.getElementById('project').value;
  if(!key) return;
  await run('/api/export?tool='+tool+'&key='+encodeURIComponent(key));
}
loadProjects();
</script>
</body></html>"""


def claude_projects():
    return [{"key": d.name, "name": d.name} for d in sorted(cce.CLAUDE_PROJECTS_DIR.iterdir()) if d.is_dir()]


def opencode_projects():
    conn = oce.open_db()
    rows = conn.execute("SELECT worktree FROM project WHERE worktree != '/'").fetchall()
    conn.close()
    return [{"key": r["worktree"], "name": Path(r["worktree"]).name} for r in rows]


def run_sync(tool: str) -> str:
    buf = io.StringIO()
    with redirect_stdout(buf):
        if tool in ("claude", "both"):
            print("=== Claude sync ===")
            cce.sync_archive()
        if tool in ("opencode", "both"):
            print("=== OpenCode sync ===")
            conn = oce.open_db()
            oce.sync_archive(conn)
            conn.close()
    return buf.getvalue()


def run_export(tool: str, key: str) -> str:
    # ponytail: keys can start with "-" (encoded project dirs) — "=" form keeps
    # argparse from mistaking the value for another flag.
    if tool == "claude":
        cmd = [sys.executable, str(SCRIPTS_DIR / "claude_session_exporter.py"),
               f"--project={key}", f"--encoded={key}", "--all"]
    else:
        cmd = [sys.executable, str(SCRIPTS_DIR / "opencode_session_exporter.py"),
               f"--worktree={key}", "--all"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.stdout + r.stderr


class Handler(BaseHTTPRequestHandler):
    def _send(self, body: str, status=200, ctype="text/plain; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._send(PAGE, ctype="text/html; charset=utf-8")
        elif parsed.path == "/api/projects":
            tool = parse_qs(parsed.query).get("tool", ["claude"])[0]
            items = claude_projects() if tool == "claude" else opencode_projects()
            self._send(json.dumps(items), ctype="application/json")
        else:
            self._send("not found", 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        try:
            if parsed.path == "/api/sync":
                self._send(run_sync(qs.get("tool", ["both"])[0]))
            elif parsed.path == "/api/export":
                self._send(run_export(qs["tool"][0], qs["key"][0]))
            else:
                self._send("not found", 404)
        except Exception as e:
            self._send(f"error: {e}", 500)

    def log_message(self, fmt, *args):
        pass  # ponytail: quiet by default, flip on for debugging


def _selftest():
    assert isinstance(claude_projects(), list)
    assert isinstance(opencode_projects(), list)
    print("selftest ok")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        _selftest()
        sys.exit(0)
    print(f"Session Sync UI → http://127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
