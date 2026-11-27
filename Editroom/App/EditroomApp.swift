import SwiftUI

/// Receives files dropped on the Dock icon or opened with the app from Finder. They can arrive
/// before the editor exists, so they wait until it does.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var pending: [URL] = []
    /// Files dropped on the icon or opened from Finder while Editroom was quit: it starts on a new
    /// project with them, instead of reopening the last one.
    private(set) var openedAtLaunch = false
    private(set) var launching = true

    @MainActor weak var model: EditorModel? {
        didSet {
            flush()
            if let model { MCPServer.shared.attach(model) }
        }
    }

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    /// The very first time Editroom opens, its window fills the screen (less the menu bar and Dock).
    /// After that macOS remembers whatever size the person leaves it at.
    private func fillScreenOnFirstLaunch() {
        let key = "filledScreenOnFirstLaunch"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        var token: NSObjectProtocol?
        let fill: (NSWindow) -> Void = { window in
            guard !UserDefaults.standard.bool(forKey: key),
                  window.identifier?.rawValue.hasPrefix("main") == true,
                  let screen = window.screen ?? NSScreen.main else { return }
            window.setFrame(screen.visibleFrame, display: true, animate: false)
            UserDefaults.standard.set(true, forKey: key)
            if let token { NotificationCenter.default.removeObserver(token) }
        }
        token = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { if let w = note.object as? NSWindow { fill(w) } }
        }
        DispatchQueue.main.async { NSApp.windows.forEach(fill) }
    }

    @objc private func openDocuments(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let list = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
        var urls: [URL] = []
        let count = list.numberOfItems
        // A single file can come as the item itself rather than a list of one.
        for i in 0..<max(count, 1) {
            let item = count > 0 ? list.atIndex(i + 1) : list
            if let url = item?.fileURLValue { urls.append(url) }
        }
        guard !urls.isEmpty else { return }
        application(NSApp, open: urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Files dropped on the Dock icon or opened from Finder once Editroom is running come here directly. Left to
        // SwiftUI, each one presented the window again, fading it out and back in. (Set after SwiftUI's own handler,
        // which replaces one set any earlier; files that open the app still arrive through it, as the window opens.)
        DispatchQueue.main.async {
            NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(self.openDocuments(_:withReply:)),
                                                         forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEOpenDocuments))
        }
        // Files that open the app arrive just before this; any after it are dropped on a running Editroom.
        DispatchQueue.main.async { self.launching = false }
        fillScreenOnFirstLaunch()
        // macOS adds Services to the app menu, and Writing Tools, AutoFill, Start Dictation and Emoji &
        // Symbols to the Edit menu. None of them help with editing video, so they come out once the menus
        // exist, and again whenever they're put back (SwiftUI rebuilds menus as commands change).
        DispatchQueue.main.async { MenuCleanup.removeExtras() }
        if CommandLine.arguments.contains("--dump-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                for top in NSApp.mainMenu?.items ?? [] {
                    NSLog("MENU %@", top.title)
                    for i in top.submenu?.items ?? [] {
                        NSLog("MENU    %@ [%@ %lu] %@%@", i.title, i.keyEquivalent, i.keyEquivalentModifierMask.rawValue, i.action.map { NSStringFromSelector($0) } ?? "-", i.isEnabled ? "" : " (off)")
                    }
                }
            }
        }
        // No automatic updates in this build: new versions come only from rebuilding this repository.
        NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { note in
            // Tidied once SwiftUI has finished updating the menus, never in the middle of it.
            MainActor.assumeIsolated { MenuCleanup.scheduleTidy() }
        }
    }

    /// With Auto-save off, unsaved changes ask Save, Don't Save or Cancel before Editroom quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { model?.confirmDiscard(quitting: true) ?? true } ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.autosaveNow() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if launching { openedAtLaunch = true }
            pending += urls
            flush()
        }
    }

    @MainActor private func flush() {
        guard let model, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        model.handleOpen(urls)
    }
}

/// Takes macOS's extra menu items back out, found by what they do rather than their titles so it holds in
/// any language, then tidies the separators they leave behind.
@MainActor
enum MenuCleanup {
    private static var tidyPending = false

