import AppKit
import Foundation

/// The AI apps Editroom can connect to with one click.
enum AgentApp: String, CaseIterable, Identifiable {
    case claude, chatgpt, claudeCode
    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .chatgpt: "ChatGPT"
        case .claudeCode: "Claude Code"
        }
    }

    /// The name the app's cursor uses in the timeline.
    var cursorName: String {
        switch self {
        case .claude, .claudeCode: "Claude"
        case .chatgpt: "Codex"
        }
    }

    var download: URL? {
        switch self {
        case .claude: URL(string: "https://claude.ai/download")
        case .chatgpt: URL(string: "https://chatgpt.com/download")
        case .claudeCode: nil
        }
    }
}

/// Adds Editroom to the Claude app, ChatGPT's Codex and Claude Code, and takes it out again.
///
/// - Claude: Editroom makes a Claude extension (an .mcpb file) and opens it in Claude, which asks the
///   person to install it.
/// - ChatGPT: adds an `[mcp_servers.editroom]` section to Codex's settings (~/.codex/config.toml),
///   used by Codex in the ChatGPT app.
/// - Claude Code: runs `claude mcp add` for this user.
///
/// Every route starts Editroom's own connection program, `Editroom --mcp` (see MCPBridge).
@MainActor
final class AgentConnect: ObservableObject {
    static let shared = AgentConnect()

    enum State: Equatable {
        case missing        // the app isn't on this Mac
        case ready          // can connect
        case waiting        // Claude's install box is open
        case connected
        case working
        case failed(String)
    }

    @Published private(set) var states: [AgentApp: State] = [:]

    /// Where settings live. Self-tests point this at a throwaway folder.
    var home = FileManager.default.homeDirectoryForCurrentUser
    /// Self-tests make the Claude extension without opening it.
    var openInClaude = true

    static let claudeBundleID = "com.anthropic.claudefordesktop"
    static let chatgptBundleIDs = ["com.openai.codex", "com.openai.chat"]
    static let editroomBundleID = Bundle.main.bundleIdentifier ?? "com.wonderassembly.Editroom"

    private var watch: Timer?

    // MARK: Status

    func refresh() {
        followMove()
        for app in AgentApp.allCases {
            if case .working = states[app] { continue }
            states[app] = status(of: app)
        }
    }

    private func status(of app: AgentApp) -> State {
        switch app {
        case .claude:
            if claudeExtensionInstalled, !claudeAppOff { return .connected }
            if case .waiting = states[app] { return .waiting }
            return Self.appURL(Self.claudeBundleID) == nil ? .missing : .ready
        case .chatgpt:
            if codexConnected { return .connected }
            let installed = Self.chatgptBundleIDs.contains { Self.appURL($0) != nil }
                || FileManager.default.fileExists(atPath: codexHome.path)
            return installed ? .ready : .missing
        case .claudeCode:
            if claudeCodeConnected { return .connected }
            return claudeCLI == nil ? .missing : .ready
        }
    }

    static func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    /// Disconnected in Editroom: the Claude app's extension may still be installed, but Editroom
    /// won't answer it (or use Claude for Magic through it) until it's connected again.
    var claudeAppOff: Bool {
        get { UserDefaults.standard.bool(forKey: "claudeAppDisconnected") }
        set { UserDefaults.standard.set(newValue, forKey: "claudeAppDisconnected") }
    }

    // MARK: Connect

    func connect(_ app: AgentApp) {
        states[app] = .working
        Task {
            do {
                switch app {
                case .claude:
                    claudeAppOff = false
                    // Installed already (and only turned off here): nothing more to do.
                    if !claudeExtensionInstalled { try connectClaude() }
                case .chatgpt: try connectCodex()
                case .claudeCode: try await runClaudeCLI(["mcp", "add", "--scope", "user", "--transport", "http", "editroom", MCPServer.endpoint])
                }
                if app == .claude, openInClaude, !claudeExtensionInstalled {
                    states[app] = .waiting
                    watchForClaude()
                } else {
                    states[app] = status(of: app)
                }
            } catch {
                states[app] = .failed((error as? ConnectError)?.message ?? error.localizedDescription)
            }
        }
    }

