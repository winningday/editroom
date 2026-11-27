import AppKit
import SwiftUI

/// Editroom > Settings… (⌘,): keyboard shortcuts, and Magic (on or off, and the AI apps it can use).
struct SettingsView: View {
    @ObservedObject var model: EditorModel

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General", shortcuts = "Shortcuts", magic = "Magic", updates = "Updates"
        var id: Self { self }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .shortcuts: "keyboard"
            case .magic: "wand.and.sparkles"
            case .updates: "arrow.down.circle"
            }
        }
        /// The tab's name kept in UserDefaults ("general", "shortcuts", "magic", "updates").
        var key: String { rawValue.lowercased() }
    }

    @AppStorage("settingsTab") private var tabKey = "shortcuts"
    @State private var hovered: Tab?
    /// A new theme rebuilds these views, so every colour is read again.
    @ObservedObject private var themes = ThemeStore.shared
    /// General was called Appearance, and may still be the tab kept from then.
    private var tab: Tab { tabKey == "appearance" ? .general : Tab.allCases.first { $0.key == tabKey } ?? .shortcuts }

    var body: some View {
        VStack(spacing: 0) {
            // Our own tab row, like a Mac app's Settings toolbar: icon over name, a soft backing on the
            // chosen one (the native toolbar would draw it in the system accent colour).
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { tabButton($0) }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            Divider().overlay(Theme.stroke)

            VStack(alignment: .leading, spacing: 0) {
                Text(tab.rawValue)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 4)
                switch tab {
                case .general: GeneralSettings()
                case .shortcuts: ShortcutSettings()
                case .magic: MagicSettings(model: model)
                case .updates: UpdateSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .id(themes.look)
        .frame(width: 600, height: 640)
        .background(Theme.panel)
        .navigationTitle("Settings")
        .preferredColorScheme(Theme.scheme)
    }

    private func tabButton(_ item: Tab) -> some View {
        let selected = tab == item
        return Button { tabKey = item.key } label: {
            VStack(spacing: 3) {
                Image(systemName: item.symbol).font(.system(size: 20)).frame(width: 28, height: 26)
                Text(item.rawValue).font(.system(size: 13))
            }
            .foregroundStyle(selected ? Theme.text : Theme.textDim)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.ink.opacity(selected ? 0.1 : hovered == item ? 0.05 : 0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? item : (hovered == item ? nil : hovered) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.label()).kerning(1.4).foregroundStyle(Theme.textFaint)
    }
}

// MARK: General

/// The themes, each shown as a small picture of the editor in its colours; how media and times are shown;
/// and whether projects save themselves.
private struct GeneralSettings: View {
    @ObservedObject var themes = ThemeStore.shared
    @AppStorage(MediaLayout.key) private var mediaLayout = MediaLayout.thumbnails
    @AppStorage(EditorModel.autosaveKey) private var autosave = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Theme") {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(AppTheme.allCases) { theme in
                        ThemeChoice(theme: theme, selected: themes.theme == theme) { themes.theme = theme }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            SettingsSection("View") {
                SettingsRow("Media") {
                    SegmentedChoice(options: MediaLayout.allCases.map { ($0, $0.name) }, selection: $mediaLayout)
                }
                Divider().overlay(Theme.stroke)
                SettingsRow("Show time as") {
                    SegmentedChoice(options: [(TimeStyle.timecode, "00:00:05:15"), (TimeStyle.simple, "0:05.50")],
                                    selection: $themes.timeStyle, mono: true)
                }
            }
            SettingsSection("Saving") {
                SettingsRow("Auto-save", detail: autosave ? "Saved projects save themselves as you edit."
                                                          : "Projects change only when you save (⌘S).") {
                    Toggle("", isOn: $autosave)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                        .tint(Theme.accent)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 22)
    }
}

/// A small grey label over a rounded box of settings, like the inspector's section names.
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(Theme.label())
                .kerning(1.5)
                .foregroundStyle(Theme.textFaint)
                .padding(.leading, 2)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
        }
    }
}

/// One setting: its name (and a line on what it does) on the left, its control on the right.
private struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textDim) }
            }
            Spacer(minLength: 0)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// A segmented switch in Editroom's own greys (the system one is drawn in the system's colours).
