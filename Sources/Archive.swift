// Archive layout shared by both exporters: _index.md, _context.md,
// plan/summary templates, and the folder-dedup lookup.
import Foundation

typealias Log = (String) -> Void

struct Archive {
    let base: URL
    let indexTitle: String  // "Claude Sessions" / "Opencode Sessions"
    let assistantWord: String  // used in plan.md's "Starting context" hint

    var indexHeader: String {
        "# \(indexTitle) — Index\n\n"
            + "| Date | Project | Session ID | Folder | Title | Created | Updated |\n"
            + "|------|---------|------------|--------|-------|---------|--------|\n"
    }

    func updateIndex(project: String, sessionID: String, folder: String, date: String, title: String) {
        let path = base.appendingPathComponent("_index.md")
        if !exists(path) { writeText(path, indexHeader) }
        let content = readText(path) ?? ""
        let now = nowString()
        if content.range(of: sessionID, options: .literal) != nil {
            let lines = content.components(separatedBy: "\n").map { line -> String in
                guard line.range(of: sessionID, options: .literal) != nil else { return line }
                var parts = line.components(separatedBy: "|")
                if parts.count >= 8 {
                    parts[4] = " `\(folder)` "
                    parts[7] = " \(now) "
                }
                return parts.joined(separator: "|")
            }
            writeText(path, lines.joined(separator: "\n"))
        } else {
            appendText(path, "| \(date) | \(project) | `\(sessionID)` | `\(folder)` | \(title) | \(now) | \(now) |\n")
        }
    }

    func findExistingSessionFolder(_ projectOut: URL, _ sessionID: String) -> URL? {
        guard exists(projectOut) else { return nil }
        for name in listDir(projectOut) {
            let folder = projectOut.appendingPathComponent(name)
            guard isDir(folder) else { continue }
            let conv = folder.appendingPathComponent("conversation.md")
            guard exists(conv) else { continue }
            if head800(conv).range(of: sessionID, options: .literal) != nil { return folder }
        }
        return nil
    }

    func scaffoldProject(_ dir: URL, _ name: String, _ log: Log) {
        mkdirs(dir)
        let ctx = dir.appendingPathComponent("_context.md")
        if !exists(ctx) {
            writeText(ctx, contextTemplate(name))
            log("  📄  Created _context.md")
        }
    }

    /// Writes conversation.md every time; plan/summary only once.
    func writeSession(_ dir: URL, markdown: String, project: String, date: String) {
        mkdirs(dir)
        mkdirs(dir.appendingPathComponent("artifacts"))
        writeText(dir.appendingPathComponent("conversation.md"), markdown)
        let plan = dir.appendingPathComponent("plan.md")
        if !exists(plan) { writeText(plan, planTemplate(project, date)) }
        let summary = dir.appendingPathComponent("summary.md")
        if !exists(summary) { writeText(summary, summaryTemplate(project, date)) }
    }

    /// New folder name, disambiguated when a different session already owns it.
    func newSessionFolder(_ projectOut: URL, base baseName: String, sessionID: String,
                          ownerPattern: String, suffix: String) -> URL {
        let dir = projectOut.appendingPathComponent(baseName)
        guard exists(dir) else { return dir }
        let conv = dir.appendingPathComponent("conversation.md")
        guard exists(conv) else { return dir }
        let head = head800(conv)
        let owner = firstMatch("session_id: (\(ownerPattern))", in: head)
            ?? firstMatch("\\*\\*Session ID:\\*\\* `(\(ownerPattern))`", in: head)
        if let owner, owner != sessionID {
            return projectOut.appendingPathComponent("\(baseName)-\(suffix)")
        }
        return dir
    }

    func planTemplate(_ project: String, _ date: String) -> String {
        """
        # Plan — \(project) · \(date)

        ## Goal
        <!-- What are you trying to accomplish this session? -->

        ## Scope
        <!-- What's in and what's out? -->

        ## Starting context
        <!-- Anything not already in _context.md that \(assistantWord) needs to know? -->

        """
    }

    func summaryTemplate(_ project: String, _ date: String) -> String {
        """
        # Summary — \(project) · \(date)

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
    }

    func contextTemplate(_ project: String) -> String {
        """
        # \(project) — Project Context

        _Last updated: \(Stamp(local: Date()).date)_

        ## Stack
        <!-- Key technologies, versions, architecture decisions -->

        ## Current state
        <!-- Where things stand right now -->

        ## Active work
        <!-- What's in progress -->

        ## Key decisions
        <!-- Important decisions already made — keep this current -->

        """
    }
}

/// Renders up to 3 tool-input params the way the Python did: `str(v)`, cut at 120 code points.
func toolLine(name: String, input: JSON?) -> String {
    var line = "*🔧 `\(name)`*"
    if case .object(let keys, let values)? = input {
        for (k, v) in zip(keys, values).prefix(3) {
            var val = pyStr(v)
            if pyLen(val) > 120 { val = pyPrefix(val, 120) + "…" }
            line += "\n  - `\(k)`: \(val)"
        }
    }
    return line
}