    func disconnect(_ app: AgentApp) {
        states[app] = .working
        Task {
            do {
                switch app {
                case .claude:
                    // Claude keeps its own list of extensions; Editroom stops answering this one.
                    claudeAppOff = true
                case .chatgpt: try disconnectCodex()
                case .claudeCode: try await runClaudeCLI(["mcp", "remove", "--scope", "user", "editroom"])
                }
                states[app] = status(of: app)
            } catch {
                states[app] = .failed((error as? ConnectError)?.message ?? error.localizedDescription)
            }
        }
    }

    /// Stops waiting for the person to click Install in Claude.
    func cancelWaiting() {
        watch?.invalidate()
        watch = nil
        if case .waiting = states[.claude] { states[.claude] = nil }
        states[.claude] = status(of: .claude)
    }

    /// Opens the Claude extension in Claude again (if its install box was closed).
    func reopenClaude() {
        let file = supportFolder.appendingPathComponent("Editroom.mcpb")
        guard let claude = Self.appURL(Self.claudeBundleID), FileManager.default.fileExists(atPath: file.path) else { return connect(.claude) }
        NSWorkspace.shared.open([file], withApplicationAt: claude, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Notices when the person clicks Install in Claude.
    private func watchForClaude() {
        watch?.invalidate()
        let started = Date()
        watch = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return t.invalidate() }
                if self.claudeExtensionInstalled || Date().timeIntervalSince(started) > 300 {
                    t.invalidate()
                    if case .waiting = self.states[.claude] { self.states[.claude] = nil }
                    self.states[.claude] = self.status(of: .claude)
                }
            }
        }
    }

    struct ConnectError: Error { let message: String }

    // MARK: The program each app starts

    private var supportFolder: URL {
        home.appendingPathComponent("Library/Application Support/Editroom/Agents", isDirectory: true)
    }

    /// A small script that starts Editroom's connection program, finding Editroom even if it has moved.
    /// `from` tells Editroom which app is calling (so a disconnected one can be turned away).
    static func launcherScript(from: String = "") -> String {
        let binary = Bundle.main.executableURL?.path ?? "/Applications/Editroom.app/Contents/MacOS/Editroom"
        return """
        #!/bin/sh
        # Starts Editroom's connection for AI apps (Claude, ChatGPT's Codex).
        app=\(shellQuote(binary))
        if [ ! -x "$app" ]; then
          # Only a copy installed in an Applications folder, never one sitting in Downloads or a disk image.
          found=$(/usr/bin/mdfind 'kMDItemCFBundleIdentifier == "\(editroomBundleID)"' | /usr/bin/grep -E "^(/Applications|$HOME/Applications)/" | /usr/bin/head -n 1)
          [ -n "$found" ] && app="$found/Contents/MacOS/Editroom"
        fi
        [ -x "$app" ] || app="/Applications/Editroom.app/Contents/MacOS/Editroom"
        exec "$app" --mcp\(from.isEmpty ? "" : " --from \(from)")

        """
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Writes the launcher (refreshed every time, in case Editroom moved) and returns its path.
    private func writeLauncher(in folder: URL, from: String = "") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("editroom-mcp")
        try Self.launcherScript(from: from).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private static var followed = false

    /// Editroom moved, or a new copy runs from somewhere else: the launchers the AI apps already have
    /// are pointed at this copy (once a launch), so they don't go on starting an old one.
    private func followMove() {
        guard !Self.followed, !CommandLine.arguments.contains("--selftest") else { return }
        Self.followed = true
        let fm = FileManager.default
        var launchers = [(supportFolder.appendingPathComponent("editroom-mcp"), "codex")]
        let extensions = claudeSupport.appendingPathComponent("Claude Extensions", isDirectory: true)
        for item in (try? fm.contentsOfDirectory(at: extensions, includingPropertiesForKeys: nil)) ?? [] {
            if let data = try? Data(contentsOf: item.appendingPathComponent("manifest.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["name"] as? String == "editroom" {
                launchers.append((item.appendingPathComponent("server/editroom-mcp"), "claude-app"))
            }
        }
        for (url, from) in launchers {
            guard let now = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let want = Self.launcherScript(from: from)
            guard now != want else { continue }
            try? want.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    // MARK: Claude (an extension)

    private var claudeSupport: URL { home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true) }

    var claudeExtensionInstalled: Bool {
        let fm = FileManager.default
        let dir = claudeSupport.appendingPathComponent("Claude Extensions", isDirectory: true)
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let manifest = item.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifest),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["name"] as? String == "editroom" { return true }
        }
        // Set up by hand in Claude's settings file.
        let config = claudeSupport.appendingPathComponent("claude_desktop_config.json")
        if let data = try? Data(contentsOf: config),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (json["mcpServers"] as? [String: Any])?["editroom"] != nil { return true }
        return false
    }

    /// The extension file: a zip holding manifest.json, an icon and the launcher.
    @discardableResult
    func makeClaudeExtension() throws -> URL {
        let fm = FileManager.default
        let stage = supportFolder.appendingPathComponent("claude-extension", isDirectory: true)
        try? fm.removeItem(at: stage)
        try fm.createDirectory(at: stage.appendingPathComponent("server"), withIntermediateDirectories: true)
        _ = try writeLauncher(in: stage.appendingPathComponent("server"), from: "claude-app")

        if let tiff = NSApp?.applicationIconImage?.tiffRepresentation(using: .none, factor: 1),
           let rep = NSBitmapImageRep(data: tiff),
           let png = Self.resized(rep, to: 256).representation(using: .png, properties: [:]) {
            try png.write(to: stage.appendingPathComponent("icon.png"))
        }
        let tools = MCPTools.definitions.compactMap { d -> [String: String]? in
            guard let name = d["name"] as? String else { return nil }
            let text = (d["description"] as? String ?? "").components(separatedBy: ". ").first ?? ""
            return ["name": name, "description": text.hasSuffix(".") ? text : text + "."]
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        var manifest: [String: Any] = [
            "manifest_version": "0.3",
            "name": "editroom",
            "display_name": "Editroom",
            "version": Self.semver(version),
            "description": "Edit your videos in Editroom: cut, trim, arrange, grade, add titles and music.",
            "long_description": "Lets Claude edit in Editroom, the video editor on your Mac. Claude gets its own cursor in Editroom, so you can watch every edit, and each one can be undone. Editroom opens by itself when Claude needs it.",
            "author": ["name": "Editroom"],
            "server": [
                "type": "binary",
                "entry_point": "server/editroom-mcp",
                "mcp_config": ["command": "/bin/sh", "args": ["${__dirname}/server/editroom-mcp"]],
            ],
            "tools": tools,
            "keywords": ["video", "editing", "editroom"],
            "compatibility": ["platforms": ["darwin"]],
        ]
        if fm.fileExists(atPath: stage.appendingPathComponent("icon.png").path) { manifest["icon"] = "icon.png" }
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try json.write(to: stage.appendingPathComponent("manifest.json"))

        let out = supportFolder.appendingPathComponent("Editroom.mcpb")
        try? fm.removeItem(at: out)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = stage
        zip.arguments = ["-qrX", out.path, "."]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw ConnectError(message: "Couldn't make the Claude extension.") }
        return out
    }

    private func connectClaude() throws {
        let file = try makeClaudeExtension()
        guard openInClaude else { return }
        guard let claude = Self.appURL(Self.claudeBundleID) else {
            throw ConnectError(message: "The Claude app isn't on this Mac.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: claude, configuration: config)
    }

    private static func semver(_ v: String) -> String {
        var parts = v.split(separator: ".").map(String.init).filter { Int($0) != nil }
        while parts.count < 3 { parts.append("0") }
        return parts.prefix(3).joined(separator: ".")
    }

    private static func resized(_ rep: NSBitmapImageRep, to side: Int) -> NSBitmapImageRep {
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return rep }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    // MARK: ChatGPT (Codex settings)

    var codexHome: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    private var codexConfig: URL { codexHome.appendingPathComponent("config.toml") }
    private static let codexHeader = "[mcp_servers.editroom]"

    var codexConnected: Bool {
        guard let text = try? String(contentsOf: codexConfig, encoding: .utf8) else { return false }
        return text.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces) == Self.codexHeader }
    }

    /// The config with Editroom's section (and any `[mcp_servers.editroom.*]` under it) taken out.
    /// Every other line is left exactly as it was.
    static func removingEditroom(from text: String) -> String {
        var out: [String] = []
        var skipping = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                skipping = t == codexHeader || t.hasPrefix("[mcp_servers.editroom.")
            }
            if !skipping { out.append(line) }
        }
        // Drop the blank lines left at the end.
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty { out.removeLast() }
        return out.joined(separator: "\n")
    }

    func connectCodex() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: codexHome, withIntermediateDirectories: true)
        let launcher = try writeLauncher(in: supportFolder, from: "codex")
        let existing = (try? String(contentsOf: codexConfig, encoding: .utf8)) ?? ""
        if !existing.isEmpty {
            // A copy of their settings as they were, just in case.
            let backup = codexHome.appendingPathComponent("config.toml.before-editroom")
            if !fm.fileExists(atPath: backup.path) { try existing.write(to: backup, atomically: true, encoding: .utf8) }
        }
        var text = Self.removingEditroom(from: existing)
        if !text.isEmpty { text += "\n\n" }
        text += """
        \(Self.codexHeader)
        command = "/bin/sh"
        args = [\(Self.tomlString(launcher.path))]
        startup_timeout_sec = 30
        tool_timeout_sec = 300

        """
        try text.write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    func disconnectCodex() throws {
        guard let existing = try? String(contentsOf: codexConfig, encoding: .utf8) else { return }
        try (Self.removingEditroom(from: existing) + "\n").write(to: codexConfig, atomically: true, encoding: .utf8)
    }

    static func tomlString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Claude Code

    var claudeCodeConnected: Bool {
        let file = home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (json["mcpServers"] as? [String: Any])?["editroom"] != nil
    }

    /// The `codex` program: the one the ChatGPT app ships, or one installed on its own.
    var codexCLI: URL? {
        let fm = FileManager.default
        for id in Self.chatgptBundleIDs {
            if let app = Self.appURL(id) {
                let c = app.appendingPathComponent("Contents/Resources/codex-cli/bin/codex")
                if fm.isExecutableFile(atPath: c.path) { return c }
            }
        }
        let h = home.path
        let known = ["\(h)/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        return known.first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    /// The `claude` program: on the PATH people usually have, or the one inside the Claude app.
    var claudeCLI: URL? {
        let fm = FileManager.default
        let h = home.path
        let known = ["\(h)/.local/bin/claude", "\(h)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let p = known.first(where: { fm.isExecutableFile(atPath: $0) }) { return URL(fileURLWithPath: p) }
        // The copy the Claude app keeps for its Code tab: newest version first.
        let root = URL(fileURLWithPath: "\(h)/Library/Application Support/Claude/claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in versions {
            guard let e = fm.enumerator(at: root.appendingPathComponent(v), includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in e where u.lastPathComponent == "claude" && u.path.hasSuffix("Contents/MacOS/claude") {
                if fm.isExecutableFile(atPath: u.path) { return u }
            }
        }
        return nil
    }

    private func runClaudeCLI(_ args: [String]) async throws {
        guard let cli = claudeCLI else { throw ConnectError(message: "Claude Code isn't installed.") }
        let result: (Int32, String) = await Task.detached {
            let p = Process()
            p.executableURL = cli
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do { try p.run() } catch { return (-1, error.localizedDescription) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        }.value
        guard result.0 == 0 else {
            let line = result.1.split(separator: "\n").first.map(String.init) ?? "Claude Code couldn't make the change."
            throw ConnectError(message: line)
        }
    }
}
