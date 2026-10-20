// Port of opencode_session_exporter.py: OpenCode SQLite → Markdown archive.
import Foundation
import SQLite3

enum SQLValue {
    case int(Int64), double(Double), text(String), null

    var text: String? { if case .text(let s) = self { return s }; return nil }
    var number: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .double(let v): return v
        default: return nil
        }
    }
}

final class SQLiteDB {
    private var db: OpaquePointer?

    /// Read-only, so the exporter can never corrupt live OpenCode state.
    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit { sqlite3_close(db) }

    func rows(_ sql: String, _ args: [String] = []) -> [[String: SQLValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), a, -1, transient) }
        var out: [[String: SQLValue]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: SQLValue] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_NULL: row[name] = .null
                default:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_text(stmt, c) {
                        row[name] = .text(String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self))
                    } else {
                        row[name] = .null
                    }
                }
            }
            out.append(row)
        }
        return out
    }
}

struct OpenCodeExporter {
    let dbPath: String
    let outputDir: URL
    let log: Log

    var archive: Archive { Archive(base: outputDir, indexTitle: "Opencode Sessions", assistantWord: "the assistant") }

    func open() -> SQLiteDB? {
        let db = SQLiteDB(path: dbPath)
        if db == nil { log("❌  OpenCode database not found at: \(dbPath)") }
        return db
    }

    /// (worktree, display name) for every registered project.
    func projects() -> [(String, String)] {
        guard let db = SQLiteDB(path: dbPath) else { return [] }
        return db.rows("SELECT worktree FROM project WHERE worktree != '/'").compactMap {
            guard let wt = $0["worktree"]?.text else { return nil }
            return (wt, (wt as NSString).lastPathComponent)
        }
    }

    struct Message { let data: JSON; let parts: [JSON] }

    func loadMessages(_ db: SQLiteDB, _ sid: String) -> [Message] {
        var partsByMsg: [String: [JSON]] = [:]
        for p in db.rows("SELECT message_id, data FROM part WHERE session_id = ? ORDER BY time_created ASC, id ASC", [sid]) {
            guard let mid = p["message_id"]?.text, let raw = p["data"]?.text, let json = JSONParser.parse(raw) else { continue }
            partsByMsg[mid, default: []].append(json)
        }
        return db.rows("SELECT id, time_created, data FROM message WHERE session_id = ? ORDER BY time_created ASC, id ASC", [sid])
            .compactMap { m in
                guard let raw = m["data"]?.text, let data = JSONParser.parse(raw), data.isObject else { return nil }
                return Message(data: data, parts: partsByMsg[m["id"]?.text ?? ""] ?? [])
            }
    }

    func partsToText(_ parts: [JSON]) -> String {
        var chunks: [String] = []
        for p in parts where p.isObject && p["type"]?.stringValue == "text" && !(p["synthetic"]?.truthy ?? false) {
            let t = pyStrip(p["text"]?.stringValue ?? "")
            if !t.isEmpty { chunks.append(t) }
        }
        return chunks.joined(separator: "\n\n")
    }

    func toolSummary(_ parts: [JSON]) -> [String] {
        parts.compactMap { p in
            guard p.isObject, p["type"]?.stringValue == "tool" else { return nil }
            let state = p["state"].flatMap { $0.truthy ? $0 : nil }
            return toolLine(name: p["tool"].map(pyStr) ?? "unknown", input: state?["input"])
        }
    }

    func markdown(_ messages: [Message], sessionID: String, project: String, stamp: Stamp,
                  title: String, directory: String?) -> String {
        let dir = (directory?.isEmpty ?? true) ? nil : directory
        var lines = [
            "---",
            "project: \(project)",
            "tool: opencode",
            "date: \(stamp.date)",
            "session_id: \(sessionID)",
            "title: \(pyJSONDumps(title))",
        ]
        if let dir { lines.append("directory: \(pyJSONDumps(dir))") }
        lines += [
            "---",
            "",
            "# \(title)",
            "**Project:** \(project)  ",
            "**Date:** \(stamp.dateTime)  ",
            "**Session ID:** `\(sessionID)`",
        ]
        if let dir { lines.append("**Directory:** `\(dir)`") }
        lines += ["", "---", ""]

        var count = 0
        for msg in messages {
            let role = msg.data["role"]?.stringValue ?? ""
            let text = partsToText(msg.parts)
            if role == "user" {
                if !text.isEmpty {
                    lines += ["## 👤 You", "", text, ""]
                    count += 1
                }
            } else if role == "assistant" {
                let tools = toolSummary(msg.parts)
                if !text.isEmpty || !tools.isEmpty {
                    lines += ["## 🤖 Assistant", ""]
                    if !text.isEmpty { lines += [text, ""] }
                    for t in tools { lines += [t, ""] }
                    count += 1
                }
            }
        }
        lines += ["---", "", "*\(count) exchange(s) · opencode_session_exporter.py*"]
        return lines.joined(separator: "\n")
    }