private struct SegmentedChoice<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    var mono = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, name in
                Button { selection = value } label: {
                    Text(name)
                        .font(mono ? Theme.mono(11.5) : .system(size: 12))
                        .foregroundStyle(selection == value ? Theme.text : Theme.textDim)
                        .padding(.horizontal, 11)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selection == value ? Theme.ink.opacity(0.16) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink.opacity(0.06)))
        .fixedSize()
    }
}

private struct ThemeChoice: View {
    let theme: AppTheme
    let selected: Bool
    let pick: () -> Void
    @State private var hovering = false

    /// Auto: Light on the left, Dark on the right.
    @ViewBuilder private var preview: some View {
        if theme == .auto {
            ZStack {
                ThemePreview(palette: AppTheme.light.palette)
                ThemePreview(palette: AppTheme.dark.palette).mask(RightHalf())
            }
        } else {
            ThemePreview(palette: theme.palette)
        }
    }

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 7) {
                preview
                    .frame(height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.ink.opacity(0.12), lineWidth: 1))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Theme.accent : (hovering ? Theme.ink.opacity(0.25) : .clear), lineWidth: 2))
                Text(theme.name)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.textDim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The right half of a box: Auto's Dark half.
private struct RightHalf: Shape {
    func path(in r: CGRect) -> Path {
        Path(CGRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height))
    }
}

/// The editor in miniature, in a theme's colours: Media, viewer and inspector over the timeline.
private struct ThemePreview: View {
    let palette: Palette

    private func c(_ hex: UInt32, _ a: Double = 1) -> Color { Color(hex: hex, alpha: a) }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let top = h * 0.11, split = h * 0.56
            ZStack(alignment: .topLeading) {
                c(palette.bg)
                // Title bar, with the Export pill.
                c(palette.panel).frame(width: w, height: top)
                Capsule().fill(c(palette.text)).frame(width: w * 0.12, height: top * 0.5)
                    .offset(x: w * 0.84, y: top * 0.25)
                // Media, with a few items.
                c(palette.panel).frame(width: w * 0.22, height: split - top).offset(y: top)
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 1.5).fill(c(palette.video))
                        .frame(width: w * 0.08, height: h * 0.07)
                        .offset(x: w * 0.025, y: top + h * 0.06 + CGFloat(i) * h * 0.11)
                    Capsule().fill(c(palette.textDim, 0.7)).frame(width: w * 0.08, height: 2)
                        .offset(x: w * 0.12, y: top + h * 0.085 + CGFloat(i) * h * 0.11)
                }
                // The viewer: black, in every theme.
                Color.black.frame(width: w * 0.42, height: split - top - h * 0.12)
                    .offset(x: w * 0.29, y: top + h * 0.05)
                Circle().fill(c(palette.text)).frame(width: h * 0.05, height: h * 0.05)
                    .offset(x: w * 0.5 - h * 0.025, y: split - h * 0.065)
                // Inspector.
                c(palette.panel).frame(width: w * 0.22, height: split - top).offset(x: w * 0.78, y: top)
                ForEach(0..<3) { i in
                    Capsule().fill(c(palette.ink, 0.12)).frame(width: w * 0.16, height: 2)
                        .offset(x: w * 0.81, y: top + h * 0.08 + CGFloat(i) * h * 0.09)
                }
                // Timeline: ruler, lanes and clips, and the playhead.
                c(palette.panel).frame(width: w, height: h * 0.07).offset(y: split)
                ForEach(0..<3) { i in
                    c(palette.lane).frame(width: w, height: h * 0.1).offset(y: split + h * 0.09 + CGFloat(i) * h * 0.12)
                }
                ForEach(Array([(0.04, 0.2), (0.25, 0.28), (0.54, 0.16)].enumerated()), id: \.offset) { _, clip in
                    RoundedRectangle(cornerRadius: 2).fill(c(palette.video))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(c(palette.clipStroke)))
                        .frame(width: w * clip.1, height: h * 0.1)
                        .offset(x: w * clip.0, y: split + h * 0.09)
                    RoundedRectangle(cornerRadius: 2).fill(c(palette.audio))
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(c(palette.clipStroke)))
                        .frame(width: w * clip.1, height: h * 0.1)
                        .offset(x: w * clip.0, y: split + h * 0.21)
                }
                RoundedRectangle(cornerRadius: 2).fill(c(palette.audio))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(c(palette.clipStroke)))
                    .frame(width: w * 0.66, height: h * 0.1)
                    .offset(x: w * 0.04, y: split + h * 0.33)
                c(palette.accent).frame(width: 1.5, height: h - split).offset(x: w * 0.36, y: split)
            }
        }
    }
}

