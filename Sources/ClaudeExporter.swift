// Port of claude_session_exporter.py: Claude Code JSONL → Markdown archive.
import Foundation

struct ClaudeExporter {
    let projectsDir: URL
    let outputDir: URL
    let log: Log

    var archive: Archive { Archive(base: outputDir, indexTitle: "Claude Sessions", assistantWord: "Claude") }

    static let noiseTypes: Set<String> = [
        "queue-operation", "system", "last-prompt", "mode",
        "permission-mode", "file-history-snapshot", "ai-title",
        "token-count", "debug",
    ]

    // MARK: Listing

    func projects() -> [String] {
        pySorted(listDir(projectsDir)).filter { isDir(projectsDir.appendingPathComponent($0)) }
    }

    func sessions(in projectDir: URL) -> [URL] {
        listDir(projectDir)
            .filter { $0.hasSuffix(".jsonl") }
            .map { projectDir.appendingPathComponent($0) }
            .filter { !isDir($0) }
            .enumerated()
            .sorted { a, b in
                let (ma, mb) = (mtime(a.element), mtime(b.element))
                return ma != mb ? ma < mb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Best-effort friendly archive name: the working directory recorded in the newest session.
    func suggestedName(for key: String) -> String? {
        guard let newest = sessions(in: projectsDir.appendingPathComponent(key)).last,
              let data = try? Data(contentsOf: newest) else { return nil }
        var cwd: String?
        forEachJSONLine(data) { entry in
            if let c = entry["cwd"]?.stringValue, !c.isEmpty { cwd = c; return false }
            return true
        }
        guard let cwd else { return nil }
        let slug = slugify((cwd as NSString).lastPathComponent)
        return slug.isEmpty ? nil : slug
    }

    // MARK: Rendering

    func timestamp(_ entries: [JSON], _ fallback: URL) -> Stamp {
        for e in entries {
            guard let ts = e["timestamp"], ts.truthy else { continue }
            if let s = Stamp(iso: pyStr(ts)) { return s }
        }
        return Stamp(local: Date(timeIntervalSince1970: mtime(fallback)))
    }

    func aiTitle(_ entries: [JSON]) -> String? {
        for e in entries where e["type"]?.stringValue == "ai-title" {
            if let t = e["aiTitle"], t.truthy { return pyStr(t) }
        }
        return nil
    }

    func contentToText(_ content: JSON) -> String {
        switch content {
        case .string(let s):
            return pyStrip(s)
        case .array(let blocks):
            var parts: [String] = []
            for block in blocks where block.isObject && block["type"]?.stringValue == "text" {
                let t = pyStrip(block["text"]?.stringValue ?? "")
                if !t.isEmpty { parts.append(t) }
            }
            return parts.joined(separator: "\n\n")
        default:
            return ""
        }
    }

    func toolSummary(_ blocks: [JSON]) -> [String] {
        blocks.compactMap { block in
            guard block.isObject, block["type"]?.stringValue == "tool_use" else { return nil }
            return toolLine(name: block["name"].map(pyStr) ?? "unknown", input: block["input"])
        }
    }

    func markdown(_ entries: [JSON], sessionID: String, project: String, stamp: Stamp, aiTitle: String?) -> String {
        let title = aiTitle ?? "Session \(sessionID)"
        var lines = [
            "---",
            "project: \(project)",
            "tool: claude-code",
            "date: \(stamp.date)",
            "session_id: \(sessionID)",
            "title: \(pyJSONDumps(title))",
            "---",
            "",
            "# \(title)",
            "**Project:** \(project)  ",
            "**Date:** \(stamp.dateTime)  ",
            "**Session ID:** `\(sessionID)`",
            "",
            "---",
            "",
        ]
        var count = 0
        for entry in entries {
            if let t = entry["type"]?.stringValue, Self.noiseTypes.contains(t) { continue }
            if entry["isMeta"]?.truthy == true { continue }
            if entry["attachment"] != nil && entry["message"] == nil { continue }
            guard let msg = entry["message"], msg.truthy, msg.isObject else { continue }
            let role = msg["role"]?.stringValue ?? ""
            let content = msg["content"] ?? .string("")
            if role == "user" {
                let text = contentToText(content)
                if !text.isEmpty {
                    lines += ["## 👤 You", "", text, ""]
                    count += 1
                }
            } else if role == "assistant" {
                if case .string(let s) = content {
                    let text = pyStrip(s)
                    if !text.isEmpty {
                        lines += ["## 🤖 Claude", "", text, ""]
                        count += 1
                    }
                } else if case .array(let blocks) = content {
                    let text = contentToText(content)
                    let tools = toolSummary(blocks)
                    if !text.isEmpty || !tools.isEmpty {
                        lines += ["## 🤖 Claude", ""]
                        if !text.isEmpty { lines += [text, ""] }
                        for t in tools { lines += [t, ""] }
                        count += 1
                    }
                }
            }
        }
        lines += ["---", "", "*\(count) exchange(s) · claude_session_exporter.py*"]
        return lines.joined(separator: "\n")
    }

    // MARK: Sync

    func sync() {
        guard exists(outputDir) else {
            log("❌  Archive not found: \(outputDir.path)")
            return
        }
        let sourceProjects = listDir(projectsDir)
        var total = 0, updated = 0, missing = 0
        for proj in pySorted(listDir(outputDir)) {
            let projDir = outputDir.appendingPathComponent(proj)
            guard isDir(projDir), !proj.hasPrefix("_"), !proj.hasPrefix(".") else { continue }
            for sess in pySorted(listDir(projDir)) {
                let sessDir = projDir.appendingPathComponent(sess)
                let conv = sessDir.appendingPathComponent("conversation.md")
                guard isDir(sessDir), exists(conv) else { continue }
                let head = head800(conv)
                guard let sid = firstMatch("session_id: ([0-9a-f-]{36})", in: head)
                        ?? firstMatch("\\*\\*Session ID:\\*\\* `([0-9a-f-]{36})`", in: head) else { continue }
                total += 1

                let candidates = sourceProjects
                    .map { projectsDir.appendingPathComponent($0).appendingPathComponent("\(sid).jsonl") }
                    .filter(exists)
                guard var src = candidates.first else {
                    log("⚠  source gone   \(proj)/\(sess)")
                    missing += 1
                    continue
                }
                // Same ID can exist under several project keys; newest write wins.
                for c in candidates.dropFirst() where mtime(c) > mtime(src) { src = c }

                let entries = parseJSONL(src)
                let stamp = timestamp(entries, src)
                let title = aiTitle(entries)
                let md = markdown(entries, sessionID: sid, project: proj, stamp: stamp, aiTitle: title)
                if !sameBytes(md, readText(conv) ?? "") {
                    writeText(conv, md)
                    archive.updateIndex(project: proj, sessionID: sid, folder: sess, date: stamp.date, title: title ?? sess)
                    log("↻  synced       \(proj)/\(sess)")
                    updated += 1
                }
            }
        }
        log("\nSYNC: \(total) session(s) checked · \(updated) refreshed · \(missing) source(s) missing")
    }

    // MARK: Export (equivalent of --project NAME --encoded KEY --all)

    func export(key: String, project: String) {
        let projectDir = projectsDir.appendingPathComponent(key)
        guard isDir(projectDir) else {
            log("❌  No project dir named: \(key)")
            return
        }
        let files = sessions(in: projectDir)
        guard !files.isEmpty else {
            log("No sessions found.")
            return
        }
        let projectOut = outputDir.appendingPathComponent(project)
        archive.scaffoldProject(projectOut, project, log)

        for file in files {
            let entries = parseJSONL(file)
            let sid = String(file.lastPathComponent.dropLast(".jsonl".count))
            let stamp = timestamp(entries, file)
            let title = aiTitle(entries)

            let sessionDir: URL
            let isUpdate: Bool
            if let existing = archive.findExistingSessionFolder(projectOut, sid) {
                sessionDir = existing
                isUpdate = true
            } else {
                let base = title.map { "\(stamp.date)_\(slugify($0))" }
                    ?? "\(stamp.date)_\(stamp.hourMinDash)_\(pyPrefix(sid, 6))"
                sessionDir = archive.newSessionFolder(projectOut, base: base, sessionID: sid,
                                                      ownerPattern: "[0-9a-f-]{36}", suffix: pyPrefix(sid, 6))
                isUpdate = false
            }

            let md = markdown(entries, sessionID: sid, project: project, stamp: stamp, aiTitle: title)
            archive.writeSession(sessionDir, markdown: md, project: project, date: stamp.date)
            let indexTitle = title ?? sessionDir.lastPathComponent
            archive.updateIndex(project: project, sessionID: sid, folder: sessionDir.lastPathComponent,
                                date: stamp.date, title: indexTitle)
            log("\(isUpdate ? "↻  updated" : "✅  created")  \(sessionDir.lastPathComponent)  —  \(pyPrefix(indexTitle, 50))")
        }
        log("\n→  \(projectOut.path)")
    }
}