    /// One tidy of the whole menu bar after the current round of menu changes.
    static func scheduleTidy() {
        guard !tidyPending else { return }
        tidyPending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                tidyPending = false
                removeExtras()
            }
        }
    }

    static func removeExtras() {
        for top in NSApp.mainMenu?.items ?? [] {
            if let menu = top.submenu { removeExtras(in: menu) }
        }
    }

    static func removeExtras(in menu: NSMenu) {
        menu.items.filter(isExtra).forEach(menu.removeItem)
        // macOS adds Enter Full Screen to the end of View; it gets a line of its own above it.
        if let i = menu.items.firstIndex(where: { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }),
           i > 0, !menu.items[i - 1].isSeparatorItem {
            menu.insertItem(.separator(), at: i)
        }
        // No separator at either end of a menu, or two in a row.
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        for i in stride(from: menu.items.count - 1, to: 0, by: -1) where menu.items[i].isSeparatorItem && menu.items[i - 1].isSeparatorItem {
            menu.removeItem(at: i)
        }
    }

    private static func isExtra(_ item: NSMenuItem) -> Bool {
        // Close and ⌘W are gone: there's one editor window, and ⌘Q quits.
        let actions: Set<String> = ["startDictation:", "orderFrontCharacterPalette:", "performClose:", "closeAll:"]
        let identifiers: Set<String> = ["__NSTextViewContextSubmenuIdentifierWritingTools", "_NSMenuItemAutoFillIdentifier",
                                        "_NSMenuItemLegacyWritingToolsSeparatorIdentifier"]
        if let services = NSApp.servicesMenu, item.submenu === services { return true }
        return item.identifier.map { identifiers.contains($0.rawValue) } == true
            || item.action.map { actions.contains(NSStringFromSelector($0)) } == true
    }
}

/// Editroom › About Editroom: the standard panel, with one quiet line of credits under the version.
enum AboutPanel {
    @MainActor static func show() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style,
        ]
        let credits = NSMutableAttributedString()
        func add(_ text: String, link: String? = nil) {
            var attributes = base
            if let link { attributes[.link] = URL(string: link) }
            credits.append(NSAttributedString(string: text, attributes: attributes))
        }
        add("Uses ")
        add("FFmpeg", link: "https://ffmpeg.org")
        add(", licensed under the ")
        add("LGPL 2.1", link: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html")
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
        // Links in the text's own colour (white in Dark, black in Light), underlined, not the system blue.
        func textViews(_ view: NSView) -> [NSTextView] { view.subviews.flatMap { ($0 as? NSTextView).map { [$0] } ?? textViews($0) } }
        for window in NSApp.windows {
            for text in textViews(window.contentView ?? NSView()) where text.string == credits.string {
                text.linkTextAttributes = [.foregroundColor: NSColor.labelColor, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                           .cursor: NSCursor.pointingHand]
            }
        }
    }
}