// MARK: Shortcuts

/// Listens for the next key press while a shortcut is being changed.
@MainActor
private final class ShortcutRecorder: ObservableObject {
    @Published var note: String?
    private var monitor: Any?
    private var noteTimer: Timer?

    func start(_ action: ShortcutAction) {
        stop()
        ShortcutStore.shared.recording = action
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, let action = ShortcutStore.shared.recording else { return e }
                // Escape cancels.
                if let combo = KeyCombo(event: e) {
                    if let taken = ShortcutStore.shared.set(action, to: combo) {
                        self.show("\(combo.display) was \(taken.title)'s shortcut, so \(taken.title) no longer has it.")
                    }
                }
                self.stop()
                return nil
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        ShortcutStore.shared.recording = nil
    }

    private func show(_ s: String) {
        note = s
        noteTimer?.invalidate()
        noteTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.note = nil }
        }
    }
}

private struct ShortcutSettings: View {
    @ObservedObject var keys = ShortcutStore.shared
    @StateObject private var recorder = ShortcutRecorder()
    @State private var search = ""

    /// The skimming choice under Play / Pause shows with it, and for searches about skimming.
    private var showsSkim: Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return matches(.playPause) || (!q.isEmpty && ["skim", "playhead", "space"].contains { $0.hasPrefix(q) || q.hasPrefix($0) })
    }

    private func matches(_ a: ShortcutAction) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return a.title.lowercased().contains(q) || keys.combos(a).contains { $0.display.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                TextField("Search shortcuts", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.field))
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(ShortcutAction.Group.allCases, id: \.self) { group in
                        let actions = ShortcutAction.allCases.filter { $0.group == group && matches($0) }
                        let skim = group == .playback && showsSkim
                        if !actions.isEmpty || skim {
                            VStack(alignment: .leading, spacing: 4) {
                                SectionLabel(text: group.rawValue).padding(.leading, 10)
                                VStack(spacing: 0) {
                                    if skim && !actions.contains(.playPause) { SkimPlayRow() }
                                    ForEach(actions) { a in
                                        ShortcutRow(action: a, keys: keys, recorder: recorder)
                                        if a == .playPause, skim { SkimPlayRow() }
                                    }
                                }
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
            }

            Divider().overlay(Theme.stroke)
            HStack {
                Text(recorder.note ?? (keys.recording != nil ? "Press the new shortcut, or Esc to cancel." : "Click a shortcut to change it. Right-click for more."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(recorder.note != nil ? Theme.text : Theme.textDim)
                    .lineLimit(2)
                Spacer()
                PillButton(title: "Restore Defaults", prominent: false) {
                    recorder.stop()
                    keys.resetAll()
                }
                .disabled(keys.changed.isEmpty)
            }
            .padding(.horizontal, 24)
            .frame(height: 52)
        }
        .onDisappear { recorder.stop() }
    }
}

/// Under Play / Pause: where space plays from while skimming.
private struct SkimPlayRow: View {
    @AppStorage(EditorModel.playFromSkimmerKey) private var fromSkimmer = true

    var body: some View {
        HStack(spacing: 8) {
            Text("↳  While skimming, play from")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
            Spacer()
            SegmentedChoice(options: [(false, "Playhead"), (true, "Skimmer")], selection: $fromSkimmer)
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .frame(height: 34)
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    @ObservedObject var keys: ShortcutStore
    @ObservedObject var recorder: ShortcutRecorder
    @State private var hovering = false

    private var recording: Bool { keys.recording == action }

    var body: some View {
        HStack(spacing: 8) {
            Text(action.title)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
            if keys.isChanged(action) {
                Circle().fill(Theme.accent).frame(width: 5, height: 5).help("Changed from the default")
            }
            Spacer()
            if recording {
                Text("Press keys…")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(Theme.accent.opacity(0.25)))
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.8)))
            } else if keys.combos(action).isEmpty {
                Text("None").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
            } else {
                HStack(spacing: 4) {
                    ForEach(keys.combos(action), id: \.self) { KeyCap(text: $0.display) }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink.opacity(hovering || recording ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { recording ? recorder.stop() : recorder.start(action) }
        .contextMenu {
            Button("Change Shortcut") { recorder.start(action) }
            Button("Remove Shortcut") { keys.clear(action) }
                .disabled(keys.combos(action).isEmpty)
            Button("Restore Default (\(action.defaults.map(\.display).joined(separator: ", ")))") { keys.reset(action) }
                .disabled(!keys.isChanged(action))
        }
    }
}

private struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.ink.opacity(0.1)))
    }
}

