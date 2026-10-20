// Session Sync — native AppKit app. All export/sync logic is in-process Swift;
// no Python, no server.
import Cocoa

let home = NSHomeDirectory()

// MARK: - Config

struct Config: Codable {
    var claudeSourceDir: String
    var opencodeDB: String
    var claudeOutputDir: String
    var opencodeOutputDir: String

    static var defaultClaudeSource: String {
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] { return d + "/projects" }
        let xdg = home + "/.config/claude/projects"
        return FileManager.default.fileExists(atPath: xdg) ? xdg : home + "/.claude/projects"
    }

    static var defaults: Config {
        Config(claudeSourceDir: defaultClaudeSource,
               opencodeDB: home + "/.local/share/opencode/opencode.db",
               claudeOutputDir: home + "/AI Sessions/Claude Sessions",
               opencodeOutputDir: home + "/AI Sessions/Opencode Sessions")
    }

    static var path: String { home + "/Library/Application Support/SessionSync/config.json" }

    static func load() -> Config? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    func save() {
        try? FileManager.default.createDirectory(atPath: (Config.path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) { FileManager.default.createFile(atPath: Config.path, contents: data) }
    }

    func claude(_ log: @escaping Log) -> ClaudeExporter {
        ClaudeExporter(projectsDir: URL(fileURLWithPath: claudeSourceDir),
                       outputDir: URL(fileURLWithPath: claudeOutputDir), log: log)
    }

    func opencode(_ log: @escaping Log) -> OpenCodeExporter {
        OpenCodeExporter(dbPath: opencodeDB, outputDir: URL(fileURLWithPath: opencodeOutputDir), log: log)
    }
}

extension Config {
    // Older config files may lack newer keys; fill them from defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaults
        claudeSourceDir = try c.decodeIfPresent(String.self, forKey: .claudeSourceDir) ?? d.claudeSourceDir
        opencodeDB = try c.decodeIfPresent(String.self, forKey: .opencodeDB) ?? d.opencodeDB
        claudeOutputDir = try c.decodeIfPresent(String.self, forKey: .claudeOutputDir) ?? d.claudeOutputDir
        opencodeOutputDir = try c.decodeIfPresent(String.self, forKey: .opencodeOutputDir) ?? d.opencodeOutputDir
    }
}

// MARK: - Setup window (first-run onboarding and Settings)

final class SetupWindowController: NSObject {
    let window: NSWindow
    private var fields: [NSTextField] = []
    private let onDone: (Config) -> Void

    private struct Row { let label: String; let pickFile: Bool; let canCreate: Bool }
    private let rows = [
        Row(label: "Claude Code data", pickFile: false, canCreate: false),
        Row(label: "OpenCode database", pickFile: true, canCreate: false),
        Row(label: "Claude archive", pickFile: false, canCreate: true),
        Row(label: "OpenCode archive", pickFile: false, canCreate: true),
    ]

    init(config: Config, firstRun: Bool, onDone: @escaping (Config) -> Void) {
        self.onDone = onDone
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = firstRun ? "Welcome to Session Sync" : "Settings"
        window.isReleasedWhenClosed = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        if firstRun {
            let title = NSTextField(labelWithString: "Set up where your sessions come from and where they go")
            title.font = .boldSystemFont(ofSize: 14)
            root.addArrangedSubview(title)
            let sub = NSTextField(wrappingLabelWithString:
                "Sources are detected automatically. Archives are where exported Markdown is written. You can change all of this later in Settings (⌘,).")
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            sub.widthAnchor.constraint(equalToConstant: 600).isActive = true
            root.addArrangedSubview(sub)
            root.setCustomSpacing(16, after: sub)
        }

        let values = [config.claudeSourceDir, config.opencodeDB, config.claudeOutputDir, config.opencodeOutputDir]
        for (i, r) in rows.enumerated() {
            if i == 0 { root.addArrangedSubview(sectionLabel("Sources")) }
            if i == 2 {
                root.setCustomSpacing(16, after: root.arrangedSubviews.last!)
                root.addArrangedSubview(sectionLabel("Archives"))
            }
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let label = NSTextField(labelWithString: r.label)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 130).isActive = true
            let field = NSTextField(labelWithString: values[i])
            field.lineBreakMode = .byTruncatingMiddle
            field.toolTip = values[i]
            field.isSelectable = true
            field.setContentHuggingPriority(.defaultLow, for: .horizontal)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let button = NSButton(title: "Choose…", target: self, action: #selector(choose(_:)))
            button.bezelStyle = .rounded
            button.tag = i
            row.addArrangedSubview(label)
            row.addArrangedSubview(field)
            row.addArrangedSubview(button)
            row.widthAnchor.constraint(equalToConstant: 600).isActive = true
            fields.append(field)
            root.addArrangedSubview(row)
        }

        let done = NSButton(title: firstRun ? "Get Started" : "Save", target: self, action: #selector(finish))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), done])
        buttons.widthAnchor.constraint(equalToConstant: 600).isActive = true
        root.setCustomSpacing(20, after: root.arrangedSubviews.last!)
        root.addArrangedSubview(buttons)

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.setContentSize(root.fittingSize)
        window.center()
    }

    private func sectionLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    @objc private func choose(_ sender: NSButton) {
        let r = rows[sender.tag]
        let current = fields[sender.tag].stringValue
        let panel = NSOpenPanel()
        panel.canChooseFiles = r.pickFile
        panel.canChooseDirectories = !r.pickFile
        panel.canCreateDirectories = r.canCreate
        panel.showsHiddenFiles = true  // sources live under ~/.config, ~/.claude, ~/.local
        panel.prompt = "Select"
        panel.directoryURL = URL(fileURLWithPath: r.pickFile ? (current as NSString).deletingLastPathComponent : current)
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let field = self?.fields[sender.tag] else { return }
            field.stringValue = url.path
            field.toolTip = url.path
        }
    }

