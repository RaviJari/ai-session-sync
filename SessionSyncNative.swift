// Real AppKit controls, Auto Layout, no WKWebView/HTML. Talks to the existing
// sync_ui.py HTTP endpoints over URLSession/JSON.
import Cocoa

let base = "http://127.0.0.1:8765"

func call(_ path: String, method: String = "GET", done: @escaping (String) -> Void) {
    var req = URLRequest(url: URL(string: base + path)!)
    req.httpMethod = method
    URLSession.shared.dataTask(with: req) { data, _, err in
        let text = err.map { "error: \($0)" } ?? String(data: data ?? Data(), encoding: .utf8) ?? ""
        DispatchQueue.main.async { done(text) }
    }.resume()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var toolPopup: NSPopUpButton!
    var projectPopup: NSPopUpButton!
    var output: NSTextView!
    var spinner: NSProgressIndicator!
    var actionButtons: [NSButton] = []
    var projectKeys: [String] = []

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        window.title = "Session Sync"
        window.minSize = NSSize(width: 560, height: 360)
        window.center()
        window.isReleasedWhenClosed = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        // Row 1 — sync actions
        let syncRow = NSStackView()
        syncRow.orientation = .horizontal
        syncRow.spacing = 8
        func makeButton(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .regular
            actionButtons.append(b)
            return b
        }
        syncRow.addArrangedSubview(makeButton("Sync Claude", #selector(syncClaude)))
        syncRow.addArrangedSubview(makeButton("Sync OpenCode", #selector(syncOpenCode)))
        syncRow.addArrangedSubview(makeButton("Sync Both", #selector(syncBoth)))
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.widthAnchor.constraint(equalToConstant: 18).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 18).isActive = true
        syncRow.addArrangedSubview(spinner)

        // Row 2 — export
        let exportRow = NSStackView()
        exportRow.orientation = .horizontal
        exportRow.spacing = 8
        toolPopup = NSPopUpButton()
        toolPopup.addItems(withTitles: ["claude", "opencode"])
        toolPopup.target = self
        toolPopup.action = #selector(reloadProjects)
        toolPopup.widthAnchor.constraint(equalToConstant: 110).isActive = true

        projectPopup = NSPopUpButton()
        projectPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        projectPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let exportButton = makeButton("Export Selected", #selector(exportSelected))
        exportRow.addArrangedSubview(toolPopup)
        exportRow.addArrangedSubview(projectPopup)
        exportRow.addArrangedSubview(exportButton)

        // Output pane
        let label = NSTextField(labelWithString: "Output")
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        output = NSTextView()
        output.isEditable = false
        output.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        output.textContainerInset = NSSize(width: 8, height: 8)
        output.string = "Ready."
        scroll.documentView = output
        output.minSize = NSSize(width: 0, height: 0)
        output.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        output.isVerticallyResizable = true
        output.isHorizontallyResizable = false
        output.autoresizingMask = [.width]
        output.textContainer?.widthTracksTextView = true

        root.addArrangedSubview(syncRow)
        root.addArrangedSubview(exportRow)
        root.addArrangedSubview(label)
        root.addArrangedSubview(scroll)

        window.contentView = NSView()
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        [syncRow, exportRow, label].forEach {
            $0.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32).isActive = true
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        reloadProjects()
    }

    func setBusy(_ busy: Bool) {
        actionButtons.forEach { $0.isEnabled = !busy }
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    func log(_ s: String) {
        output.string = s
        setBusy(false)
    }

    @objc func syncClaude()   { setBusy(true); log_placeholder(); call("/api/sync?tool=claude", method: "POST", done: log) }
    @objc func syncOpenCode() { setBusy(true); log_placeholder(); call("/api/sync?tool=opencode", method: "POST", done: log) }
    @objc func syncBoth()     { setBusy(true); log_placeholder(); call("/api/sync?tool=both", method: "POST", done: log) }
    func log_placeholder() { output.string = "Running…" }

    @objc func reloadProjects() {
        let tool = toolPopup.titleOfSelectedItem ?? "claude"
        call("/api/projects?tool=\(tool)") { text in
            guard let data = text.data(using: .utf8),
                  let items = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
            else { return }
            self.projectPopup.removeAllItems()
            self.projectPopup.addItems(withTitles: items.compactMap { $0["name"] })
            self.projectKeys = items.compactMap { $0["key"] }
        }
    }

    @objc func exportSelected() {
        let tool = toolPopup.titleOfSelectedItem ?? "claude"
        let idx = projectPopup.indexOfSelectedItem
        guard idx >= 0, idx < projectKeys.count else { return }
        let key = projectKeys[idx].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        setBusy(true)
        log_placeholder()
        call("/api/export?tool=\(tool)&key=\(key)", method: "POST", done: log)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