// MARK: Magic

private struct MagicSettings: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var server = MCPServer.shared
    @ObservedObject var connect = AgentConnect.shared
    @AppStorage("magicEnabled") private var magicEnabled = true
    @AppStorage("magicShowWork") private var showWork = true

    /// Claude Code only when it's on this Mac.
    private var apps: [AgentApp] {
        [.claude, .chatgpt, .claudeCode].filter { $0 != .claudeCode || connect.states[$0] != .missing }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Magic")
                    VStack(spacing: 0) {
                        ToggleRow(title: "Enable Magic",
                                  note: "Magic makes an edit for you: a quick cut on this Mac, or one Claude or ChatGPT works out from what you ask. Off hides the Magic button.",
                                  isOn: $magicEnabled, boxed: false)
                        Divider().overlay(Theme.stroke)
                        ToggleRow(title: "Show Magic at work",
                                  note: "Watch the cursors make the edit. Off, the edit appears at once, as one step you can undo.",
                                  isOn: $showWork, boxed: false)
                            .disabled(!magicEnabled)
                            .opacity(magicEnabled ? 1 : 0.4)
                    }
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "AI apps")
                    VStack(spacing: 0) {
                        ForEach(Array(apps.enumerated()), id: \.element) { i, app in
                            if i > 0 { Divider().overlay(Theme.stroke).padding(.leading, 58) }
                            AppRow(app: app, state: connect.states[app] ?? .ready, connect: connect)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
                    Text("Connected apps use your own Claude or ChatGPT plan; no API key needed. Disconnecting stops Editroom answering that app, for Magic and for edits you ask for in the app.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: "Editing from other apps")
                    ToggleRow(title: "Let AI apps edit in Editroom",
                              note: server.enabled
                                ? "On: connected apps can edit here, with their own cursor, and every change can be undone. Only apps on this Mac can reach Editroom."
                                : "Off: no app can reach Editroom, and Magic only makes quick cuts on this Mac.",
                              isOn: $server.enabled)
                    OwnAgentRow(enabled: server.enabled)
                    if let problem = server.problem, server.enabled {
                        Text(problem).font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xE5735C))
                    }
                    // Only agents that have done something in the last minute.
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        let active = server.clients.values.filter { context.date.timeIntervalSince($0.lastSeen) < 60 }
                        if !active.isEmpty {
                            HStack(spacing: 10) {
                                Text("Working now:").font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                                ForEach(active.sorted { $0.lastSeen > $1.lastSeen }) { c in
                                    HStack(spacing: 5) {
                                        Circle().fill(Color(nsColor: MCPTools.color(for: c.name))).frame(width: 7, height: 7)
                                        Text(c.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .onAppear { connect.refresh() }
        // Back from Claude or ChatGPT: see what changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            connect.refresh()
        }
    }
}

/// For AI apps without a Connect button: one prompt to paste into them, which they follow to connect and start.
private struct OwnAgentRow: View {
    let enabled: Bool
    @State private var copied = false

    private var prompt: String {
        let launcher = Bundle.main.executablePath ?? "/Applications/Editroom.app/Contents/MacOS/Editroom"
        return """
        Connect to Editroom, the video editor on my Mac, and edit only through its MCP tools (never screenshots or clicks). \
        Its MCP server runs as the command "\(launcher)" with the argument --mcp (stdio; it opens Editroom when needed), \
        or at \(MCPServer.endpoint) (Streamable HTTP) while Editroom is open. Add it to your MCP settings as "editroom" \
        (or use the entry if it's already there). Until its tools appear in a new session, call the address directly. \
        Then call get_project and list_media, and follow the instructions Editroom sends when you connect.
        """
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect another AI app").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Using a different AI app? Copy this prompt and paste it in, and it connects itself and can start editing.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                // Always as wide as "Copy Prompt", so the note beside it doesn't rewrap when it says "Copied".
                ZStack {
                    Text("Copy Prompt").hidden()
                    Text(copied ? "Copied" : "Copy Prompt")
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.field))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }
}

private struct ToggleRow: View {
    let title: String
    let note: String
    @Binding var isOn: Bool
    /// In its own box; false when it shares one with other rows.
    var boxed = true

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                // Small, like the rest of Editroom's controls (the standard switch looks oversized here).
                .controlSize(.small)
                .tint(Theme.accent)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(boxed ? Theme.field : .clear))
    }
}