    @objc private func finish() {
        let v = fields.map(\.stringValue)
        let config = Config(claudeSourceDir: v[0], opencodeDB: v[1], claudeOutputDir: v[2], opencodeOutputDir: v[3])
        config.save()
        window.close()
        onDone(config)
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Main window

final class AppDelegate: NSObject, NSApplicationDelegate {
    var config = Config.defaults
    var window: NSWindow?
    var setup: SetupWindowController?

    var toolPopup: NSPopUpButton!
    var projectPopup: NSPopUpButton!
    var nameField: NSTextField!
    var output: NSTextView!
    var spinner: NSProgressIndicator!
    var actionButtons: [NSButton] = []
    var projectKeys: [String] = []
    var busy = false

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        if let saved = Config.load() {
            config = saved
            showMainWindow()
        } else {
            setup = SetupWindowController(config: .defaults, firstRun: true) { [weak self] cfg in
                self?.config = cfg
                self?.showMainWindow()
            }
            setup?.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Session Sync", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Session Sync", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Session Sync", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }

    @objc func openSettings() {
        setup = SetupWindowController(config: config, firstRun: false) { [weak self] cfg in
            self?.config = cfg
            self?.reloadProjects()
        }
        setup?.show()
    }

    func showMainWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Session Sync"
        w.minSize = NSSize(width: 620, height: 380)
        w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("MainWindow")

        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            actionButtons.append(b)
            return b
        }
        func caption(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 11, weight: .medium)
            l.textColor = .secondaryLabelColor
            return l
        }

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let syncRow = NSStackView(views: [
            button("Sync Claude", #selector(syncClaude)),
            button("Sync OpenCode", #selector(syncOpenCode)),
            button("Sync Both", #selector(syncBoth)),
            spinner,
        ])
        syncRow.spacing = 8

        toolPopup = NSPopUpButton()
        toolPopup.addItems(withTitles: ["Claude Code", "OpenCode"])
        toolPopup.target = self
        toolPopup.action = #selector(reloadProjects)
        projectPopup = NSPopUpButton()
        projectPopup.target = self
        projectPopup.action = #selector(projectChanged)
        projectPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        projectPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField = NSTextField()
        nameField.placeholderString = "archive folder"
        nameField.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let exportRow = NSStackView(views: [toolPopup, projectPopup, caption("as"), nameField,
                                            button("Export All Sessions", #selector(exportSelected))])
        exportRow.spacing = 8

        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        output = (scroll.documentView as! NSTextView)
        output.isEditable = false
        output.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        output.textContainerInset = NSSize(width: 8, height: 8)

        let root = NSStackView(views: [caption("Refresh everything already archived"), syncRow,
                                       caption("Export a project's sessions"), exportRow,
                                       caption("Output"), scroll])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.setCustomSpacing(18, after: syncRow)
        root.setCustomSpacing(18, after: exportRow)
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            exportRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
        ])
        w.contentView = content
        if !w.setFrameUsingName("MainWindow") { w.center() }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
        append("Ready.\n")
        reloadProjects()
    }

    var isClaude: Bool { toolPopup.indexOfSelectedItem == 0 }

    @objc func reloadProjects() {
        guard toolPopup != nil else { return }
        let cfg = config
        let claude = isClaude
        DispatchQueue.global(qos: .userInitiated).async {
            let items: [(String, String)] = claude
                ? cfg.claude({ _ in }).projects().map { ($0, $0) }
                : cfg.opencode({ _ in }).projects()
            DispatchQueue.main.async {
                self.projectKeys = items.map(\.0)
                self.projectPopup.removeAllItems()
                self.projectPopup.addItems(withTitles: items.map(\.1))
                if items.isEmpty {
                    self.projectPopup.addItem(withTitle: "No projects found")
                    self.projectPopup.isEnabled = false
                } else {
                    self.projectPopup.isEnabled = true
                }
                self.projectChanged()
            }
        }
    }

    @objc func projectChanged() {
        let idx = projectPopup.indexOfSelectedItem
        guard idx >= 0, idx < projectKeys.count else { nameField.stringValue = ""; return }
        let key = projectKeys[idx]
        let cfg = config
        let claude = isClaude
        DispatchQueue.global(qos: .userInitiated).async {
            let name = claude
                ? cfg.claude({ _ in }).suggestedName(for: key) ?? key
                : slugify((key as NSString).lastPathComponent)
            DispatchQueue.main.async {
                if self.projectPopup.indexOfSelectedItem == idx { self.nameField.stringValue = name }
            }
        }
    }

    func append(_ s: String) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.textColor,
        ]
        output.textStorage?.append(NSAttributedString(string: s, attributes: attrs))
        output.scrollToEndOfDocument(nil)
    }

    func run(_ work: @escaping (Config, @escaping Log) -> Void) {
        guard !busy else { return }
        busy = true
        actionButtons.forEach { $0.isEnabled = false }
        spinner.startAnimation(nil)
        output.string = ""
        let cfg = config
        let log: Log = { line in DispatchQueue.main.async { self.append(line + "\n") } }
        DispatchQueue.global(qos: .userInitiated).async {
            work(cfg, log)
            DispatchQueue.main.async {
                self.busy = false
                self.actionButtons.forEach { $0.isEnabled = true }
                self.spinner.stopAnimation(nil)
            }
        }
    }

    @objc func syncClaude() { run { cfg, log in log("=== Claude sync ==="); cfg.claude(log).sync() } }
    @objc func syncOpenCode() { run { cfg, log in log("=== OpenCode sync ==="); cfg.opencode(log).sync() } }
    @objc func syncBoth() {
        run { cfg, log in
            log("=== Claude sync ===")
            cfg.claude(log).sync()
            log("=== OpenCode sync ===")
            cfg.opencode(log).sync()
        }
    }

    @objc func exportSelected() {
        let idx = projectPopup.indexOfSelectedItem
        guard idx >= 0, idx < projectKeys.count else { return }
        let key = projectKeys[idx]
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", !name.hasPrefix(".") else {
            NSSound.beep()
            output.string = ""
            append("Choose a valid archive folder name (no slashes, not starting with a dot).\n")
            return
        }
        let claude = isClaude
        run { cfg, log in
            if claude { cfg.claude(log).export(key: key, project: name) }
            else { cfg.opencode(log).export(worktree: key, project: name) }
        }
    }
}

// MARK: - CLI (used for parity tests against the original Python exporters)

func runCLI(_ a: [String]) -> Int32 {
    let env = ProcessInfo.processInfo.environment
    let claudeSrc = URL(fileURLWithPath: env["CLAUDE_PROJECTS_DIR"] ?? Config.defaultClaudeSource)
    let db = env["OPENCODE_DB"] ?? Config.defaults.opencodeDB
    let log: Log = { print($0) }
    switch (a.first ?? "", a.count) {
    case ("claude-export", 4):
        ClaudeExporter(projectsDir: claudeSrc, outputDir: URL(fileURLWithPath: a[3]), log: log).export(key: a[1], project: a[2])
    case ("claude-sync", 2):
        ClaudeExporter(projectsDir: claudeSrc, outputDir: URL(fileURLWithPath: a[1]), log: log).sync()
    case ("opencode-export", 4):
        OpenCodeExporter(dbPath: db, outputDir: URL(fileURLWithPath: a[3]), log: log).export(worktree: a[1], project: a[2])
    case ("opencode-sync", 2):
        OpenCodeExporter(dbPath: db, outputDir: URL(fileURLWithPath: a[1]), log: log).sync()
    default:
        print("usage: --cli claude-export KEY NAME OUT | claude-sync OUT | opencode-export WORKTREE NAME OUT | opencode-sync OUT")
        return 2
    }
    return 0
}

if let i = CommandLine.arguments.firstIndex(of: "--cli") {
    exit(runCLI(Array(CommandLine.arguments[(i + 1)...])))
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