@main
struct EditroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = EditorModel()
    @StateObject private var keys = ShortcutStore.shared

    init() {
        // `--mcp`: a go-between for an AI agent, with no window. Never returns.
        MCPBridge.runIfRequested()
        Self.carryOverFromCutAndPlay()
        SelfTest.runIfRequested()
        FormatCheck.runIfRequested()
    }

    /// The app used to be called Cut and Play. Its settings and its Application Support folder
    /// (recovery file, converted and reversed media) move over once, the first time Editroom runs.
    private static func carryOverFromCutAndPlay() {
        let defaults = UserDefaults.standard
        if let id = Bundle.main.bundleIdentifier,
           defaults.persistentDomain(forName: id)?.isEmpty ?? true,
           let old = defaults.persistentDomain(forName: "com.wonderassembly.CutAndPlay"), !old.isEmpty {
            defaults.setPersistentDomain(old, forName: id)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("CutAndPlay", isDirectory: true)
        let new = support.appendingPathComponent("Editroom", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: new.path) {
            try? FileManager.default.moveItem(at: old, to: new)
            let recovery = new.appendingPathComponent("Recovery")
            try? FileManager.default.moveItem(at: recovery.appendingPathComponent("Untitled.cutplay"),
                                              to: recovery.appendingPathComponent("Untitled.room"))
        }
    }

    var body: some Scene {
        Window("Editroom", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1080, minHeight: 680)
        }
        .defaultSize(width: 1480, height: 940)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Editroom") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New") { model.newProject() }.keyboardShortcut(keys.menu(.new))
                Button("Open…") { model.openProject() }.keyboardShortcut(keys.menu(.open))
                Menu("Open Recent") {
                    ForEach(model.recentProjects, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { model.openRecent(url) }
                    }
                    if !model.recentProjects.isEmpty { Divider() }
                    Button("Clear Menu") { model.clearRecents() }
                        .disabled(model.recentProjects.isEmpty)
                }
                Divider()
                Button("Save") { model.save() }.keyboardShortcut(keys.menu(.save))
                Button("Save As…") { model.saveAs() }.keyboardShortcut(keys.menu(.saveAs))
                Divider()
                Button("Import Media…") { model.showImportPanel() }.keyboardShortcut(keys.menu(.importMedia))
                Button("Export…") { model.showExport = true }.keyboardShortcut(keys.menu(.export))
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }.keyboardShortcut(keys.menu(.undo))
                Button("Redo") { model.redo() }.keyboardShortcut(keys.menu(.redo))
            }
            CommandMenu("Clip") {
                Button("Split at Playhead") { model.splitAtPlayhead() }.keyboardShortcut(keys.menu(.split))
                Button("Add Dissolve") { model.addTransitionAtPlayhead() }.keyboardShortcut(keys.menu(.addDissolve))
                    .disabled(!model.canAddDissolve)
                Button("Even Out Audio Levels") { model.evenOutLevels() }
                Button("Detach Audio") { model.detachAudio() }.keyboardShortcut(keys.menu(.detachAudio))
                    .disabled(!model.selectionIsLinked)
                Button("Duplicate") { model.duplicateSelection() }.keyboardShortcut(keys.menu(.duplicate))
                    .disabled(!model.canDuplicate)
                Button("Freeze Frame") { model.freezeFrame() }.keyboardShortcut(keys.menu(.freezeFrame))
                    .disabled(!model.canFreezeFrame)
                Button("Reverse") { model.reverseSelection() }.keyboardShortcut(keys.menu(.reverse))
                    .disabled(!model.canReverse)
                Divider()
                Button("Copy Grade") { model.copyGrade() }
                    .keyboardShortcut(keys.menu(.copyGrade))
                    .disabled(!model.canCopyGrade)
                Button("Paste Grade") { model.pasteGrade() }
                    .keyboardShortcut(keys.menu(.pasteGrade))
                    .disabled(!model.canPasteGrade)
                Divider()
                Button("Match Sequence to Clip") { if let a = model.matchableAsset { model.matchSequence(to: a) } }
                    .disabled(model.matchableAsset.map { model.sequenceMatches($0) } ?? true)
                Button("Reveal in Media") { model.revealInMedia() }.keyboardShortcut(keys.menu(.revealInMedia))
                    .disabled(model.revealableAsset == nil)
                Divider()
                Button("Delete") { model.deleteSelected() }.keyboardShortcut(keys.menu(.delete))
                    .disabled(!model.canDeleteSelected)
                Button("Ripple Delete") { model.deleteSelected(ripple: true) }.keyboardShortcut(keys.menu(.rippleDelete))
                    .disabled(!model.canDeleteSelected)
                Button("Ripple Trim Start to Playhead") { model.rippleTrim(head: true) }.keyboardShortcut(keys.menu(.rippleTrimStart))
                    .disabled(!model.canRippleTrim)
                Button("Ripple Trim End to Playhead") { model.rippleTrim(head: false) }.keyboardShortcut(keys.menu(.rippleTrimEnd))
                    .disabled(!model.canRippleTrim)
                Button("Close All Gaps") { model.closeAllGaps() }
                Divider()
                Button("Add Text") { model.addAtPlayhead(.text) }.keyboardShortcut(keys.menu(.addText))
                Button("Add Solid") { model.addAtPlayhead(.solid) }
                Button(model.captionsMenuTitle) { model.captionsFromMenu() }
                    .disabled(!model.canCaption)
                Button("Transcribe Again") { model.transcribeAgain() }
                    .disabled(!Transcripts.available)
                Divider()
                Button("Add Video Track") { model.addTrack(.video) }
                Button("Add Audio Track") { model.addTrack(.audio) }
            }
            CommandMenu("Subtitles") {
                Button("Translate and Dub…") { model.showDub = true }
                Divider()
                Button("Import Subtitles (SRT)…") { model.importSubtitlesFromPanel() }
                Divider()
                Button("Export Subtitles (SRT)…") { model.exportSubtitles(.srt) }
                    .disabled(model.project.captions == nil)
                Button("Export Transcript (Text)…") { model.exportSubtitles(.text) }
                    .disabled(model.project.captions == nil)
                Button("Export Transcript with Times…") { model.exportSubtitles(.textWithTimes) }
                    .disabled(model.project.captions == nil)
                Divider()
                // Which subtitles the caption track shows: what's heard, or a layer brought in (a translation).
                Picker("Show", selection: Binding(get: { model.project.captions?.layer }, set: { model.showSubtitleLayer($0) })) {
                    Text("What's Heard").tag(UUID?.none)
                    ForEach(model.project.subtitleLayers ?? []) { layer in
                        Text(layer.name).tag(UUID?.some(layer.id))
                    }
                }
                .disabled(model.project.captions == nil)
                if let layers = model.project.subtitleLayers, !layers.isEmpty {
                    Menu("Remove Layer") {
                        ForEach(layers) { layer in
                            Button(layer.name) { model.removeSubtitleLayer(layer.id) }
                        }
                    }
                }
                Divider()
                Button("Import Dub Track…") { model.importDubFromPanel() }
            }
            CommandMenu("Class") {
                Button("Make Multi-Angle from Selected Clips") { model.makeMultiAngle() }
                if let group = model.activeAngleGroup {
                    Divider()
                    ForEach(Array(group.angles.enumerated()), id: \.offset) { i, angle in
                        // ⌥1…⌥9 for the first nine cameras.
                        Button("Cut to Camera \(i + 1): \(angle.name)") { model.switchAngle(to: i) }
                            .keyboardShortcut(i < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .option) : nil)
                    }
                    Menu("Selected Clips Show") {
                        ForEach(Array(group.angles.enumerated()), id: \.offset) { i, angle in
                            Button("Camera \(i + 1): \(angle.name)") { model.showAngle(i) }
                        }
                    }
                    Menu("Picture in Picture") {
                        ForEach(Array(group.angles.enumerated()), id: \.offset) { i, angle in
                            Menu("Camera \(i + 1): \(angle.name)") {
                                ForEach(PictureCorner.allCases, id: \.self) { corner in
                                    Button(corner.label) { model.addPictureInPicture(angle: i, corner: corner) }
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Remove Dead Air…") { model.removeDeadAirDialog() }
                Button("Speed Up…") { model.speedUpDialog() }
            }
            // Plain-key shortcuts (M, I, O, ⇧X) are run by the editor window first (KeyCommands), and
            // typed as text in a text field.
            CommandMenu("Mark") {
                Button("Add Marker") { model.addMarker() }.keyboardShortcut(keys.menu(.addMarker))
                Button("Clear All Markers") { model.clearMarkers() }
                    .disabled((model.project.markers ?? []).isEmpty)
                Divider()
                Button("Set In") { model.setInPoint() }.keyboardShortcut(keys.menu(.setIn))
                Button("Set Out") { model.setOutPoint() }.keyboardShortcut(keys.menu(.setOut))
                Button("Clear In and Out") { model.clearRange() }.keyboardShortcut(keys.menu(.clearInOut))
                    .disabled(model.project.inPoint == nil && model.project.outPoint == nil)
            }
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { model.zoom(by: 1.4) }.keyboardShortcut(keys.menu(.zoomIn))
                Button("Zoom Out") { model.zoom(by: 1 / 1.4) }.keyboardShortcut(keys.menu(.zoomOut))
                Button("Zoom to Fit") { model.zoomToFit() }.keyboardShortcut(keys.menu(.zoomToFit))
                Divider()
                // The timeline toolbar's toggles, in the same order, ticked when on. Typing in a text
                // field keeps these single keys (see KeyCommands); macOS puts Enter Full Screen after
                // them, and MenuCleanup keeps a line above it.
                Toggle("Filmstrips", isOn: $model.thumbnails)
                Toggle("Snapping", isOn: $model.snapping).keyboardShortcut(keys.menu(.snapping))
                Toggle("Sticky Edges", isOn: $model.sticky).keyboardShortcut(keys.menu(.sticky))
                Toggle("Skimming", isOn: $model.skimming).keyboardShortcut(keys.menu(.skimming))
                Toggle("Audio Scrubbing", isOn: $model.audioScrub).keyboardShortcut(keys.menu(.audioScrubbing))
            }
        }
        Settings {
            SettingsView(model: model)
        }
    }
}