private struct AppRow: View {
    let app: AgentApp
    let state: AgentConnect.State
    let connect: AgentConnect

    private var icon: NSImage? {
        let id: String? = switch app {
        case .claude, .claudeCode: AgentConnect.claudeBundleID
        case .chatgpt: AgentConnect.chatgptBundleIDs.first { AgentConnect.appURL($0) != nil }
        }
        guard let id, let url = AgentConnect.appURL(id) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var note: String {
        switch (app, state) {
        case (_, .missing): "Not on this Mac."
        case (_, .working): "One moment…"
        case (_, .failed(let message)): message
        case (.claude, .ready):
            connect.claudeAppOff && connect.claudeExtensionInstalled
                ? "Disconnected. To remove Editroom from Claude too, use Claude's Settings > Extensions."
                : "Adds Editroom to the Claude app as an extension."
        case (.claude, .waiting): "Click Install in the Claude app to finish."
        case (.claude, .connected): "Connected. Claude can edit here, and Magic can use it."
        case (.chatgpt, .ready): "Adds Editroom to Codex in the ChatGPT app."
        case (.chatgpt, .connected): "Connected. ChatGPT can edit here, and Magic can use it."
        case (.claudeCode, .ready): "Adds Editroom to Claude Code for all your projects."
        case (.claudeCode, .connected): "Connected. New Claude Code sessions can edit here."
        default: ""
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let icon { Image(nsImage: icon).resizable() } else {
                    RoundedRectangle(cornerRadius: 7).fill(Theme.raised)
                }
            }
            .frame(width: 32, height: 32)
            .opacity(state == .missing ? 0.5 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isFailed ? Color(hex: 0xE5735C) : Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            button
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var isFailed: Bool { if case .failed = state { true } else { false } }

    @ViewBuilder private var button: some View {
        switch state {
        case .missing:
            if let url = app.download {
                PillButton(title: "Get \(app.title)", prominent: false) { NSWorkspace.shared.open(url) }
            }
        case .working:
            ProgressView().controlSize(.small).frame(width: 60)
        case .waiting:
            HStack(spacing: 6) {
                PillButton(title: "Cancel", prominent: false) { connect.cancelWaiting() }
                PillButton(title: "Open Claude Again", prominent: false) { connect.reopenClaude() }
            }
        case .connected:
            PillButton(title: "Disconnect", prominent: false) { connect.disconnect(app) }
        case .ready:
            PillButton(title: "Connect", prominent: true) {
                // Connecting an app means letting AI apps in.
                if !MCPServer.shared.enabled { MCPServer.shared.enabled = true }
                connect.connect(app)
            }
        case .failed:
            PillButton(title: "Try Again", prominent: true) { connect.connect(app) }
        }
    }
}

// MARK: Updates

/// Which version this is. This build never checks for or installs updates by itself: a new version only
/// arrives when someone rebuilds it from the repository, so what runs on this Mac is always what was chosen.
private struct UpdateSettings: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }
    private var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(title: "Software Update") {
                    VStack(alignment: .leading, spacing: 12) {
                        Row(name: "Installed version", value: "\(version) (\(build))")
                        Divider().overlay(Theme.stroke)
                        Text("Automatic updates are off in this build. Editroom never downloads or installs a new version by itself. To update, rebuild it from your copy of the code in Xcode.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
    }

    private struct Card<Content: View>: View {
        let title: String
        @ViewBuilder let content: Content
        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.field))
        }
    }

    private struct Row: View {
        let name: String
        let value: String
        var body: some View {
            HStack(spacing: 8) {
                Text(name).foregroundStyle(Theme.textDim)
                Text(value).foregroundStyle(Theme.text).textSelection(.enabled)
            }
            .font(.system(size: 12.5))
        }
    }
}