    func stamp(_ row: [String: SQLValue]) -> Stamp {
        Stamp(local: Date(timeIntervalSince1970: (row["time_created"]?.number ?? 0) / 1000))
    }

    func title(_ row: [String: SQLValue], _ sid: String) -> String {
        if let t = row["title"]?.text, !t.isEmpty { return t }
        return "Session \(sid)"
    }

    // MARK: Sync

    func sync() {
        guard let db = open() else { return }
        guard exists(outputDir) else {
            log("❌  Archive not found: \(outputDir.path)")
            return
        }
        var total = 0, updated = 0, missing = 0
        for proj in pySorted(listDir(outputDir)) {
            let projDir = outputDir.appendingPathComponent(proj)
            guard isDir(projDir), !proj.hasPrefix("_"), !proj.hasPrefix(".") else { continue }
            for sess in pySorted(listDir(projDir)) {
                let sessDir = projDir.appendingPathComponent(sess)
                let conv = sessDir.appendingPathComponent("conversation.md")
                guard isDir(sessDir), exists(conv) else { continue }
                let head = head800(conv)
                guard let sid = firstMatch("session_id: (ses_[A-Za-z0-9]+)", in: head)
                        ?? firstMatch("\\*\\*Session ID:\\*\\* `(ses_[A-Za-z0-9]+)`", in: head) else { continue }
                total += 1

                guard let row = db.rows("SELECT id, title, directory, time_created FROM session WHERE id = ?", [sid]).first else {
                    log("⚠  source gone   \(proj)/\(sess)")
                    missing += 1
                    continue
                }
                let st = stamp(row)
                let t = title(row, sid)
                let md = markdown(loadMessages(db, sid), sessionID: sid, project: proj, stamp: st,
                                  title: t, directory: row["directory"]?.text)
                if !sameBytes(md, readText(conv) ?? "") {
                    writeText(conv, md)
                    archive.updateIndex(project: proj, sessionID: sid, folder: sess, date: st.date, title: t)
                    log("↻  synced       \(proj)/\(sess)")
                    updated += 1
                }
            }
        }
        log("\nSYNC: \(total) session(s) checked · \(updated) refreshed · \(missing) source(s) missing")
    }

    // MARK: Export (equivalent of --worktree WT --project NAME --all)

    func export(worktree: String, project: String) {
        guard let db = open() else { return }
        guard let projectID = db.rows("SELECT id FROM project WHERE worktree = ?", [worktree]).first?["id"]?.text else {
            log("❌  No OpenCode project registered with worktree: \(worktree)")
            return
        }
        let sessions = db.rows(
            "SELECT id, slug, title, directory, parent_id, time_created, time_updated "
                + "FROM session WHERE project_id = ? AND parent_id IS NULL ORDER BY time_created ASC",
            [projectID])
        guard !sessions.isEmpty else {
            log("No sessions found.")
            return
        }
        let projectOut = outputDir.appendingPathComponent(project)
        archive.scaffoldProject(projectOut, project, log)

        for row in sessions {
            guard let sid = row["id"]?.text else { continue }
            let t = title(row, sid)
            let st = stamp(row)

            let sessionDir: URL
            let isUpdate: Bool
            if let existing = archive.findExistingSessionFolder(projectOut, sid) {
                sessionDir = existing
                isUpdate = true
            } else {
                let base = t.hasPrefix("Session ")
                    ? "\(st.date)_\(st.hourMinDash)_\(pySuffix(sid, 6))"
                    : "\(st.date)_\(slugify(t))"
                sessionDir = archive.newSessionFolder(projectOut, base: base, sessionID: sid,
                                                      ownerPattern: "ses_[A-Za-z0-9]+", suffix: pySuffix(sid, 6))
                isUpdate = false
            }

            let md = markdown(loadMessages(db, sid), sessionID: sid, project: project, stamp: st,
                              title: t, directory: row["directory"]?.text)
            archive.writeSession(sessionDir, markdown: md, project: project, date: st.date)
            archive.updateIndex(project: project, sessionID: sid, folder: sessionDir.lastPathComponent,
                                date: st.date, title: t)
            log("\(isUpdate ? "↻  updated" : "✅  created")  \(project)/\(sessionDir.lastPathComponent)  —  \(pyPrefix(t, 50))")
        }
        log("\n→  \(projectOut.path)")
    }
}
