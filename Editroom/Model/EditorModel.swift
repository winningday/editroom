import SwiftUI
import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

enum Tool { case move, cut }

enum DragPayload: Equatable {
    case asset(UUID)
    case solid
    case text
}

/// Zoom and scroll of the timeline. Kept separate so scrolling doesn't invalidate the whole UI.
@MainActor
final class TimelineViewState: ObservableObject {
    static let minPPS: CGFloat = 0.05
    static let maxPPS: CGFloat = 2400

    @Published var pps: CGFloat = 80
    @Published var scrollX: CGFloat = 0
    @Published var scrollY: CGFloat = 0
    @Published var rowHeight: CGFloat = 62
    @Published var viewWidth: CGFloat = 900
    @Published var viewHeight: CGFloat = 300
    /// Set until the timeline has reported its real size and the tracks have been centred in it.
    var needsInitialCentering = true

    static let rowRange: ClosedRange<CGFloat> = 30...110
}

/// Publishes only when the visible frame number changes.
@MainActor
final class Clock: ObservableObject {
    @Published private(set) var frame = 0

    func update(time: Double, fps: Double) {
        let f = Int((time * fps).rounded())
        if f != frame { frame = f }
    }
}

struct SavedDocument: Codable {
    var version = 1
    var project: Project
}

@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var project = Project() {
        didSet { lastEdit = Date() }
    }
    @Published var selection: Set<UUID> = [] {
        didSet {
            if !selection.isEmpty, !captionSelection.isEmpty || captionsFocused { captionSelection = []; captionsFocused = false }
            // Clips picked on the timeline (a click, ⌘A, a drop): Media lets go of its picks, so Delete is for the clips.
            if !selection.isEmpty, selection != oldValue, !mediaSelection.isEmpty || !folderSelection.isEmpty || !incomingSelection.isEmpty {
                clearMediaPicks()
            }
        }
    }
    /// Captions picked on the caption track (by `CaptionBlock.id`); picking clips clears them.
    @Published var captionSelection: Set<String> = []
    /// The caption track's header was clicked: the inspector shows the caption style.
    @Published var captionsFocused = false
    /// A caption to retype: the inspector puts its text field on it.
    @Published var captionEditRequest: String?
    /// Bumped as transcripts become ready, so captions waiting for one appear.
    private var transcriptVersion = 0
    private var captionCache: (key: Int, blocks: [CaptionBlock])?
    private var transcriptWatch: AnyCancellable?
    /// Items picked in the Media panel (click, ⇧-click for a range, ⌘-click to add or take away).
    /// Delete removes these while there are any; clicking the timeline clears them.
    @Published var mediaSelection: Set<UUID> = []
    /// Folders picked in the Media panel, by path, alongside items: Delete takes them out too.
    @Published var folderSelection: Set<String> = []
    private var mediaAnchor: MediaPick?
    /// Files are being dragged over the window outside the Media panel and timeline: the panel shows they'll land in it.
    @Published var importDropHover = false
    /// Files another app is still writing for a drop (Photos): shown as placeholders at the end of Media.
    @Published var incomingFiles: [UUID] = []
    /// Placeholders picked in Media: Delete cancels them.
    @Published var incomingSelection: Set<UUID> = []
    /// For each drop, how many of its files were cancelled: those are thrown away as they arrive.
    var incomingCancels: [UUID: Int] = [:]
    /// The drop each placeholder belongs to.
    var incomingDrop: [UUID: UUID] = [:]
    /// Something the Media panel should scroll to (what was just imported).
    @Published var mediaReveal: MediaReveal?
    /// The folder open in the Media panel (its path); nil for the top.
    @Published var mediaFolder: String?
    /// Linked folders whose files are coming in, kept while they're still empty.
    private var importingFolders = Set<UUID>()
    /// Files being imported right now, so the same file isn't brought in twice at once.
    private var pendingImports = Set<String>()
    private var syncingFolders = false
    /// Items taken out because their file was deleted from a linked folder: Undo doesn't bring them back.
    private var droppedFromDisk = Set<UUID>()
    /// Files in linked folders that couldn't be imported, left alone from then on.
    private var unreadable = Set<String>()
    @Published var tool: Tool = .move
    @Published var snapping = true
    /// Skimming: hovering over the timeline shows that frame in the viewer without moving the playhead.
    @Published var skimming = UserDefaults.standard.object(forKey: "skimming") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(skimming, forKey: "skimming")
            if !skimming { skim(to: nil) }
        }
    }
    /// Clip thumbnails: pictures in video and image clips. Off draws every clip as flat colour by
    /// media type, which reads more clearly on a busy or zoomed-out timeline.
    @Published var thumbnails = UserDefaults.standard.object(forKey: "thumbnails") as? Bool ?? true {
        didSet { UserDefaults.standard.set(thumbnails, forKey: "thumbnails") }
    }
    /// Where the viewer is skimmed to, if anywhere.
    private(set) var skimTime: Double?
    /// Audio scrubbing: hear short snippets while dragging the playhead or skimming. Off unless turned on.
    @Published var audioScrub = UserDefaults.standard.bool(forKey: "audioScrub") {
        didSet {
            UserDefaults.standard.set(audioScrub, forKey: "audioScrub")
            if audioScrub {
                scrubber.warmUp()
                scrubber.prepare(project: project, media: media)
            } else {
                scrubber.shutDown()
            }
        }
    }
    private let scrubber = AudioScrubber()
    /// The last snippet heard, so the meters can show it.
    private var lastScrubSound: (time: Double, at: Double)?

    /// Plays a snippet of the timeline's sound at a time, when audio scrubbing is on.
    func scrubSound(at t: Double) {
        guard audioScrub, !isPlaying else { return }
        scrubber.play(at: t)
        lastScrubSound = (t, CACurrentMediaTime())
    }
    /// Sticky edges: clips touching a clip that changes length move with it, closing or opening up
    /// the space instead of leaving a gap or overlapping.
    @Published var sticky = UserDefaults.standard.bool(forKey: "stickyEdges") {
        didSet { UserDefaults.standard.set(sticky, forKey: "stickyEdges") }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var fileURL: URL?
    @Published private(set) var isDirty = false
    @Published var showExport = false
    @Published var showAgents = false
    /// Playback starts over from the beginning when it reaches the end.
    @Published var loop = UserDefaults.standard.bool(forKey: "loopPlayback") {
        didSet { UserDefaults.standard.set(loop, forKey: "loopPlayback") }
    }
    /// Only the viewer is shown, full screen.
    @Published private(set) var viewerOnly = false
    @Published private(set) var importCount = 0
    @Published var importError: String?

    let view = TimelineViewState()
    let clock = Clock()
    let media = MediaStore()
    let meters = MeterState()
    let sourcePreview = SourcePreviewState()
    let engine = PlaybackEngine()
    let exports = ExportQueue()

    private(set) var playhead: Double = 0
    var tickHandlers: [() -> Void] = []
    /// Set while something is being dragged out of the library.
    var dragPayload: DragPayload?

    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    /// For each redo step, the library items there were before it: so redoing a deletion takes the
    /// items away again, without touching anything imported since.
    private var redoKnown: [Set<UUID>] = []
    private var liveSnapshot: Project?
    private var liveTimer: Timer?
    private var rebuildPending = false
    private var lastRebuild = 0.0

    init() {
        defer { sourcePreview.engine = engine }
        engine.onEnded = { [weak self] in
            guard let self else { return }
            if self.loop, self.project.duration > 0 {
                let start = self.loopSpan.start
                self.playhead = start
                self.engine.seek(to: start)
                self.engine.play()
                return
            }
            self.isPlaying = false
            self.playhead = self.project.duration
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                // Leaving macOS full screen while the viewer had it: back to the editor.
                if self?.viewerOnly == true, let window = note.object as? NSWindow {
                    self?.viewerOnly = false
                    ViewerScreen.exit(window)
                }
            }
        }
        // Back from another app: any media saved over there is opened again.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadChangedMedia()
                Task { await self?.syncFolders() }
            }
        }
        // A transcript ready: captions waiting for it appear.
        transcriptWatch = Transcripts.shared.$states.dropFirst().sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.project.captions != nil else { return }
                self.transcriptVersion += 1
                self.objectWillChange.send()
                self.setNeedsRebuild()
            }
        }
        media.onStillLoaded = { [weak self] in self?.setNeedsRebuild() }
        media.onReverseReady = { [weak self] in self?.setNeedsRebuild() }
        Task {
            await BaseVideo.load()
            self.setNeedsRebuild()
            // `--open <project.room>` loads a project at launch.
            let args = CommandLine.arguments
            if let i = args.firstIndex(of: "--open"), args.count > i + 1 {
                self.open(url: URL(fileURLWithPath: args[i + 1]))
                if let j = args.firstIndex(of: "--seek"), args.count > j + 1, let t = Double(args[j + 1]) {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.seek(to: t)
                }
                // `--pps N` (testing): the timeline zoomed to N points a second.
                if let j = args.firstIndex(of: "--pps"), args.count > j + 1, let v = Double(args[j + 1]) {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.setView(pps: CGFloat(v), scrollX: 0)
                }
                if let j = args.firstIndex(of: "--rows"), args.count > j + 1, let r = Double(args[j + 1]) {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.setView(rowHeight: CGFloat(r))
                    self.centerRows()
                }
                if args.contains("--select-first"), let first = self.project.clips.first {
                    self.selection = self.project.linked([first.id])
                }
                if args.contains("--reverse-first") { self.reverseSelection() }
                if args.contains("--edit-marker"), let m = self.project.markerList.dropFirst().first {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    self.editingMarker = m.id
                }
                // `--scrub-test` (testing): drags the playhead back and forth like a fast scrub, 60 moves a
                // second, and times how far the shown frame falls behind.
                // `--scrub-test [exact]` (testing): drags the playhead like a hand scrub (back and forth across
                // a few seconds, 60 moves a second) and counts how often the viewer's picture changes.
                // `--loop-test` (testing): plays the last two seconds on Loop, three times round, and reports
                // the longest wait between new frames in the viewer at each wrap (a frame is ~17-42 ms).
                if args.contains("--loop-test") {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    let d = self.project.duration
                    self.loop = true
                    // `--loop-test inout`: an in/out range in the middle instead of the whole timeline.
                    if args.contains("inout") { self.mutate { $0.inPoint = d * 0.3; $0.outPoint = d * 0.3 + 1.5 } }
                    self.seek(to: args.contains("inout") ? d * 0.3 + 1 : max(0, d - 2))
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    self.play()
                    var lastShown = -1.0, lastChange = CACurrentMediaTime(), prevPlayhead = self.playhead
                    var gaps: [(at: Double, gap: Double)] = [], wrapTimes: [Double] = []
                    let t0 = CACurrentMediaTime()
                    while CACurrentMediaTime() - t0 < 7.2 {
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        let now = CACurrentMediaTime()
                        if self.engine.shownTime != lastShown {
                            if lastShown >= 0 { gaps.append((now, now - lastChange)) }
                            lastShown = self.engine.shownTime
                            lastChange = now
                        }
                        if self.playhead < prevPlayhead - 0.5 {
                            wrapTimes.append(now)
                            // What the viewer shows next, and where the playhead is, right after wrapping.
                            var firstShown = self.engine.shownTime
                            let ph = self.playhead
                            for _ in 0..<50 where firstShown > ph + 0.5 { try? await Task.sleep(nanoseconds: 1_000_000); firstShown = self.engine.shownTime }
                            FileHandle.standardError.write(String(format: "LOOP wrap: playhead %.4f, first frame shown %.4f (loop start %.4f)\n", ph, firstShown, self.loopSpan.start).data(using: .utf8)!)
                        }
                        prevPlayhead = self.playhead
                    }
                    let typical = gaps.map(\.gap).sorted()[gaps.count / 2]
                    let wraps = wrapTimes.map { w in
                        String(format: "%.0f ms", (gaps.filter { abs($0.at - w) < 0.5 }.map(\.gap).max() ?? 0) * 1000)
                    }
                    FileHandle.standardError.write(String(format: "LOOP typical frame %.0f ms\n", typical * 1000).data(using: .utf8)!)
                    self.pause()
                    FileHandle.standardError.write("LOOP wraps=\(wraps.count) longest gap at each: \(wraps.joined(separator: ", "))\n".data(using: .utf8)!)
                    exit(0)
                }
                if args.contains("--scrub-test") {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    // The made-ahead frames for what's on the timeline, unless testing without them.
                    let made = Date()
                    let videos = Set(self.project.clips.filter { $0.kind == .video }.compactMap(\.assetID))
                    while !args.contains("exact"), !videos.allSatisfy({ self.media.scrubCache.has($0) }), Date().timeIntervalSince(made) < 120 {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    FileHandle.standardError.write(String(format: "SCRUB frames ready after %.1fs\n", Date().timeIntervalSince(made)).data(using: .utf8)!)
                    let d = self.project.duration
                    let exact = args.contains("exact")
                    var last = -1.0, updates = 0
                    let t0 = Date()
                    for i in 0..<240 {
                        let u = Double(i) / 60
                        let t = min(d - 0.1, d * 0.2 + min(2.5, d * 0.35) * (1 - cos(u * 2.2)))
                        if exact { self.seek(to: t) } else { self.scrub(to: t) }
                        try? await Task.sleep(nanoseconds: 16_000_000)
                        if self.engine.shownTime != last { updates += 1; last = self.engine.shownTime }
                    }
                    let secs = Date().timeIntervalSince(t0)
                    let stop = Date()
                    while abs(self.engine.shownTime - self.playhead) > 1.5 / self.project.fps, Date().timeIntervalSince(stop) < 3 {
                        try? await Task.sleep(nanoseconds: 2_000_000)
                    }
                    FileHandle.standardError.write(String(format: "SCRUB %@: viewer updated %.0f times a second, exact frame %.0f ms after stopping (shown %.3f, playhead %.3f)\n",
                                                          exact ? "exact" : "fast", Double(updates) / secs, Date().timeIntervalSince(stop) * 1000,
                                                          self.engine.shownTime, self.playhead).data(using: .utf8)!)
                    // The same moment, exact and from scrub frames: how far apart their colours are (0-255).
                    if !exact, let still = self.engine.lastFrame {
                        func mean(_ b: CVPixelBuffer) -> [Double] {
                            CVPixelBufferLockBaseAddress(b, .readOnly)
                            defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
                            let w = CVPixelBufferGetWidth(b), h = CVPixelBufferGetHeight(b), row = CVPixelBufferGetBytesPerRow(b)
                            guard let base = CVPixelBufferGetBaseAddress(b)?.assumingMemoryBound(to: UInt8.self) else { return [] }
                            var sum = [0.0, 0.0, 0.0], n = 0.0
                            for y in stride(from: 0, to: h, by: 8) { for x in stride(from: 0, to: w, by: 8) {
                                let p = base + y * row + x * 4
                                sum[0] += Double(p[2]); sum[1] += Double(p[1]); sum[2] += Double(p[0]); n += 1 } }
                            return sum.map { $0 / n }
                        }
                        let a = mean(still)
                        _ = self.engine.showScrubFrame(at: self.playhead, cache: self.media.scrubCache)
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        if let scrubbed = self.engine.lastFrame, scrubbed !== still {
                            let b = mean(scrubbed)
                            FileHandle.standardError.write(String(format: "SCRUB colour exact RGB %.1f %.1f %.1f, scrub frame %.1f %.1f %.1f\n",
                                                                  a[0], a[1], a[2], b[0], b[1], b[2]).data(using: .utf8)!)
                        }
                        self.engine.endScrubFrames()
                    }
                    // One seek at a time, each to somewhere new: how long until its frame is on screen.
                    var waits: [Double] = []
                    for i in 0..<24 {
                        let t = d * (0.1 + 0.8 * Double((i * 7) % 24) / 24)
                        let asked = Date()
                        if exact { self.seek(to: t) } else { self.scrub(to: t) }
                        while abs(self.engine.shownTime - self.playhead) > (exact ? 1.5 / self.project.fps : 0.8), Date().timeIntervalSince(asked) < 2 {
                            try? await Task.sleep(nanoseconds: 1_000_000)
                        }
                        waits.append(Date().timeIntervalSince(asked) * 1000)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                    }
                    waits.sort()
                    FileHandle.standardError.write(String(format: "SEEK %@: median %.0f ms, slowest %.0f ms (shown vs asked: %.3f / %.3f)\n", exact ? "exact" : "fast",
                                                          waits[waits.count / 2], waits.last!, self.engine.shownTime, self.playhead).data(using: .utf8)!)
                }
                if args.contains("--show-export") { self.showExport = true }
                if args.contains("--show-agents") { self.showAgents = true }
                // `--import-test <file>` (testing): imports it and times its Media poster and a timeline frame.
                // `--import-offer`: offering to match the sequence to it, as a drop does.
                if let k = args.firstIndex(of: "--import-test"), args.count > k + 1 {
                    let url = URL(fileURLWithPath: args[k + 1])
                    let t0 = Date()
                    self.importFiles([url], offerMatch: args.contains("--import-offer")) { assets in
                        guard let a = assets.first else { return }
                        FileHandle.standardError.write(String(format: "IMPORT imported %.2fs\n", Date().timeIntervalSince(t0)).data(using: .utf8)!)
                        if args.contains("--to-timeline") {
                            let payload = DragPayload.asset(a.id)
                            self.insert(self.makeClips(payload, at: 0, videoTrack: self.project.videoTracks[0].id, audioTrack: self.project.audioTracks[0].id))
                        }
                        Task { @MainActor in
                            var poster = false, frame = false
                            while Date().timeIntervalSince(t0) < 120, !(poster && frame) {
                                if !poster, self.media.posters[a.id] != nil {
                                    poster = true
                                    FileHandle.standardError.write(String(format: "IMPORT poster %.2fs\n", Date().timeIntervalSince(t0)).data(using: .utf8)!)
                                }
                                if !frame, self.media.thumbnail(asset: a.id, time: a.duration / 2) != nil {
                                    frame = true
                                    FileHandle.standardError.write(String(format: "IMPORT frame %.2fs\n", Date().timeIntervalSince(t0)).data(using: .utf8)!)
                                }
                                try? await Task.sleep(nanoseconds: 50_000_000)
                            }
                            if !poster { FileHandle.standardError.write("IMPORT poster never\n".data(using: .utf8)!) }
                        }
                    }
                }
                // `--switch-theme light` (testing): change the theme while running, as Settings does.
                if let k = args.firstIndex(of: "--switch-theme"), args.count > k + 1, let theme = AppTheme(rawValue: args[k + 1]) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    ThemeStore.shared.theme = theme
                }
                // `--scrub-test` (testing): how long a hover-scrub frame takes once the strips are made.
                if args.contains("--scrub-test") {
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    for a in self.project.assets where a.kind == .video {
                        var hits = 0
                        let t0 = CACurrentMediaTime()
                        for i in 0...100 where self.media.instantFrame(asset: a, at: Double(i) / 100) != nil { hits += 1 }
                        let ms = (CACurrentMediaTime() - t0) * 1000 / 101
                        FileHandle.standardError.write("SCRUB \(a.name) \(hits)/101 frames ready, \(String(format: "%.2f", ms)) ms each\n".data(using: .utf8)!)
                    }
                }
                // `--media-menu header|empty` (testing): right-click the Media panel's header or the space under its list.
                if let k = args.firstIndex(of: "--media-menu"), args.count > k + 1,
                   let r = MagicAnchors.rect("libraryList"), let w = NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let at = args[k + 1] == "header" ? NSPoint(x: r.minX + 60, y: r.maxY + 22) : NSPoint(x: r.midX, y: r.minY + 30)
                    if let e = NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        DispatchQueue.main.async { w.sendEvent(e) }
                    }
                }
                // `--toggle-time` (testing): switch Show time as a few times, as clicking it would.
                if args.contains("--toggle-time") {
                    for _ in 0..<4 {
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        let before = self.playhead
                        ThemeStore.shared.timeStyle = ThemeStore.shared.timeStyle == .simple ? .timecode : .simple
                        var seen: [Double] = []
                        for _ in 0..<6 { try? await Task.sleep(nanoseconds: 50_000_000); seen.append(self.playhead) }
                        FileHandle.standardError.write("TOGGLE TIME \(ThemeStore.shared.timeStyle) playhead \(before) -> \(seen)\n".data(using: .utf8)!)
                    }
                }
                // `--scenes <file>` (testing): what Vision sees in a video, every label it gives at 0.2 or more.
                if let k = args.firstIndex(of: "--scenes"), args.count > k + 1 {
                    let url = URL(fileURLWithPath: args[k + 1])
                    let d = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 5
                    let tags = await SceneTagStore.seeVideo(url, duration: d)
                    let all = await SceneTagStore.allLabels(url, duration: d)
                    FileHandle.standardError.write("SCENES kept: \(tags?.tags.map { "\($0.name) \($0.confidence)" }.joined(separator: ", ") ?? "-")\nSCENES all: \(all)\n".data(using: .utf8)!)
                }
                // `--transcribe <file>` (testing): hear a file and log its words with their times.
                if let k = args.firstIndex(of: "--transcribe"), args.count > k + 1 {
                    let url = URL(fileURLWithPath: args[k + 1])
                    let t0 = Date()
                    let t = await Transcripts.transcribe(url)
                    let words = t?.words.map { String(format: "%.2f-%.2f %@", $0.start, $0.end, $0.text) }.joined(separator: " | ") ?? "nil"
                    FileHandle.standardError.write("TRANSCRIBE \(String(format: "%.1f", Date().timeIntervalSince(t0)))s [\(t?.language ?? "-")] \(words)\n".data(using: .utf8)!)
                }
                if args.contains("--play") { self.play() }
                // `--captions-test <file> <out.png>` (testing): captions a clip of someone talking, logs the
                // captions once what's said has been heard, and draws one over grey to the PNG.
                if let k = args.firstIndex(of: "--captions-test"), args.count > k + 2 {
                    self.importFiles([URL(fileURLWithPath: args[k + 1])], offerMatch: false) { assets in
                        guard let a = assets.first else { return }
                        let v = self.project.videoTracks[0].id, au = self.project.audioTracks[0].id
                        self.insert(self.makeClips(.asset(a.id), at: 0, videoTrack: v, audioTrack: au))
                        let n = self.addCaptions(to: [])
                        Task { @MainActor in
                            let t0 = CACurrentMediaTime()
                            while self.captionBlocks.isEmpty, CACurrentMediaTime() - t0 < 120 {
                                try? await Task.sleep(nanoseconds: 250_000_000)
                            }
                            let blocks = self.captionBlocks
                            var log = "CAPTIONS clips=\(n) blocks=\(blocks.count) after \(Int(CACurrentMediaTime() - t0))s\n"
                            for b in blocks { log += String(format: "  %.2f-%.2f  ", b.start, b.end) + b.text + "\n" }
                            if let b = blocks.dropFirst().first ?? blocks.first, let track = self.project.captions {
                                let size = CGSize(width: 1920, height: 1080)
                                let layers = CaptionRenderer.layers([b], style: track.style)
                                let t = b.words.count > 1 ? (b.words[1].start + b.words[1].end) / 2 : (b.start + b.end) / 2
                                let grey = CIImage(color: CIColor(red: 0.45, green: 0.5, blue: 0.55)).cropped(to: CGRect(origin: .zero, size: size))
                                let image = layers.first { t >= $0.start && t < $0.end }?.image(output: size).map { $0.composited(over: grey) } ?? grey
                                if let cg = TimelineCompositor.context.createCGImage(image, from: CGRect(origin: .zero, size: size)) {
                                    let rep = NSBitmapImageRep(cgImage: cg)
                                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[k + 2]))
                                }
                            }
                            // The AI's fix: the second caption retyped, the third taken out.
                            if blocks.count >= 3 {
                                let out = try? await MCPTools.call("set_captions", ["edit": [["at": (blocks[1].start + blocks[1].end) / 2, "text": "We made Editroom"],
                                                                                            ["at": blocks[2].start + 0.01, "text": ""]]], model: self, client: nil)
                                let now = self.captionBlocks
                                log += "CAPTIONS edit via set_captions: \(out == nil ? "failed" : "ok")\n"
                                for b in now.prefix(4) { log += String(format: "  %.2f-%.2f  ", b.start, b.end) + b.text + "\n" }
                            }
                            FileHandle.standardError.write(log.data(using: .utf8)!)
                        }
                    }
                }
                // `--handoff-test <file>` (testing): plays two copies of a clip, moves the second while playing,
                // and logs how evenly the playhead kept moving (the longest it stood still).
                if let k = args.firstIndex(of: "--handoff-test"), args.count > k + 1 {
                    self.importFiles([URL(fileURLWithPath: args[k + 1])], offerMatch: false) { assets in
                        guard let a = assets.first else { return }
                        let v = self.project.videoTracks[0].id, au = self.project.audioTracks[0].id
                        let len = min(a.duration, 4)
                        var clips = self.makeClips(.asset(a.id), at: 0, videoTrack: v, audioTrack: au)
                        clips += self.makeClips(.asset(a.id), at: a.duration, videoTrack: v, audioTrack: au)
                        self.insert(clips)
                        Task { @MainActor in
                            // `--handoff-captions`: with the clips captioned (heard first).
                            if args.contains("--handoff-captions") {
                                self.addCaptions(to: [])
                                if let url = self.media.soundURL(a.id) { _ = await Transcripts.shared.ready(url) }
                                FileHandle.standardError.write("CAPTIONS \(self.captionBlocks.count)\n".data(using: .utf8)!)
                            }
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            if args.contains("--handoff-loop") {
                                self.project.inPoint = 0.5
                                self.project.outPoint = 2.0
                                self.loop = true
                            }
                            self.play()
                            var samples: [(wall: Double, head: Double)] = []
                            let t0 = CACurrentMediaTime()
                            var moved = false, moves = 0
                            var lastShown = -1.0, lastChange = CACurrentMediaTime(), frameGap = 0.0, backward = 0
                            while CACurrentMediaTime() - t0 < 3.5 {
                                if args.contains("--handoff-mute"), !moved, CACurrentMediaTime() - t0 > 1 {
                                    // `--handoff-mute`: mutes and unmutes the first audio track instead.
                                    moved = true
                                    FileHandle.standardError.write("MUTE on\n".data(using: .utf8)!)
                                    self.mutate { $0.audioTracks[0].muted = true }
                                    Task { @MainActor in
                                        try? await Task.sleep(nanoseconds: 700_000_000)
                                        FileHandle.standardError.write("MUTE off\n".data(using: .utf8)!)
                                        self.mutate { $0.audioTracks[0].muted = false }
                                    }
                                }
                                if moves < (args.contains("--handoff-none") ? 0 : 3), CACurrentMediaTime() - t0 > 1 + Double(moves) * 0.8 {
                                    moves += 1
                                    moved = true
                                    let second = self.project.clips.filter { $0.start > 0.5 }.map(\.id)
                                    if args.contains("--handoff-track") {
                                        // `--handoff-track`: the second copy goes up a track instead (V1→V2, A1→A2).
                                        self.mutate { p in
                                            let v2 = p.videoTracks[1].id, a2 = p.audioTracks[1].id
                                            for id in second { if let i = p.index(of: id) { p.clips[i].trackID = p.clips[i].kind == .audio ? a2 : v2 } }
                                        }
                                    } else {
                                        self.mutate { p in for id in second { if let i = p.index(of: id) { p.clips[i].start += 0.5 } } }
                                    }
                                }
                                if CACurrentMediaTime() - t0 > 0.5 { samples.append((CACurrentMediaTime(), self.playhead)) }
                                if CACurrentMediaTime() - t0 > 0.5, self.engine.shownTime != lastShown {
                                    let now = CACurrentMediaTime()
                                    if lastShown >= 0 { frameGap = max(frameGap, now - lastChange); if self.engine.shownTime < lastShown { backward += 1 } }
                                    lastShown = self.engine.shownTime
                                    lastChange = now
                                }
                                try? await Task.sleep(nanoseconds: 2_000_000)
                            }
                            var stall = 0.0, since = samples[0].wall
                            for i in 1..<samples.count {
                                if samples[i].head > samples[i - 1].head + 1e-6 { since = samples[i].wall } else { stall = max(stall, samples[i].wall - since) }
                            }
                            let drift = (samples.last!.head - samples[0].head) - (samples.last!.wall - samples[0].wall)
                            FileHandle.standardError.write(String(format: "HANDOFF longest still %.0f ms, drift %.0f ms, playing=%@ len=%.1f, moves %d, longest between viewer frames %.0f ms, backward %d\n",
                                                                  stall * 1000, drift * 1000, self.isPlaying ? "yes" : "no", len, moves, frameGap * 1000, backward).data(using: .utf8)!)
                        }
                    }
                }
                if args.contains("--magic") {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    LocalMagic.run("", model: self)
                }
                if args.contains("--magic-ask") {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    // `--magic-tab claude|chatgpt|local` picks the tab first.
                    if let k = args.firstIndex(of: "--magic-tab"), args.count > k + 1, let tab = MagicAgent.Tab(rawValue: args[k + 1]) {
                        MagicAgent.shared.tab = tab
                    }
                    MagicAgent.shared.asking = true
                    // `--magic-reopen` (testing): close the popover and open it again, as after looking around.
                    if args.contains("--magic-reopen") {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        MagicAgent.shared.asking = false
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        FileHandle.standardError.write("MAGIC REOPEN kept \"\(MagicAgent.shared.prompt)\"\n".data(using: .utf8)!)
                        MagicAgent.shared.asking = true
                    }
                }
                // `--magic-note` (testing): shows a sample finished note.
                if args.contains("--magic-note") {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    MagicAgent.shared.note = MagicAgent.Note(agent: .chatgpt, text: "I cut it from 12 seconds to 8, took out the repeated shots, and timed the cuts to the music. Your library has no sound effects, so I couldn't add any.", changed: true, detail: "GPT-6.2-Sol · Low · 56s")
                }
                // `--magic-local "request"` (testing): Local Magic with a request, read on this Mac.
                if let k = args.firstIndex(of: "--magic-local"), args.count > k + 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    LocalMagic.run(args[k + 1], model: self)
                }
                // `--magic-ai claude|chatgpt "request"` (testing): Magic with an AI, logged to stderr.
                if let k = args.firstIndex(of: "--magic-ai"), args.count > k + 1,
                   let kind = MagicAgent.Kind(rawValue: args[k + 1]) {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let request = args.count > k + 2 && !args[k + 2].hasPrefix("--") ? args[k + 2] : ""
                    MagicAgent.shared.start(request: request, with: kind, model: self)
                }
                if args.contains("--curve-menu") {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    let (menu, current) = CurveMenu.menu(selection: .easeIn, rising: true) { _ in }
                    menu.popUp(positioning: current, at: NSPoint(x: 400, y: 600), in: nil)
                }
                // `--queue-exports <dir>`: queues a 4K HEVC and a WAV export, for checking the queue.
                if let k = args.firstIndex(of: "--queue-exports"), args.count > k + 1 {
                    let dir = URL(fileURLWithPath: args[k + 1])
                    var video = ExportSettings()
                    video.height = 2160
                    video.codec = .hevc
                    var audio = ExportSettings()
                    audio.format = .wav
                    self.exports.add(project: self.project, media: self.media, settings: video, url: dir.appendingPathComponent("queued_4k.mp4"))
                    self.exports.add(project: self.project, media: self.media, settings: audio, url: dir.appendingPathComponent("queued.wav"))
                }
                if args.contains("--viewer-fullscreen") {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    self.toggleViewerFullScreen()
                }
            } else if !args.contains("--selftest") {
                // Files that opened the app have arrived by the time launching ends.
                for _ in 0..<100 where AppDelegate.shared?.launching == true { try? await Task.sleep(nanoseconds: 20_000_000) }
                self.restoreLastSession()
            }
        }
        if audioScrub { scrubber.warmUp() }
        if !CommandLine.arguments.contains("--selftest") {
            autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.autosaveIfIdle() }
            }
        }
    }

    // MARK: Autosave and recovery

    private var autosaveTimer: Timer?
    private var lastEdit = Date.distantPast
    private var lastRecovered: Project?

    /// Unsaved work on an untitled project is kept here, and reopened on the next launch.
    static var recoveryURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Editroom/Recovery", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Untitled.room")
    }

    /// What to reopen at launch: a project file's path, or "untitled" for the recovery copy.
    private var lastSession: String? {
        get { UserDefaults.standard.string(forKey: "lastSession") }
        set {
            guard !CommandLine.arguments.contains("--open") else { return }
            UserDefaults.standard.set(newValue, forKey: "lastSession")
        }
    }

    /// Settings > General > Auto-save. On (the default), a saved project is written in place as you edit.
    /// Off, the project file changes only on Save; edits still go to the recovery copy, so a crash loses nothing.
    static let autosaveKey = "autosave"
    static var autosaves: Bool { UserDefaults.standard.object(forKey: autosaveKey) as? Bool ?? true }
    /// The project file the recovery copy holds unsaved changes to, when Auto-save is off.
    private var recoveryFor: String? {
        get { UserDefaults.standard.string(forKey: "recoveryFor") }
        set { UserDefaults.standard.set(newValue, forKey: "recoveryFor") }
    }

    /// Two seconds after the last change, and never in the middle of a drag: a saved project is
    /// saved in place (or, with Auto-save off, kept in the recovery copy), and untitled work goes to the recovery copy.
    private func autosaveIfIdle() {
        guard isDirty, liveSnapshot == nil, Date().timeIntervalSince(lastEdit) > 2 else { return }
        autosaveNow()
    }

    func autosaveNow() {
        commitLive()
        if let url = fileURL, Self.autosaves {
            guard isDirty else { return }
            write(to: url)
            lastSession = url.path
        } else if let url = fileURL {
            // Auto-save off: the file is left alone, and the changes wait in the recovery copy.
            guard isDirty, lastRecovered != project else { return }
            if let data = try? JSONEncoder().encode(SavedDocument(project: project)) {
                try? data.write(to: Self.recoveryURL, options: .atomic)
                lastRecovered = project
                recoveryFor = url.path
                lastSession = url.path
            }
        } else if project.clips.isEmpty && project.assets.isEmpty {
            try? FileManager.default.removeItem(at: Self.recoveryURL)
            if lastSession == "untitled" { lastSession = nil }
        } else if isDirty, lastRecovered != project {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(SavedDocument(project: project)) {
                try? data.write(to: Self.recoveryURL, options: .atomic)
                lastRecovered = project
                recoveryFor = nil
                lastSession = "untitled"
            }
        }
    }

    /// Unsaved changes are let go: the recovery copy is removed, and the project counts as unchanged.
    func dropUnsaved() {
        try? FileManager.default.removeItem(at: Self.recoveryURL)
        recoveryFor = nil
        lastRecovered = nil
        isDirty = false
        if fileURL == nil, lastSession == "untitled" { lastSession = nil }
    }

    /// Opens whatever was being worked on last time: the project file, or untitled work from the
    /// recovery copy. Nothing to reopen leaves the empty project that's already there.
    private func restoreLastSession() {
        // Opened by dropping files on the icon: those start a new project (or are the project), so nothing reopens.
        guard AppDelegate.shared?.openedAtLaunch != true else { return }
        guard let last = lastSession else { return }
        if last == "untitled" {
            guard let data = try? Data(contentsOf: Self.recoveryURL),
                  let doc = try? JSONDecoder().decode(SavedDocument.self, from: data) else { return }
            load(doc.project, url: nil, offerLocate: true)
            lastRecovered = doc.project
            isDirty = true
        } else if FileManager.default.fileExists(atPath: last) {
            let url = URL(fileURLWithPath: last)
            open(url: url)
            // Unsaved changes to it from last time (Auto-save off) come back, still unsaved.
            if recoveryFor == last, let data = try? Data(contentsOf: Self.recoveryURL),
               var doc = try? JSONDecoder().decode(SavedDocument.self, from: data) {
                doc.project.resolveMovedMedia(projectDir: url.deletingLastPathComponent())
                load(doc.project, url: url, offerLocate: true)
                lastRecovered = doc.project
                isDirty = true
            }
        }
    }

    func open(url: URL) {
        do {
            var doc = try JSONDecoder().decode(SavedDocument.self, from: Data(contentsOf: url))
            doc.project.resolveMovedMedia(projectDir: url.deletingLastPathComponent())
            load(doc.project, url: url, offerLocate: true)
            noteRecent(url)
            // Test launches (`--open`, `--selftest`) don't change what opens next time.
            if !CommandLine.arguments.contains("--selftest"), !CommandLine.arguments.contains("--open") { lastSession = url.path }
        } catch {
            importError = "Couldn't open \(url.lastPathComponent)."
        }
    }

    var title: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    var canUndo: Bool { !undoStack.isEmpty || liveSnapshot != nil }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: Mutation & undo

    /// One undoable change.
    func mutate(_ body: (inout Project) -> Void) {
        commitLive()
        var p = project
        body(&p)
        p.sanitize()
        guard p != project else { return }
        undoStack.append(project)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        redoKnown.removeAll()
        project = p
        didChange()
    }

    /// A change that belongs to the last undo step (Magic's captions on the cut it just made): one Undo takes
    /// back both. With nothing to undo, it's a step of its own.
    func amendLastStep(_ body: (inout Project) -> Void) {
        commitLive()
        guard !undoStack.isEmpty else { return mutate(body) }
        var p = project
        body(&p)
        p.sanitize()
        guard p != project else { return }
        redoStack.removeAll()
        redoKnown.removeAll()
        project = p
        didChange()
    }

    /// Continuous change (drag, slider). Coalesces into a single undo step.
    func live(autoCommit: Bool = true, _ body: (inout Project) -> Void) {
        var p = project
        body(&p)
        guard p != project else { return }
        if liveSnapshot == nil { liveSnapshot = project }
        project = p
        isDirty = true
        setNeedsRebuild()
        liveTimer?.invalidate()
        liveTimer = nil
        if autoCommit {
            liveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.commitLive() }
            }
        }
    }

    /// Throws away a live change that hasn't been committed: back to how it was, with no undo step.
    func discardLive() {
        liveTimer?.invalidate()
        liveTimer = nil
        guard let snapshot = liveSnapshot else { return }
        liveSnapshot = nil
        project = snapshot
        setNeedsRebuild()
    }

    func commitLive() {
        liveTimer?.invalidate()
        liveTimer = nil
        guard let snapshot = liveSnapshot else { return }
        liveSnapshot = nil
        if snapshot != project {
            undoStack.append(snapshot)
            redoStack.removeAll()
        redoKnown.removeAll()
        }
    }

    func undo() {
        commitLive()
        guard var prev = undoStack.popLast() else { return }
        redoStack.append(project)
        redoKnown.append(Set(prev.assets.map(\.id)))
        // The library isn't undone (imports and relinks stay), except that items a step deleted come back.
        prev.assets = Self.restoring(prev.assets, into: project.assets)
        // Except items whose file was deleted from a linked folder, unless this step's clips use them.
        let usedThen = Set(prev.clips.compactMap(\.assetID))
        prev.assets.removeAll { droppedFromDisk.contains($0.id) && !usedThen.contains($0.id) }
        Self.keepFolders(&prev, from: project, importing: importingFolders)
        // Magic's prompt history isn't undone either.
        prev.magicHistory = project.magicHistory
        project = prev
        didChange()
    }

    /// Linked folders follow the library: those of either version that still hold something are kept.
    private static func keepFolders(_ p: inout Project, from now: Project, importing: Set<UUID>) {
        var folders = now.folders ?? []
        for f in p.folders ?? [] where !folders.contains(where: { $0.id == f.id }) { folders.append(f) }
        p.folders = folders.isEmpty ? nil : folders
        let hidden = Array(Set((p.hiddenMedia ?? []) + (now.hiddenMedia ?? [])))
        p.hiddenMedia = hidden.isEmpty ? nil : hidden
        p.pruneFolders(keeping: importing)
    }

    /// The library now, with any items from `earlier` that are missing put back where they were.
    private static func restoring(_ earlier: [MediaAsset], into now: [MediaAsset]) -> [MediaAsset] {
        let current = Dictionary(now.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let earlierIDs = Set(earlier.map(\.id))
        return earlier.map { current[$0.id] ?? $0 } + now.filter { !earlierIDs.contains($0.id) }
    }

    func redo() {
        commitLive()
        guard var next = redoStack.popLast() else { return }
        let known = redoKnown.popLast() ?? []
        undoStack.append(project)
        // Items the step deleted go again; everything else in the library stays as it is now.
        let deleted = known.subtracting(next.assets.map(\.id))
        next.assets = project.assets.filter { !deleted.contains($0.id) }
        Self.keepFolders(&next, from: project, importing: importingFolders)
        next.magicHistory = project.magicHistory
        project = next
        didChange()
    }

    private func didChange() {
        if !captionSelection.isEmpty {
            let ids = Set(captionBlocks.map(\.id))
            let valid = captionSelection.intersection(ids)
            if valid != captionSelection { captionSelection = valid }
        }
        if project.captions == nil { captionsFocused = false }
        // Muting and soloing are heard at once, not after the rebuild.
        engine.audio.setAudible(Dictionary(uniqueKeysWithValues: project.audioTracks.map { ($0.id, project.isAudible($0)) }))
        let valid = selection.intersection(Set(project.clips.map(\.id)))
        if valid != selection { selection = valid }
        isDirty = true
        // Adding or removing a video track moves the video/audio gap; keep it where it was on screen.
        let above = rowsAbove
        if lastRowsAbove > 0, above != lastRowsAbove {
            setView(scrollY: view.scrollY + above - lastRowsAbove)
        } else {
            clampView()
        }
        setNeedsRebuild()
    }

    /// Set while the magic show is building a cut, so the player isn't rebuilt every frame.
    var rebuildSuspended = false {
        didSet { if !rebuildSuspended { setNeedsRebuild() } }
    }

    func setNeedsRebuild() {
        guard !rebuildPending, !rebuildSuspended else { return }
        rebuildPending = true
        let wait = max(0, 0.03 - (CACurrentMediaTime() - lastRebuild))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated { self?.rebuildNow() }
        }
    }

    /// Applies a change waiting to be rebuilt now, so the viewer shows it before anything else moves (a zoom
    /// dot dragged on its graph: the curve first, then the playhead to the dot).
    func flushRebuild() {
        rebuildNow()
    }

    private func rebuildNow() {
        guard rebuildPending else { return }
        rebuildPending = false
        lastRebuild = CACurrentMediaTime()
        engine.rebuild(project: project, media: media, at: playhead)
        if audioScrub { scrubber.prepare(project: project, media: media) }
        if isPlaying && engine.isEmpty { isPlaying = false }
    }

    // MARK: Transport

    func tick() {
        if isPlaying {
            // Looping: the engine starts over on its own, with no pause, once it's ready to.
            engine.loopSpan = loop && project.duration > 0 ? loopSpan : nil
            engine.serviceLoop()
            playhead = engine.takeWrap() && loop ? loopSpan.start : min(engine.currentTime, max(engine.duration, 0))
            // Within a frame of the end, or stopped by the player: start over when looping (with a
            // seek, when the engine isn't ready to loop by itself yet).
            let span = loopSpan
            if loop, !engine.loopsItself, span.end > 0, playhead >= span.end - 1 / project.fps || !engine.isPlaying {
                playhead = span.start
                engine.seek(to: span.start)
                engine.play()
            }
        } else if engine.loopSpan != nil {
            engine.loopSpan = nil
        }
        clock.update(time: playhead, fps: project.fps)
        // While scrubbing with sound, the meters show what's being heard.
        if !isPlaying, let s = lastScrubSound, CACurrentMediaTime() - s.at < AudioScrubber.snippet + 0.05 {
            meters.update(project: project, media: media, time: s.time, playing: true, quickRelease: true)
        } else {
            meters.update(project: project, media: media, time: playhead, playing: isPlaying)
        }
        for handler in tickHandlers { handler() }
    }

    /// Shows just the viewer, full screen, or goes back to the editor.
    func toggleViewerFullScreen() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        viewerOnly.toggle()
        if viewerOnly { ViewerScreen.enter(window) } else { ViewerScreen.exit(window) }
        // The viewer is rebuilt in its new place; give it a frame to show while paused.
        if !isPlaying {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.engine.seek(to: self.playhead)
            }
        }
    }

    /// What Loop repeats: the in/out range when there is one, otherwise the whole timeline.
    var loopSpan: (start: Double, end: Double) {
        project.playRange ?? (0, project.duration)
    }

    // MARK: Markers and in/out

    /// The marker the timeline is showing its panel for.
    @Published var editingMarker: UUID?

    /// Adds a marker at the playhead, or opens the one already there.
    func addMarker() {
        let t = project.snapFrame(playhead)
        if let here = project.markerList.first(where: { abs($0.time - t) < 0.5 / project.fps }) {
            editingMarker = here.id
            return
        }
        let m = Marker(time: t, name: "Marker \((project.markers?.count ?? 0) + 1)")
        mutate { p in p.markers = (p.markers ?? []) + [m] }
    }

    func updateMarker(_ id: UUID, _ change: (inout Marker) -> Void) {
        mutate { p in
            guard let i = p.markers?.firstIndex(where: { $0.id == id }) else { return }
            change(&p.markers![i])
        }
    }

    /// While dragging a flag: one undo step for the whole drag.
    func updateMarkerLive(_ id: UUID, _ change: (inout Marker) -> Void) {
        live(autoCommit: false) { p in
            guard let i = p.markers?.firstIndex(where: { $0.id == id }) else { return }
            change(&p.markers![i])
        }
    }

    /// Typing a marker's name: one undo step per pause in typing.
    func renameMarker(_ id: UUID, to name: String) {
        live { p in
            guard let i = p.markers?.firstIndex(where: { $0.id == id }) else { return }
            p.markers![i].name = name
        }
    }

    func setRangeEdgeLive(isIn: Bool, to t: Double) {
        live(autoCommit: false) { p in
            if isIn { p.inPoint = t } else { p.outPoint = t }
        }
    }

    func deleteMarker(_ id: UUID) {
        if editingMarker == id { editingMarker = nil }
        mutate { p in
            p.markers?.removeAll { $0.id == id }
            if p.markers?.isEmpty == true { p.markers = nil }
        }
    }

    /// Removes every marker (one undo step).
    func clearMarkers() {
        guard !(project.markers ?? []).isEmpty else { return }
        editingMarker = nil
        mutate { p in p.markers = nil }
    }

    func setInPoint() {
        let t = project.snapFrame(playhead)
        mutate { p in
            p.inPoint = t
            if let o = p.outPoint, o <= t { p.outPoint = nil }
        }
    }

    func setOutPoint() {
        let t = project.snapFrame(playhead)
        mutate { p in
            p.outPoint = t
            if let i = p.inPoint, i >= t { p.inPoint = nil }
        }
    }

    func clearRange() {
        guard project.inPoint != nil || project.outPoint != nil else { return }
        mutate { p in p.inPoint = nil; p.outPoint = nil }
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    /// Shows the frame at a time without moving the playhead; nil goes back to the playhead's frame.
    func skim(to t: Double?) {
        guard let t else {
            if skimTime != nil {
                skimTime = nil
                if !isPlaying { engine.seek(to: playhead) }
            }
            return
        }
        guard skimming, !isPlaying else { return }
        let time = min(max(0, project.snapFrame(t)), project.duration)
        guard time != skimTime else { return }
        skimTime = time
        if !engine.showScrubFrame(at: time, cache: media.scrubCache) {
            engine.seek(to: time, fast: true)
        }
        settleSoon()
        scrubSound(at: time)
    }

    /// Space while skimming plays from where the skimmer is (the default, as in Final Cut), or from the
    /// playhead. Set in Settings > Shortcuts, under Play / Pause.
    static let playFromSkimmerKey = "playFromSkimmer"

    func play() {
        if let s = skimTime {
            if UserDefaults.standard.object(forKey: Self.playFromSkimmerKey) as? Bool ?? true {
                playhead = s
            } else {
                // The viewer was showing the skimmed frame: back to the playhead to play from there.
                engine.seek(to: playhead)
            }
        }
        skimTime = nil
        settleWork?.cancel()
        engine.endScrubFrames()
        guard project.duration > 0 else { return }
        rebuildNow()
        guard !engine.isEmpty else { return }
        let span = loopSpan
        if playhead >= project.duration - 1 / project.fps || (loop && project.playRange != nil && (playhead < span.start || playhead >= span.end - 1 / project.fps)) {
            playhead = span.start
            engine.seek(to: span.start)
        }
        // Looping: the start is made ready to follow the end right away.
        engine.loopSpan = loop ? span : nil
        engine.play()
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        engine.pause()
        engine.loopSpan = nil
        isPlaying = false
        playhead = project.snapFrame(engine.currentTime)
        engine.seek(to: playhead)
    }

    func seek(to time: Double) {
        skimTime = nil
        settleWork?.cancel()
        engine.endScrubFrames()
        if isPlaying {
            engine.pause()
            isPlaying = false
        }
        playhead = max(0, project.snapFrame(time))
        engine.seek(to: playhead)
    }

    /// Moving the playhead by dragging it: the viewer keeps up with the nearest frame it can show at
    /// once, and the exact frame follows when the drag rests for a moment or stops.
    func scrub(to time: Double) {
        skimTime = nil
        if isPlaying {
            engine.pause()
            isPlaying = false
        }
        playhead = max(0, project.snapFrame(time))
        // A frame from the made-ahead ones at once if they're there; the player's own seek otherwise.
        if !engine.showScrubFrame(at: playhead, cache: media.scrubCache) {
            engine.seek(to: playhead, fast: true)
        }
        settleSoon()
    }

    private var settleWork: DispatchWorkItem?

    /// The exact frame once scrubbing or skimming rests (the playhead's, or the skimmer's).
    private func settleSoon() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.engine.endScrubFrames()
            self.engine.seek(to: self.skimTime ?? self.playhead)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    func step(frames: Int) {
        seek(to: playhead + Double(frames) / project.fps)
    }

    func jumpToEdit(forward: Bool) {
        let points = project.editPoints
        let eps = 0.5 / project.fps
        if forward {
            if let t = points.first(where: { $0 > playhead + eps }) { seek(to: t) }
        } else {
            if let t = points.last(where: { $0 < playhead - eps }) { seek(to: t) }
        }
    }

    // MARK: Zoom

    // Every change to zoom or scroll goes through `setView`, so the canvas, the scroll bars and the
    // wheel all agree on one set of limits and nothing can fight over the position.

    /// Seconds of timeline that can be scrolled to: the content plus working room after it.
    var extent: Double { max(30, project.duration * 1.3 + 10) }

    /// Fully zoomed out shows exactly `extent`.
    var minPPS: CGFloat { max(TimelineViewState.minPPS, view.viewWidth / CGFloat(extent)) }
    var maxScrollX: CGFloat { max(0, CGFloat(extent) * view.pps - view.viewWidth) }

    var rowsContent: CGFloat {
        TimelineLayout.fixedHeight + TimelineLayout.captionSpace(project)
            + CGFloat(project.videoTracks.count + project.audioTracks.count) * (view.rowHeight + TimelineLayout.gap)
    }
    var rowsVisible: CGFloat { max(40, view.viewHeight - TimelineLayout.ruler) }

    /// Distance from the top of the tracks to the middle of the gap between video and audio.
    /// That gap is the vertical "home" of the timeline: the centre of the scroll bar.
    var rowsAbove: CGFloat {
        TimelineLayout.captionSpace(project) + TimelineLayout.zone
            + CGFloat(project.videoTracks.count) * (view.rowHeight + TimelineLayout.gap) + TimelineLayout.divider / 2
    }

    /// The vertical bar is a window onto a taller "world" whose middle is the video/audio gap, so a
    /// centred thumb always puts that gap in the middle of the view, however many tracks are on
    /// either side. The world is at least big enough to reach both ends of the tracks, and grows as
    /// rows get taller so the thumb's length shows the zoom.
    var rowsWorld: CGFloat {
        let zoomed = rowsVisible * view.rowHeight / TimelineViewState.rowRange.lowerBound
        return max(rowsVisible, zoomed, 2 * rowsAbove, 2 * (rowsContent - rowsAbove))
    }

    /// Fraction of the vertical bar the thumb covers.
    var rowWindow: CGFloat { rowsVisible / rowsWorld }

    /// The same fraction as it would be at another row height.
    func rowWindow(rowHeight r: CGFloat) -> CGFloat {
        let tracks = CGFloat(project.videoTracks.count + project.audioTracks.count)
        let captions = TimelineLayout.captionSpace(project)
        let above = captions + TimelineLayout.zone + CGFloat(project.videoTracks.count) * (r + TimelineLayout.gap) + TimelineLayout.divider / 2
        let content = TimelineLayout.fixedHeight + captions + tracks * (r + TimelineLayout.gap)
        let zoomed = rowsVisible * r / TimelineViewState.rowRange.lowerBound
        return rowsVisible / max(rowsVisible, zoomed, 2 * above, 2 * (content - above))
    }

    /// `scrollY` is how far the top of the tracks is above the top of the view; it goes negative
    /// when the tracks sit lower than the top.
    var minScrollY: CGFloat { rowsAbove - rowsWorld / 2 }
    var maxScrollY: CGFloat { rowsAbove + rowsWorld / 2 - rowsVisible }
    var centeredScrollY: CGFloat { rowsAbove - rowsVisible / 2 }

    /// A point in the tracks split into fixed-height space above it (ruler zones, gaps, the divider)
    /// and how many rows' worth of height lie above it, so it can be found again at another row height:
    /// `fixed + rows * rowHeight`.
    func rowAnchor(at y: CGFloat) -> (fixed: CGFloat, rows: CGFloat) {
        let r = view.rowHeight
        var segments: [(length: CGFloat, row: Bool)] = [(TimelineLayout.zone, false)]
        for _ in project.videoTracks { segments += [(r, true), (TimelineLayout.gap, false)] }
        segments.append((TimelineLayout.divider, false))
        for _ in project.audioTracks { segments += [(r, true), (TimelineLayout.gap, false)] }
        segments.append((TimelineLayout.zone, false))
        var fixed = min(0, y), rows: CGFloat = 0, pos: CGFloat = 0
        for s in segments {
            let take = min(max(y - pos, 0), s.length)
            if s.row { rows += take / r } else { fixed += take }
            pos += s.length
        }
        fixed += max(0, y - pos)
        return (fixed, rows)
    }

    func centerRows() {
        setView(scrollY: centeredScrollY)
    }

    /// How a timeline opens (at launch, and when a project opens): rows as tall as fit the panel with every
    /// track and the add-track zones above and below in view (no taller than usual, no shorter than the
    /// smallest), centred. When they can't all fit, the tracks start at the top (the add-video zone first), with
    /// no empty space above, and the rest are scrolled to.
    func fitRows() {
        // The track headers run on past the timeline, alongside the scroll bar under it: the add-audio zone,
        // only a label on the headers' side, can sit level with the bar.
        let visible = rowsVisible + RangeBarStyle.thickness
        let tracks = CGFloat(max(1, project.videoTracks.count + project.audioTracks.count))
        let room = visible - TimelineLayout.fixedHeight - TimelineLayout.captionSpace(project) - 6
        setView(rowHeight: min(62, room / tracks - TimelineLayout.gap))
        if rowsContent <= visible {
            setView(scrollY: (rowsContent - visible) / 2)
        } else {
            setView(scrollY: 0)
        }
    }

    func setView(pps: CGFloat? = nil, scrollX: CGFloat? = nil, scrollY: CGFloat? = nil, rowHeight: CGFloat? = nil) {
        if let rowHeight {
            let r = min(TimelineViewState.rowRange.upperBound, max(TimelineViewState.rowRange.lowerBound, rowHeight.rounded()))
            if r != view.rowHeight { view.rowHeight = r }
        }
        let p = min(TimelineViewState.maxPPS, max(minPPS, pps ?? view.pps))
        if p != view.pps { view.pps = p }
        let x = min(max(0, scrollX ?? view.scrollX), maxScrollX)
        if x != view.scrollX { view.scrollX = x }
        let y = min(max(minScrollY, scrollY ?? view.scrollY), maxScrollY)
        if y != view.scrollY { view.scrollY = y }
        lastRowsAbove = rowsAbove
    }

    func clampView() { setView() }

    private var lastRowsAbove: CGFloat = 0

    /// Zooms around the playhead: it keeps its place on screen, or is brought to the centre if it was off screen.
    func setZoom(_ newPPS: CGFloat) {
        let old = view.pps
        let pps = min(TimelineViewState.maxPPS, max(minPPS, newPPS))
        guard abs(pps - old) > 1e-9 else { return }
        let px = CGFloat(playhead) * old - view.scrollX
        let anchor = (px >= 0 && px <= view.viewWidth) ? px : view.viewWidth / 2
        setView(pps: pps, scrollX: CGFloat(playhead) * pps - anchor)
    }

    func zoom(by factor: CGFloat) {
        setZoom(view.pps * factor)
    }

    func zoomToFit() {
        let d = max(project.duration, 1)
        setView(pps: (view.viewWidth - 80) / CGFloat(d), scrollX: 0)
    }

    // MARK: Import

    static var importTypes: [UTType] { MediaFolder.types }

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = Self.importTypes
        panel.prompt = "Import"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// `offerMatch` asks about matching the sequence to the first video; off for imports by an agent.
    /// A folder brings in everything in it (and in the folders inside it) and stays linked to it: the Media
    /// panel shows it as a folder, and files added to it later come in too.
    func importFiles(_ urls: [URL], offerMatch offer: Bool = true, then completion: (([MediaAsset]) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        importCount += 1
        Task {
            var files: [String] = []
            var linked: [MediaFolder] = []
            var opened: String?
            for url in urls {
                let path = url.standardizedFileURL.path
                let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
                if MediaFolder.isFolder(path), !isPackage {
                    let (folder, nested) = linkFolder(path)
                    if let folder { linked.append(folder); importingFolders.insert(folder.id) }
                    if nested { opened = path }
                    files += await Task.detached { MediaFolder.mediaFiles(in: path) }.value.filter { !project.isHidden($0) }
                } else {
                    // Brought in by hand: no longer left out of its folder.
                    project.hiddenMedia?.removeAll { MediaFolder.contains($0, path) }
                    files.append(path)
                }
            }
            importCount += files.count
            importCount -= 1
            var imported: [MediaAsset] = []
            var failed: [String] = []
            for path in files {
                defer { importCount -= 1 }
                if let existing = project.assets.first(where: { $0.path == path }) {
                    imported.append(existing)
                    continue
                }
                guard !pendingImports.contains(path) else { continue }
                pendingImports.insert(path)
                defer { pendingImports.remove(path) }
                if var asset = await media.importFile(URL(fileURLWithPath: path)) {
                    asset.bookmark = Bookmark.make(path)
                    project.assets.append(asset)
                    isDirty = true
                    imported.append(asset)
                    if offer { offerMatch(asset) }
                } else {
                    // Not tried again when its folder is next looked at.
                    unreadable.insert(path)
                    failed.append(URL(fileURLWithPath: path).lastPathComponent)
                }
            }
            for f in linked { importingFolders.remove(f.id) }
            let before = project.folders
            project.pruneFolders(keeping: importingFolders)
            for f in linked where project.folders?.contains(where: { $0.id == f.id }) != true {
                importError = "There's no media in “\(f.name)”."
            }
            if project.folders != before { objectWillChange.send() }
            if !failed.isEmpty {
                let hint = FFmpeg.binary == nil ? " Install ffmpeg to import formats macOS can't decode." : ""
                let shown = failed.prefix(8).joined(separator: ", ") + (failed.count > 8 ? " and \(failed.count - 8) more" : "")
                importError = "Couldn't import " + shown + "." + hint
            }
            // Brought in by hand (not by an agent, or found in a linked folder): shown where it sits in Media,
            // picked and scrolled to, so it's clear what came in.
            if offer { showImported(imported, folders: linked, opened: opened) }
            completion?(imported)
        }
    }

    /// Nothing picked in Media (after a drop on the timeline, say: the new clips there are what's picked).
    func clearMediaPicks() {
        mediaSelection = []
        folderSelection = []
        incomingSelection = []
    }

    /// The library item behind the clip selected on the timeline (the first, if several), for Reveal in Media.
    var revealableAsset: MediaAsset? {
        project.clips.filter { selection.contains($0.id) }.sorted { $0.start < $1.start }
            .lazy.compactMap { $0.assetID.flatMap { self.project.asset($0) } }.first
    }

    /// Reveal in Media (⇧F, as Final Cut's Reveal in Browser): the clip's file is opened in Media, in its folder,
    /// picked and scrolled to. The timeline's selection is left as it is.
    func revealInMedia(_ clipID: UUID? = nil) {
        let asset = clipID.flatMap { project.clip($0)?.assetID }.flatMap { project.asset($0) } ?? revealableAsset
        guard let asset else { return }
        mediaFolder = MediaTree(project).folder(of: asset)
        mediaSelection = [asset.id]
        folderSelection = []
        incomingSelection = []
        mediaAnchor = .asset(asset.id)
        mediaReveal = MediaReveal(target: .asset(asset.id))
    }

    /// Opens the folder an import landed in, picks what came in and asks the Media panel to scroll to it: a new
    /// linked folder's tile, or the files (those in the same folder as the first, when they're spread out).
    private func showImported(_ assets: [MediaAsset], folders: [MediaFolder], opened: String?) {
        // Not while the mouse is down (a file that came in first, grabbed and being dragged while the rest
        // were still coming): opening its folder or scrolling would move it out from under the pointer, and the drag
        // would be lost.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let tree = MediaTree(project)
        if let opened, tree.exists(opened) {
            mediaFolder = opened
            mediaSelection = []
            folderSelection = []
            return
        }
        let roots = folders.filter { f in project.folders?.contains { $0.id == f.id } == true }
        if let first = roots.first {
            mediaFolder = nil
            mediaSelection = Set(assets.filter { tree.folder(of: $0) == nil }.map(\.id))
            folderSelection = Set(roots.map(\.path))
            mediaAnchor = .folder(first.path)
            mediaReveal = MediaReveal(target: .folder(first.path))
            return
        }
        guard let a = assets.first(where: { project.asset($0.id) != nil }) else { return }
        let place = tree.folder(of: a)
        mediaFolder = place
        mediaSelection = Set(assets.filter { tree.folder(of: $0) == place }.map(\.id))
        folderSelection = []
        mediaAnchor = .asset(a.id)
        mediaReveal = MediaReveal(target: .asset(a.id))
    }

    /// Starts following a folder brought in whole. Returns the new linked folder, or nil when it's already
    /// inside one (`nested`). Linked folders inside it become part of it.
    private func linkFolder(_ path: String) -> (MediaFolder?, nested: Bool) {
        // Everything left out of it comes back: it was brought in again on purpose.
        project.hiddenMedia?.removeAll { MediaFolder.contains(path, $0) || MediaFolder.contains($0, path) }
        if project.hiddenMedia?.isEmpty == true { project.hiddenMedia = nil }
        if project.linkedFolder(holding: path) != nil { return (nil, true) }
        let folder = MediaFolder(path: path, bookmark: Bookmark.make(path))
        var list = (project.folders ?? []).filter { !MediaFolder.contains(path, $0.path) }
        list.append(folder)
        project.folders = list
        isDirty = true
        return (folder, false)
    }

    // MARK: Folders on disk

    /// Brings the Media panel up to date with the disk: linked folders and files that were renamed or
    /// moved on their drive are followed, and files added to linked folders come in. Run when Editroom
    /// comes back to the front, when a project opens, and from Reload Folder from Disk.
    func syncFolders() async {
        guard !syncingFolders else { return }
        syncingFolders = true
        defer { syncingFolders = false }
        var p = project
        var moved = Set<UUID>()
        for f in p.folders ?? [] where !MediaFolder.isFolder(f.path) {
            guard let now = Bookmark.resolve(f.bookmark), MediaFolder.isFolder(now) else { continue }
            moved.formUnion(p.assets.filter { MediaFolder.contains(f.path, $0.path) }.map(\.id))
            p.movePaths(from: f.path, to: now)
        }
        for i in p.assets.indices where !FileManager.default.fileExists(atPath: p.assets[i].path) {
            guard let now = Bookmark.resolve(p.assets[i].bookmark), now != p.assets[i].path else { continue }
            // Renamed: the new name shows, unless it was given a name of its own.
            let wasNamed = URL(fileURLWithPath: p.assets[i].path).deletingPathExtension().lastPathComponent
            if p.assets[i].name == wasNamed { p.assets[i].name = URL(fileURLWithPath: now).deletingPathExtension().lastPathComponent }
            p.assets[i].path = now
            moved.insert(p.assets[i].id)
        }
        if p.assets != project.assets || p.folders != project.folders || p.hiddenMedia != project.hiddenMedia {
            commitLive()
            project.assets = p.assets
            project.folders = p.folders
            project.hiddenMedia = p.hiddenMedia
            isDirty = true
            if let open = mediaFolder, !MediaTree(project).exists(open) { mediaFolder = nil }
        }
        if !moved.isEmpty { await reopenMedia(moved) }
        // Replaced with the same name in another format (beach.mp4 deleted, beach.mov saved beside it): the item takes
        // the new file, keeping its clips, as Locate would. Only when that one file is the obvious match.
        await adoptReplacements()
        // Deleted from a linked folder on disk (or put in the Trash) and not used on the timeline: gone from Media too,
        // as from the folder. Used ones stay, shown missing, so the edit doesn't lose a clip without a word. (The
        // folder itself has to be there: a whole linked folder gone is found again with Locate.)
        let used = Set(project.clips.compactMap(\.assetID))
        let gone = Set(project.assets.filter { a in
            !used.contains(a.id) && !FileManager.default.fileExists(atPath: a.path)
                && project.linkedFolder(holding: a.path).map { MediaFolder.isFolder($0.path) } == true
        }.map(\.id))
        if !gone.isEmpty {
            commitLive()
            project.assets.removeAll { gone.contains($0.id) }
            droppedFromDisk.formUnion(gone)
            mediaSelection.subtract(gone)
            isDirty = true
            if let open = mediaFolder, !MediaTree(project).exists(open) {
                let tree = MediaTree(project)
                var up: String? = open
                while let u = up, !tree.exists(u) { up = tree.root(of: u) == nil ? nil : (u as NSString).deletingLastPathComponent }
                mediaFolder = up
            }
        }
        var added: [URL] = []
        for f in project.folders ?? [] where MediaFolder.isFolder(f.path) {
            let path = f.path
            let files = await Task.detached { MediaFolder.mediaFiles(in: path) }.value
            let have = Set(project.assets.map(\.path))
            added += files.filter { !have.contains($0) && !project.isHidden($0) && !pendingImports.contains($0) && !unreadable.contains($0) }
                .map { URL(fileURLWithPath: $0) }
        }
        if !added.isEmpty { importFiles(added, offerMatch: false) }
    }

    /// While another app writes files it promised (Photos fetching from iCloud): the Media spinner shows.
    func beginWaitingForFiles() { importCount += 1 }
    func endWaitingForFiles() { importCount = max(0, importCount - 1) }

    /// A library item's file is somewhere else now (moved by Editroom itself).
    func repointAsset(at i: Int, to path: String) {
        project.assets[i].path = path
        project.assets[i].bookmark = Bookmark.make(path)
    }

    /// Items whose files were moved by Editroom itself (held copies going beside a newly saved project).
    func reopenMovedMedia(_ ids: Set<UUID>) async { await reopenMedia(ids) }

    /// Items whose file is gone, with exactly one media file of the same name (another extension) beside where it was,
    /// that nothing else in the project uses: pointed at that file. Undo history is kept (the library isn't undone).
    func adoptReplacements() async {
        let fm = FileManager.default
        let used = Set(project.assets.map(\.path))
        var taken = Set<String>()
        for old in project.assets where !fm.fileExists(atPath: old.path) {
            let gone = URL(fileURLWithPath: old.path)
            let dir = gone.deletingLastPathComponent()
            let stem = gone.deletingPathExtension().lastPathComponent.lowercased()
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            let matches = names.map { dir.appendingPathComponent($0) }.filter { u in
                u.deletingPathExtension().lastPathComponent.lowercased() == stem && u.pathExtension.lowercased() != gone.pathExtension.lowercased()
                    && MediaFolder.isMedia(u) && !used.contains(u.standardizedFileURL.path) && !taken.contains(u.standardizedFileURL.path)
            }
            guard matches.count == 1, let url = matches.first,
                  var fresh = await media.importFile(url, replacing: old),
                  let i = project.assets.firstIndex(where: { $0.id == old.id }) else { continue }
            taken.insert(url.standardizedFileURL.path)
            fresh.bookmark = Bookmark.make(fresh.path)
            fresh.relativePath = nil
            commitLive()
            project.assets[i] = fresh
            isDirty = true
            mutate { $0.fitClips(toMedia: [old.id]) }
        }
        objectWillChange.send()
        setNeedsRebuild()
    }

    /// Opens items again at their new place on disk (after a rename or a move).
    private func reopenMedia(_ ids: Set<UUID>) async {
        for id in ids {
            guard let old = project.asset(id), FileManager.default.fileExists(atPath: old.path),
                  var fresh = await media.importFile(URL(fileURLWithPath: old.path), replacing: old),
                  let i = project.assets.firstIndex(where: { $0.id == id }) else { continue }
            fresh.bookmark = Bookmark.make(fresh.path)
            fresh.relativePath = old.relativePath
            project.assets[i] = fresh
        }
        sourcePreview.clear()
        objectWillChange.send()
        setNeedsRebuild()
    }

    /// Asks where a linked folder that's gone missing is now; everything in it is found there.
    func locateFolder(_ id: UUID) {
        guard let f = project.folders?.first(where: { $0.id == id }) else { return }
        let panel = NSOpenPanel()
        panel.message = "Locate the folder “\(f.name)”"
        panel.prompt = "Locate"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await relinkFolder(f.path, to: url.standardizedFileURL.path)
            if !missingAssets.isEmpty { offerToLocateMissing() }
        }
    }

    /// Points a linked folder, and everything in it, at where it is now.
    private func relinkFolder(_ old: String, to new: String) async {
        commitLive()
        let ids = Set(project.assets.filter { MediaFolder.contains(old, $0.path) }.map(\.id))
        project.movePaths(from: old, to: new)
        if let i = project.folders?.firstIndex(where: { $0.path == new }) { project.folders?[i].bookmark = Bookmark.make(new) }
        isDirty = true
        if let open = mediaFolder, MediaFolder.contains(old, open) { mediaFolder = new + open.dropFirst(old.count) }
        await reopenMedia(ids)
        await syncFolders()
    }

    /// Reload Folder from Disk: follows renames and moves, brings in new files, and opens everything in the
    /// folder again as it is on disk now.
    func reloadFolder(_ folder: String) async {
        await syncFolders()
        let ids = Set(MediaTree(project).assets(under: folder, of: project.assets).map(\.id))
        await reloadMedia(ids)
    }

    /// Takes a folder in the Media panel out of the project, with everything in it (the files stay on disk).
    func removeFolder(_ folder: String) { removeAssets([], folders: [folder]) }

    /// Asked once, on the first video brought into a project: adopt its frame size and rate?
    private func offerMatch(_ asset: MediaAsset) {
        guard asset.kind == .video, !project.settingsLocked, asset.width > 0, asset.height > 0 else { return }
        let fps = Self.standardFPS(asset.fps)
        project.settingsLocked = true
        if asset.width == project.width, asset.height == project.height, fps == project.fps { return }
        let alert = EditroomAlert()
        alert.messageText = "Match the sequence to “\(asset.name)”?"
        alert.informativeText = "\(asset.width) × \(asset.height) · \(InspectorView.fpsLabel(fps))\nThe sequence is currently \(project.width) × \(project.height) · \(InspectorView.fpsLabel(project.fps))."
        alert.addButton(withTitle: "Match")
        // Esc keeps the sequence as it is.
        alert.addButton(withTitle: "Keep Current").keyEquivalent = "\u{1b}"
        let match = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            self?.mutate { p in
                p.width = asset.width
                p.height = asset.height
                p.fps = fps
            }
        }
        // Over the editor without holding it up: more files dropped on the window while it's up (or a click on its
        // way as it opened) are taken in rather than turned away with a beep.
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            alert.show(over: window, then: match)
        } else {
            match(alert.runModal())
        }
    }

    /// Prompts sent with Magic in this project, newest first.
    var magicHistory: [MagicHistory.Entry] { project.magicHistory ?? [] }

    /// Keeps a prompt just sent with Magic in the project. Not an undoable edit.
    func addMagicPrompt(_ text: String, tab: MagicAgent.Tab) {
        guard let list = MagicHistory.adding(text, tab: tab, to: magicHistory) else { return }
        project.magicHistory = list
        isDirty = true
    }

    /// Remembers where exports go. Not an undoable edit.
    func setExportTarget(name: String, directory: String) {
        guard project.exportName != name || project.exportDir != directory else { return }
        project.exportName = name
        project.exportDir = directory
        isDirty = true
    }

    /// Renders the frame under the playhead, for previews.
    func snapshot(at time: Double? = nil) async -> NSImage? {
        await snapshot(of: project, at: time ?? playhead)
    }

    /// Renders a frame of any version of the project (an agent's Magic draft, say).
    func snapshot(of p: Project, at time: Double) async -> NSImage? {
        let scale = min(1, 640 / CGFloat(max(p.width, p.height)))
        let size = CGSize(width: max(2, (CGFloat(p.width) * scale / 2).rounded() * 2),
                          height: max(2, (CGFloat(p.height) * scale / 2).rounded() * 2))
        guard let built = CompositionBuilder.build(project: p, media: media, renderSize: size, includeAudio: false) else { return nil }
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let t = min(max(0, time), max(0, built.duration - 1 / p.fps))
        guard let cg = try? await generator.image(at: CompositionBuilder.time(t)).image else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    /// A click on a Media panel item. `order` is the items as shown, for ⇧-click ranges.
    func clickMedia(_ id: MediaPick, in order: [MediaPick]) {
        let flags = NSEvent.modifierFlags
        var picked = Set(mediaSelection.map(MediaPick.asset)).union(folderSelection.map(MediaPick.folder))
            .union(incomingSelection.map(MediaPick.incoming))
        if flags.contains(.shift), let anchor = mediaAnchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
            picked = Set(order[min(a, b)...max(a, b)])
        } else if flags.contains(.command) {
            if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
            mediaAnchor = id
        } else {
            picked = [id]
            mediaAnchor = id
        }
        mediaSelection = Set(picked.compactMap { if case .asset(let a) = $0 { a } else { nil } })
        folderSelection = Set(picked.compactMap { if case .folder(let f) = $0 { f } else { nil } })
        incomingSelection = Set(picked.compactMap { if case .incoming(let i) = $0 { i } else { nil } })
        // One thing selected at a time: Delete then means these.
        selection = []
        // Out of the search field, so Delete reaches the editor rather than the text.
        if NSApp.keyWindow?.firstResponder is NSText { NSApp.keyWindow?.makeFirstResponder(nil) }
    }

    func removeAsset(_ id: UUID) { removeAssets([id]) }

    /// Takes items out of the project (the files stay where they are), with any clips that use them.
    /// One undo brings them all back. Asks first when that would take clips off the timeline.
    /// `folders`: whole folders in the Media panel going too, with everything in them.
    func removeAssets(_ picked: Set<UUID>, folders: Set<String> = []) {
        let tree = MediaTree(project)
        let inFolders = Set(folders.flatMap { tree.assets(under: $0, of: project.assets).map(\.id) })
        // Items picked on their own (not in a folder that's going).
        let loose = picked.subtracting(inFolders)
        let ids = loose.union(inFolders)
        if ids.isEmpty {
            // Folders with nothing in them (missing ones, say): just let go.
            guard !folders.isEmpty else { return }
            project.folders?.removeAll { folders.contains($0.path) }
            project.pruneFolders(keeping: importingFolders)
            isDirty = true
            folderSelection.subtract(folders)
            objectWillChange.send()
            return
        }
        let used = project.clips.filter { $0.assetID.map(ids.contains) == true }
        // A video and its linked sound count as one clip, as they look on the timeline.
        let clipCount = Set(used.map { $0.linkID ?? $0.id }).count
        if !used.isEmpty {
            let names = project.assets.filter { loose.contains($0.id) }.map(\.name) + folders.map { tree.name($0) }
            let alert = EditroomAlert()
            alert.messageText = names.count == 1
                ? (folders.isEmpty ? "Delete “\(names[0])”?" : "Delete the folder “\(names[0])”?")
                : "Delete \(names.count) items?"
            alert.informativeText = "\(clipCount) clip\(clipCount == 1 ? " on the timeline uses" : "s on the timeline use") \(names.count == 1 ? "it" : "them") and will be deleted too. The files stay on your Mac, and Undo brings everything back."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let importing = importingFolders
        mutate { p in
            // Files in a linked folder are left out of it from now on, so they don't come back.
            var hidden = p.hiddenMedia ?? []
            for folder in folders {
                if p.folders?.contains(where: { $0.path == folder }) == true {
                    p.folders?.removeAll { $0.path == folder }
                } else {
                    hidden.append(folder)
                }
            }
            hidden += p.assets.filter { loose.contains($0.id) && p.linkedFolder(holding: $0.path) != nil }.map(\.path)
            p.hiddenMedia = hidden.isEmpty ? nil : hidden
            p.clips.removeAll { $0.assetID.map(ids.contains) == true }
            p.assets.removeAll { ids.contains($0.id) }
            p.pruneFolders(keeping: importing)
        }
        mediaSelection.subtract(ids)
        folderSelection = folderSelection.filter { f in !folders.contains { MediaFolder.contains($0, f) } }
        if let open = mediaFolder, !MediaTree(project).exists(open) {
            // Back up to the nearest folder that's still there.
            let tree = MediaTree(project)
            var up: String? = open
            while let u = up, !tree.exists(u) { up = tree.root(of: u) == nil ? nil : (u as NSString).deletingLastPathComponent }
            mediaFolder = up
        }
        selection = selection.filter { project.clip($0) != nil }
    }

    /// Delete: the picked Media panel items if there are any, otherwise what's selected on the timeline.
    func deleteSelected(ripple: Bool = false) {
        // Picked placeholders: their imports are cancelled. Media's picks come before the timeline's, as ever.
        let cancelling = incomingSelection
        if !cancelling.isEmpty { cancelIncoming(cancelling) }
        if !mediaSelection.isEmpty || !folderSelection.isEmpty {
            removeAssets(mediaSelection, folders: folderSelection)
        } else if cancelling.isEmpty {
            deleteSelection(ripple: ripple)
        }
    }

    // MARK: Adding clips

    func payloadDuration(_ payload: DragPayload) -> Double {
        if case .asset(let id) = payload, let a = project.asset(id), a.kind != .image {
            return max(1 / project.fps, floor(a.duration * project.fps + 1e-6) / project.fps)
        }
        return 5
    }

    /// Builds the clip (or linked video + audio pair) a payload produces.
    func makeClips(_ payload: DragPayload, at start: Double, videoTrack: UUID, audioTrack: UUID) -> [Clip] {
        let dur = payloadDuration(payload)
        switch payload {
        case .solid:
            return [Clip(trackID: videoTrack, kind: .solid, start: start, duration: dur)]
        case .text:
            return [Clip(trackID: videoTrack, kind: .text, start: start, duration: dur)]
        case .asset(let id):
            guard let a = project.asset(id) else { return [] }
            switch a.kind {
            case .image:
                return [Clip(trackID: videoTrack, kind: .image, assetID: id, start: start, duration: dur)]
            case .audio:
                return [Clip(trackID: audioTrack, kind: .audio, assetID: id, start: start, duration: dur)]
            case .video:
                var v = Clip(trackID: videoTrack, kind: .video, assetID: id, start: start, duration: dur)
                guard a.hasAudio else { return [v] }
                let link = UUID()
                v.linkID = link
                var au = Clip(trackID: audioTrack, kind: .audio, assetID: id, start: start, duration: dur)
                au.linkID = link
                return [v, au]
            }
        }
    }

    func insert(_ clips: [Clip]) {
        guard !clips.isEmpty else { return }
        let ids = Set(clips.map(\.id))
        mutate { p in
            p.clips.append(contentsOf: clips)
            p.materializeTokens()
            p.resolveOverlaps(keeping: ids)
        }
        selection = ids
    }

    func addAtPlayhead(_ payload: DragPayload) {
        let dur = payloadDuration(payload)
        // Text and solids never cover anything: the first open video track at the playhead, or else
        // the first gap after it.
        if payload == .text || payload == .solid {
            if let spot = project.firstFreeVideoSpot(from: playhead, duration: dur) {
                insert(makeClips(payload, at: spot.start, videoTrack: spot.track, audioTrack: project.audioTracks.first?.id ?? TrackToken.newAudio))
            } else {
                insert(makeClips(payload, at: playhead, videoTrack: TrackToken.newVideo, audioTrack: TrackToken.newAudio))
            }
            return
        }
        let start = playhead
        let v = project.freeTrack(.video, start: start, duration: dur) ?? TrackToken.newVideo
        let a = project.freeTrack(.audio, start: start, duration: dur) ?? TrackToken.newAudio
        insert(makeClips(payload, at: start, videoTrack: v, audioTrack: a))
    }

    static let frameRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60, 100, 119.88, 120]

    static func standardFPS(_ fps: Double) -> Double {
        guard fps > 1 else { return 30 }
        return frameRates.min { abs($0 - fps) < abs($1 - fps) } ?? 30
    }

    // MARK: Editing commands

    func deleteSelection(ripple: Bool = false) {
        if selection.isEmpty, !captionSelection.isEmpty { return deleteSelectedCaptions() }
        guard !selection.isEmpty else { return }
        let ids = project.unlocked(project.linked(selection))
        guard !ids.isEmpty else { return }
        mutate { $0.remove(ids: ids, ripple: ripple) }
    }

    func splitAtPlayhead() {
        let t = playhead
        let under = project.clips.filter { $0.start < t && $0.end > t }
        let selected = under.filter { selection.contains($0.id) }
        let targets = project.unlocked(project.linked(Set((selected.isEmpty ? under : selected).map(\.id))))
        guard !targets.isEmpty else { return }
        mutate { p in _ = p.split(ids: targets, at: t) }
    }

    /// Ripple Trim (Q and W, as in Premiere): takes out the clip under the playhead from its start up to the
    /// playhead (`head`), or from the playhead to its end, and closes the gap. With clips under the playhead
    /// selected, only their tracks (and their linked audio or video) change; otherwise every track does, so
    /// music and other layers stay in sync. After a head trim the playhead lands on the new edit.
    func rippleTrim(head: Bool) {
        // While playing, trim where it's playing now and carry on playing afterwards.
        let wasPlaying = isPlaying
        pause()
        guard let (a, b, tracks) = rippleTrimRange(head: head) else {
            if wasPlaying { play() }
            return
        }
        mutate { $0.rippleRemove(from: a, to: b, tracks: tracks) }
        if head { seek(to: a) }
        if wasPlaying { play() }
    }

    var canRippleTrim: Bool { rippleTrimRange(head: true) != nil || rippleTrimRange(head: false) != nil }

    private func rippleTrimRange(head: Bool) -> (Double, Double, Set<UUID>)? {
        let t = playhead
        let p = project
        let under = p.clips.filter { $0.start < t && $0.end > t && !p.isLocked($0.trackID) }
        let selected = under.filter { selection.contains($0.id) }
        let tracks: Set<UUID>
        if selected.isEmpty {
            tracks = Set((p.videoTracks + p.audioTracks).map(\.id))
        } else {
            let ids = p.linked(Set(selected.map(\.id)))
            tracks = Set(p.clips.filter { ids.contains($0.id) }.map(\.trackID))
        }
        let edges = under.filter { tracks.contains($0.trackID) }
        guard !edges.isEmpty else { return nil }
        // The nearest edit before (or after) the playhead on those tracks.
        let range = head ? (edges.map(\.start).max()!, t) : (t, edges.map(\.end).min()!)
        guard range.1 - range.0 >= 0.5 / p.fps else { return nil }
        return (range.0, range.1, tracks.filter { !p.isLocked($0) })
    }

    // MARK: Zoom

    /// Set while a speed or zoom dot is dragged in the inspector: the playhead, which follows the dot, shows
    /// its time on the timeline as when it's dragged itself.
    @Published var showPlayheadTime = false

    /// The zoom button on Scale: on, the clip moves between the full frame and its Scale over its length
    /// (zoomed to 200% if it was at 100%); off, its Scale stays as a plain size.
    func toggleZoom(_ id: UUID) {
        guard let c = project.clip(id), c.isTransformable else { return }
        if c.transform?.zoom != nil {
            mutate { p in
                guard let i = p.index(of: id) else { return }
                p.clips[i].transform?.zoom = nil
                if p.clips[i].transform?.isIdentity == true { p.clips[i].transform = nil }
            }
            return
        }
        mutate { p in
            guard let i = p.index(of: id) else { return }
            var t = p.clips[i].transform ?? ClipTransform()
            if t.scale <= 1.01 { t.scale = 2 }
            t.zoom = .starter(ZoomMove.lastMode, length: p.clips[i].duration)
            p.clips[i].transform = t
        }
        showZoomed(id)
    }

    /// Moves the playhead to where a zooming clip is all the way in, so its framing can be set on the
    /// picture it zooms into. Leaves it if it's there already, and never while playing.
    func showZoomed(_ id: UUID) {
        guard !isPlaying, let c = project.clip(id), let z = c.transform?.zoom else { return }
        let u = playhead - c.start
        if u >= 0, u < c.duration, z.amount(at: u) > 0.999 { return }
        seek(to: c.start + z.zoomedTime(length: c.duration))
    }

    func split(clip id: UUID, at t: Double) {
        let targets = project.linked([id])
        mutate { p in _ = p.split(ids: targets, at: t) }
    }

    func detachAudio() {
        let ids = selection
        mutate { $0.unlink(ids: ids) }
    }

    var selectionIsLinked: Bool {
        project.clips.contains { selection.contains($0.id) && $0.linkID != nil }
    }

    func selectAll() {
        selection = Set(project.clips.map(\.id))
        // Even when every clip was already picked (so the selection didn't change): Media lets go.
        clearMediaPicks()
        // The timeline has the keys now (out of the Media search, say), so Delete reaches the clips.
        if let timeline = TimelineCanvas.current, let window = timeline.window { window.makeFirstResponder(timeline) }
    }

    // MARK: Captions

    /// The captions as they show: each captioned clip's words, in short phrases where they're said.
    var captionBlocks: [CaptionBlock] {
        guard project.captions != nil else { return [] }
        var h = Hasher()
        h.combine(project.captionedClips)
        h.combine(project.captionFixes)
        h.combine(project.captions?.layer)
        h.combine(project.subtitleRevision)
        h.combine(transcriptVersion)
        let key = h.finalize()
        if let c = captionCache, c.key == key { return c.blocks }
        let blocks = CaptionLayout.blocks(project) { media.transcript($0.id) }
        captionCache = (key, blocks)
        return blocks
    }

    /// Clips that will have captions once what's said in them has been heard.
    var captionsWaiting: Bool {
        project.captionedClips.contains { c in
            guard let id = c.assetID, let url = media.soundURL(id) else { return false }
            let state = Transcripts.shared.state(for: url)
            return state == .waiting || state == .working
        }
    }

    /// Clip › Add Captions: the picked clips' speech, or with nothing picked, every clip of people
    /// talking (sound from video files, and voiceover tracks). Their transcripts are made first if needed.
    /// Returns how many clips were captioned.
    @discardableResult
    func addCaptions(to ids: Set<UUID>? = nil) -> Int {
        let picked = ids ?? selection
        // Everything picked (⌘A), or nothing: everyone talking, not the music.
        let everything = picked.isEmpty || picked.isSuperset(of: Set(project.clips.map(\.id)))
        let targets = project.unlocked(everything ? project.defaultCaptionTargets : project.captionTargets(picked))
        guard !targets.isEmpty else { return 0 }
        for c in project.clips where targets.contains(c.id) {
            if let id = c.assetID, let url = media.soundURL(id) { Transcripts.shared.make(url, soon: true) }
        }
        mutate { $0.addCaptions(targets) }
        return targets.count
    }

    /// Clip › Add Captions, or Remove Captions when the picked clips have them.
    var captionsMenuTitle: String { !selection.isEmpty && hasCaptions(selection) ? "Remove Captions" : "Add Captions" }

    func captionsFromMenu() {
        if !selection.isEmpty, hasCaptions(selection) { return removeCaptions() }
        guard addCaptions() == 0 else { return }
        let alert = EditroomAlert()
        alert.messageText = "Nothing to caption"
        alert.informativeText = selection.isEmpty
            ? "Captions come from what's said in clips of people talking. Add some to the timeline, or pick a clip with sound."
            : "The picked clips have no sound to caption."
        alert.runModal()
    }

    /// Takes captions off the picked clips (and what's linked to them).
    func removeCaptions(from ids: Set<UUID>? = nil) {
        let targets = project.captionTargets(ids ?? selection)
        guard !targets.isEmpty else { return }
        mutate { $0.removeCaptions(targets) }
    }

    func removeCaptionTrack() {
        captionSelection = []
        mutate { $0.removeCaptionTrack() }
    }

    /// Whether any of these clips (or what's linked to them) have captions.
    func hasCaptions(_ ids: Set<UUID>) -> Bool {
        let targets = project.captionTargets(ids)
        return project.clips.contains { targets.contains($0.id) && $0.captioned == true }
    }

    /// Picks captions on the caption track (clips are let go).
    func selectCaptions(_ ids: Set<String>) {
        if !selection.isEmpty { selection = [] }
        captionSelection = ids
        captionsFocused = false
    }

    /// Clicking elsewhere on the timeline lets go of captions.
    func releaseCaptions() {
        if !captionSelection.isEmpty { captionSelection = [] }
        if captionsFocused { captionsFocused = false }
    }

    /// The caption track's header: shows the caption style in the inspector.
    func focusCaptions() {
        if !selection.isEmpty { selection = [] }
        captionSelection = []
        captionsFocused = true
    }

    /// Leaves the picked captions' words out (the speech isn't touched).
    func deleteSelectedCaptions() {
        let picked = captionBlocks.filter { captionSelection.contains($0.id) }
        guard !picked.isEmpty else { return }
        captionSelection = []
        mutate { p in for b in picked { p.setCaptionText(b, to: "") } }
    }

    func setCaptionText(_ block: CaptionBlock, to text: String) {
        mutate { $0.setCaptionText(block, to: text) }
    }

    /// A caption's words as they're typed, shown at once; one undo step when typing ends (commitLive),
    /// or put back with discardLive. Empty text waits for more typing rather than removing the caption.
    func typeCaptionText(_ block: CaptionBlock, _ text: String) {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        live(autoCommit: false) { $0.setCaptionText(block, to: text) }
    }

    func setCaptionsHidden(_ hidden: Bool) {
        mutate { $0.captions?.hidden = hidden }
    }

    /// Style changes; `live` for a slider being dragged.
    /// `settles`: a live change that becomes an undo step by itself once it stops (colour wells).
    func setCaptionStyle(live: Bool = false, settles: Bool = false, _ change: (inout CaptionStyle) -> Void) {
        guard project.captions != nil else { return }
        if live {
            self.live(autoCommit: settles) { p in if p.captions != nil { change(&p.captions!.style) } }
        } else {
            mutate { p in if p.captions != nil { change(&p.captions!.style) } }
        }
    }

    // MARK: Freeze frame

    /// Holds the frame under the playhead for two seconds: the clip splits there, a freeze frame goes
    /// in, and everything after it on the clip's tracks moves along to make room.
    /// The picked video clip under the playhead, which Freeze Frame holds.
    private var freezeTarget: Clip? {
        let t = project.snapFrame(playhead)
        return project.clips.first { selection.contains($0.id) && $0.kind == .video && !$0.isFreeze && !project.isLocked($0.trackID) && t >= $0.start && t < $0.end }
    }

    func freezeFrame(seconds hold: Double = 2) {
        let t = project.snapFrame(playhead)
        guard let c = freezeTarget else { return }
        var source = c.sourceTime(at: t)
        if c.playsBackwards, let length = project.asset(c.assetID)?.duration { source = max(0, length - source - 0.001) }
        var made: UUID?
        mutate { p in
            let group = p.linked([c.id])
            _ = p.split(ids: group, at: t)
            let tracks = Set(p.clips.filter { group.contains($0.id) }.map(\.trackID))
            var shifting = Set(p.clips.filter { tracks.contains($0.trackID) && $0.start >= t - 1e-6 }.map(\.id))
            shifting = p.unlocked(p.linked(shifting))
            for i in p.clips.indices where shifting.contains(p.clips[i].id) { p.clips[i].start += hold }
            var f = Clip(trackID: c.trackID, kind: .video, assetID: c.assetID, start: t, duration: hold, sourceStart: source)
            f.freeze = true
            f.grade = c.grade
            f.transform = c.transform
            p.clips.append(f)
            p.resolveOverlaps(keeping: shifting.union([f.id]))
            made = f.id
        }
        if let made { selection = [made] }
    }

    // MARK: Reverse

    /// Plays the selected clip (and its linked audio) backwards, straight away and at any length:
    /// the picture is read backwards from the original file as it plays, and the sound is reversed
    /// once per file in the background (a fraction of a second for most). Reversing again plays
    /// it forwards.
    func reverseSelection() {
        guard let c = project.clips.first(where: { selection.contains($0.id) && $0.playsSource && !project.isLocked($0.trackID) }) else { return }
        let group = project.unlocked(project.linked([c.id]))

        // Older projects reversed into a copy of the file: point back at the original footage.
        if c.reversedFrom != nil {
            mutate { p in
                for i in p.clips.indices where group.contains(p.clips[i].id) {
                    guard let from = p.clips[i].reversedFrom else { continue }
                    p.clips[i].assetID = from.assetID
                    p.clips[i].sourceStart = from.sourceStart
                    p.clips[i].reversedFrom = nil
                }
            }
            return
        }

        let backwards = !c.playsBackwards
        for m in project.clips where group.contains(m.id) && m.kind == .audio && backwards {
            if let id = m.assetID { media.prepareReversedAudio(id) }
        }
        mutate { p in
            for i in p.clips.indices where group.contains(p.clips[i].id) && p.clips[i].playsSource && p.clips[i].reversedFrom == nil {
                guard let length = p.asset(p.clips[i].assetID)?.duration else { continue }
                let m = p.clips[i]
                // The same stretch of the file, measured from the other end.
                p.clips[i].sourceStart = max(0, length - (m.sourceStart + m.sourceLength))
                p.clips[i].ramp = m.ramp?.mirrored(length: length)
                p.clips[i].reversed = backwards ? true : nil
            }
        }
    }

    // MARK: Gaps

    func deleteGap(on track: UUID, at t: Double) {
        guard let g = project.gap(on: track, at: t) else { return }
        mutate { $0.pullLeft(on: track, from: g.end, by: g.end - g.start) }
    }

    /// Closes the gaps on the selected clips' tracks, or on every track with nothing selected.
    func closeAllGaps(on tracks: [UUID]? = nil) {
        let chosen = tracks ?? {
            let selected = Set(project.clips.filter { selection.contains($0.id) }.map(\.trackID))
            return selected.isEmpty ? (project.videoTracks + project.audioTracks).map(\.id) : Array(selected)
        }()
        mutate { p in for t in chosen { p.closeAllGaps(on: t) } }
    }

    // MARK: Copy, paste, duplicate

    /// Copied clips, with times measured from the earliest of them.
    private(set) var clipboard: [Clip] = []

    // MARK: Copy and paste grade

    /// A grade copied from a clip, to paste onto others. Nil inside means the clip had no grade, so
    /// pasting clears grades.
    @Published private(set) var copiedGrade: ColorGrade??

    /// Selected clips that take a colour grade (everything but sound), on unlocked tracks.
    private var gradableSelection: [Clip] {
        let ids = project.unlocked(selection)
        return project.clips.filter { ids.contains($0.id) && $0.kind != .audio }
    }

    var canCopyGrade: Bool { gradableSelection.count == 1 }
    var canPasteGrade: Bool { copiedGrade != nil && !gradableSelection.isEmpty }

    /// Copies the selected clip's whole grade: look and its strength, adjustments and wheels.
    func copyGrade() {
        guard let clip = gradableSelection.first else { return }
        copiedGrade = .some(clip.grade)
    }

    /// Gives every selected clip the copied grade, replacing theirs, as one undoable edit.
    func pasteGrade() {
        guard let copied = copiedGrade else { return }
        let ids = Set(gradableSelection.map(\.id))
        guard !ids.isEmpty else { return }
        mutate { p in
            for i in p.clips.indices where ids.contains(p.clips[i].id) { p.clips[i].grade = copied }
        }
    }

    private var selectedForCopy: [Clip] {
        let ids = project.unlocked(project.linked(selection))
        return project.clips.filter { ids.contains($0.id) }
    }

    func copySelection() {
        let clips = selectedForCopy
        guard let t0 = clips.map(\.start).min() else { return }
        clipboard = clips.map { c in var c = c; c.start -= t0; return c }
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    /// Pastes at the playhead, on the same tracks, over whatever is there (like Premiere), and moves
    /// the playhead to the end of what was pasted.
    func paste() {
        let copies = placed(clipboard, at: playhead)
        guard !copies.isEmpty else { return }
        insert(copies)
        if let end = copies.map(\.end).max() { seek(to: end) }
    }

    /// Puts a copy of the selection straight after it, on the same tracks.
    func duplicateSelection() {
        let clips = selectedForCopy
        guard let t0 = clips.map(\.start).min(), let t1 = clips.map(\.end).max() else { return }
        insert(placed(clips.map { c in var c = c; c.start -= t0; return c }, at: t1))
    }

    /// Fresh copies of clips (times relative to 0) placed at a time, with new ids and links kept
    /// between the copies. Copies whose track has gone or is locked land on an open track of their kind.
    func placed(_ clips: [Clip], at t: Double) -> [Clip] {
        var links: [UUID: UUID] = [:]
        return clips.map { original in
            var c = original
            c.id = UUID()
            if let l = c.linkID {
                if links[l] == nil { links[l] = UUID() }
                c.linkID = links[l]
            }
            c.start += t
            if project.track(c.trackID) == nil || project.isLocked(c.trackID) {
                let kind = c.kind.trackKind
                c.trackID = project.tracks(kind).first { !$0.locked }?.id ?? (kind == .video ? TrackToken.newVideo : TrackToken.newAudio)
            }
            return c
        }
    }

    /// Sets every selected audio clip (or every audio clip, with none selected) to the same typical
    /// level, so quiet and loud recordings sit together. Clips without a waveform yet are left alone.
    func evenOutLevels() {
        let chosen = project.clips.filter { selection.contains($0.id) && $0.kind == .audio }
        let clips = (chosen.isEmpty ? project.clips.filter { $0.kind == .audio } : chosen).filter { !project.isLocked($0.trackID) }
        let gains = levelGains(of: clips)
        guard !gains.isEmpty else { return }
        mutate { p in
            for i in p.clips.indices {
                if let g = gains[p.clips[i].id] { p.clips[i].gainDB = g.clamped(to: -24...12) }
            }
        }
    }

    /// The clip gain that brings each audio clip to the same typical level, measured from its waveform
    /// (clips with no sound, or no waveform yet, are left out), clamped to the gain range.
    /// - Plain: every clip to -20 dB.
    /// - `matchOutput`: so they read the same on the output meters, each track's gain counted. The level
    ///   they meet at is the middle of where they play now, so the whole mix stays about as loud and each
    ///   clip moves as little as it can; none is turned up past 1 dB under full scale.
    func levelGains(of clips: [Clip], matchOutput: Bool = false) -> [UUID: Double] {
        var measured: [(clip: Clip, level: Double, peak: Double, track: Double)] = []
        for c in clips {
            guard let level = AudioLevels.envelopeDB(c, media: media) else { continue }
            let track = matchOutput ? project.track(c.trackID)?.gainDB ?? 0 : 0
            measured.append((c, level, AudioLevels.peakDB(c, media: media) ?? level, track))
        }
        guard !measured.isEmpty else { return [:] }
        let target: Double
        if matchOutput {
            let outputs = measured.map { $0.level + $0.clip.gainDB + $0.track }.sorted()
            let n = outputs.count
            target = n % 2 == 1 ? outputs[n / 2] : (outputs[n / 2 - 1] + outputs[n / 2]) / 2
        } else {
            target = -20
        }
        var gains: [UUID: Double] = [:]
        for m in measured {
            var g = target - m.level - m.track
            if matchOutput { g = min(g, -1 - m.peak - m.track) }
            gains[m.clip.id] = ((g * 10).rounded() / 10).clamped(to: -24...12)
        }
        return gains
    }

    /// Turns one audio track down while another has sound (music under a voice); nil stops it.
    func duck(_ track: UUID, under voice: UUID?, amount: Double? = nil) {
        mutate { p in
            p.updateTrack(track) { t in
                t.duckUnder = voice
                if let amount { t.duckDB = amount }
            }
        }
    }

    /// Sets (or with nil removes) the transition into a clip from the one before it.
    func setTransition(into id: UUID, _ transition: Transition?) {
        mutate { p in
            if let i = p.index(of: id) { p.clips[i].transitionIn = transition }
        }
    }

    /// Puts a dissolve on the cut nearest the playhead, looking at selected clips first.
    /// A dissolve on the picked clips' cut nearest the playhead (either end of a picked clip).
    func addTransitionAtPlayhead() {
        guard let best = dissolveTarget else { return }
        setTransition(into: best.id, best.transitionIn ?? Transition())
    }

    private var dissolveTarget: Clip? {
        let cuts = project.clips.filter { c in
            c.kind != .audio && !project.isLocked(c.trackID) && project.previous(touching: c) != nil
        }
        let selected = cuts.filter { c in
            selection.contains(c.id) || project.previous(touching: c).map { selection.contains($0.id) } ?? false
        }
        return selected.min(by: { abs($0.start - playhead) < abs($1.start - playhead) })
    }

    // MARK: What the Clip menu can do with what's picked

    var canAddDissolve: Bool { dissolveTarget != nil }
    var canDuplicate: Bool { !selectedForCopy.isEmpty }
    var canReverse: Bool { project.clips.contains { selection.contains($0.id) && $0.playsSource && !project.isLocked($0.trackID) } }
    var canFreezeFrame: Bool { freezeTarget != nil }
    var canDeleteSelected: Bool { !selection.isEmpty || !mediaSelection.isEmpty || !folderSelection.isEmpty || !incomingSelection.isEmpty || !captionSelection.isEmpty }
    /// Picked clips with sound to caption (or captions to remove).
    var canCaption: Bool { Transcripts.available && !project.captionTargets(selection).isEmpty }

    /// The Playback section back as it was: 100% with no ramp, and these clips' volume at 0 dB.
    func resetPlayback(volume: Set<UUID>) {
        let ids = project.linked(selection)
        let sticky = self.sticky
        mutate { p in
            p.retime(ids: ids, sticky: sticky) { c in
                c.speed = 1
                c.ramp = nil
            }
            for i in p.clips.indices where volume.contains(p.clips[i].id) { p.clips[i].gainDB = 0 }
        }
    }

    func setSpeed(_ speed: Double) {
        let ids = project.linked(selection)
        let sticky = self.sticky
        mutate { $0.setSpeed(ids: ids, speed: speed, sticky: sticky) }
    }

    func addTrack(_ kind: TrackKind) {
        mutate { p in _ = p.addTrack(kind) }
    }

    func removeTrack(_ id: UUID) {
        mutate { $0.removeTrack(id) }
    }

    func setSequence(width: Int, height: Int) {
        mutate { p in
            p.width = width
            p.height = height
            p.settingsLocked = true
        }
    }

    /// The video a "match sequence" command would use: the selected clip's, if it's a video clip.
    var matchableAsset: MediaAsset? {
        guard let clip = project.clips.first(where: { selection.contains($0.id) && $0.kind == .video }),
              let asset = project.asset(clip.assetID ?? UUID()), asset.width > 0 else { return nil }
        return asset
    }

    /// Whether the sequence already has a video's frame size and rate.
    func sequenceMatches(_ asset: MediaAsset) -> Bool {
        asset.width == project.width && asset.height == project.height && Self.standardFPS(asset.fps) == project.fps
    }

    /// Sets the sequence's frame size and rate to a video's (an undoable edit).
    func matchSequence(to asset: MediaAsset) {
        guard asset.kind == .video, asset.width > 0, asset.height > 0 else { return }
        mutate { p in
            p.width = asset.width
            p.height = asset.height
            p.fps = Self.standardFPS(asset.fps)
            p.settingsLocked = true
        }
    }

    func setFPS(_ fps: Double) {
        mutate { p in
            p.fps = fps
            p.settingsLocked = true
        }
    }

    // MARK: Files

    /// Before the project is closed (another opened, a new one, or quitting). With Auto-save on, a saved project
    /// is already on disk; untitled work asks before it's thrown away. With it off, any unsaved changes ask to be saved.
    func confirmDiscard(quitting: Bool = false) -> Bool {
        if Self.autosaves {
            // Quitting keeps untitled work in the recovery copy, which reopens next time.
            guard !quitting, isDirty, !project.clips.isEmpty else { return true }
            if fileURL != nil { autosaveNow(); return true }
            let alert = EditroomAlert()
            alert.messageText = "Discard unsaved changes?"
            alert.informativeText = "Your changes to “\(title)” will be lost."
            alert.addButton(withTitle: "Discard")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            dropUnsaved()
            return true
        }
        commitLive()
        guard isDirty, !(project.clips.isEmpty && project.assets.isEmpty) else { return true }
        let alert = EditroomAlert()
        alert.messageText = "Save changes to “\(title)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dont = alert.addButton(withTitle: "Don't Save")
        dont.keyEquivalent = "d"
        dont.keyEquivalentModifierMask = .command
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            save()
            return !isDirty
        case .alertThirdButtonReturn:
            dropUnsaved()
            return true
        default:
            return false
        }
    }

    /// Projects are saved as `.room`; `.cutplay` is the name from before the app was called Editroom.
    static let projectExtensions = ["room", "cutplay"]
    static func isProjectFile(_ url: URL) -> Bool { projectExtensions.contains(url.pathExtension.lowercased()) }

    /// Files handed to the app from outside: a project opens, anything else is imported.
    func handleOpen(_ urls: [URL]) {
        if let project = urls.first(where: { Self.isProjectFile($0) }) {
            guard confirmDiscard() else { return }
            open(url: project)
        }
        let media = urls.filter { !Self.isProjectFile($0) }
        if !media.isEmpty { importFiles(media) }
        NSApp.activate()
    }

    func newProject() {
        guard confirmDiscard() else { return }
        load(Project(), url: nil)
        try? FileManager.default.removeItem(at: Self.recoveryURL)
        lastSession = nil
    }

    // MARK: Recent projects

    /// Projects opened or saved recently, newest first, as macOS keeps them for this app.
    @Published private(set) var recentProjects: [URL] = NSDocumentController.shared.recentDocumentURLs

    /// Adds a project to Open Recent. Test launches leave the list alone.
    private func noteRecent(_ url: URL) {
        let args = CommandLine.arguments
        guard !args.contains("--selftest"), !args.contains("--open") else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentProjects = NSDocumentController.shared.recentDocumentURLs
    }

    func openRecent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            importError = "“\(url.lastPathComponent)” can't be found. It may have been moved or deleted."
            return
        }
        guard confirmDiscard() else { return }
        open(url: url)
    }

    func clearRecents() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentProjects = []
    }

    func openProject() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.projectExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func save() {
        guard let url = fileURL else { return saveAs() }
        write(to: url)
        noteRecent(url)
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "room") ?? .json]
        panel.nameFieldStringValue = title + ".room"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
        noteRecent(url)
    }

    /// Self-tests: saves as Save As would, without its panel.
    func saveForTest(to url: URL) { write(to: url) }

    private func write(to url: URL) {
        commitLive()
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Copies dropped from Photos while it was unsaved go beside the project now.
            adoptHeldMedia(projectDir: url.deletingLastPathComponent())
            var saved = project
            saved.stampRelativePaths(projectDir: url.deletingLastPathComponent())
            try encoder.encode(SavedDocument(project: saved)).write(to: url, options: .atomic)
            if fileURL == nil || recoveryFor != nil { try? FileManager.default.removeItem(at: Self.recoveryURL) }
            recoveryFor = nil
            lastRecovered = nil
            fileURL = url
            isDirty = false
            lastSession = url.path
        } catch {
            importError = "Couldn't save to \(url.lastPathComponent)."
        }
    }

    func load(_ p: Project, url: URL?, offerLocate: Bool = false) {
        if isPlaying { pause() }
        commitLive()
        undoStack.removeAll()
        redoStack.removeAll()
        redoKnown.removeAll()
        selection = []
        mediaSelection = []
        folderSelection = []
        mediaFolder = nil
        playhead = 0
        // Its files are loading from here: drawn as clips, not as missing, until they're found or aren't.
        media.expect(p.assets)
        // Older projects: bookmarks for files and folders that are where they were.
        var p = p
        for i in p.assets.indices where p.assets[i].bookmark == nil { p.assets[i].bookmark = Bookmark.make(p.assets[i].path) }
        for i in (p.folders ?? []).indices where p.folders![i].bookmark == nil { p.folders![i].bookmark = Bookmark.make(p.folders![i].path) }
        project = p
        fileURL = url
        isDirty = false
        setView(scrollX: 0)
        fitRows()
        setNeedsRebuild()
        Task {
            let reconverted = await media.restore(p.assets)
            for i in self.project.assets.indices {
                if let path = reconverted[self.project.assets[i].id] { self.project.assets[i].playablePath = path }
            }
            self.objectWillChange.send()
            self.setNeedsRebuild()
            await self.syncFolders()
            // Copies held for an unsaved project that's been left behind.
            if !CommandLine.arguments.contains("--selftest") { self.clearUnusedHeldMedia() }
            if offerLocate, !self.missingAssets.isEmpty { self.offerToLocateMissing() }
        }
    }

    // MARK: Missing media

    /// Library items whose file can't be found.
    var missingAssets: [MediaAsset] {
        project.assets.filter { !FileManager.default.fileExists(atPath: $0.url.path) }
    }

    /// Points a library item at a new file, then looks in that file's folder for any other missing
    /// items by file name. Returns false when the chosen file can't stand in for the item.
    @discardableResult
    func relink(_ id: UUID, to url: URL) async -> Bool {
        guard let old = project.assets.first(where: { $0.id == id }),
              let fresh = await media.importFile(url, replacing: old),
              let i = project.assets.firstIndex(where: { $0.id == id }) else { return false }
        commitLive()
        var found = fresh
        found.bookmark = Bookmark.make(fresh.path)
        project.assets[i] = found
        // In a linked folder that's gone: the folder is where this file is now, if it's the same place in it.
        if let root = project.linkedFolder(holding: old.path), !MediaFolder.isFolder(root.path) {
            let inside = String(old.path.dropFirst(root.path.count))
            let now = url.standardizedFileURL.path
            if now.hasSuffix(inside) {
                let moved = String(now.dropLast(inside.count))
                if MediaFolder.isFolder(moved) { await relinkFolder(root.path, to: moved) }
            }
        }
        let folder = url.deletingLastPathComponent()
        for other in missingAssets where other.id != id {
            let candidate = folder.appendingPathComponent(URL(fileURLWithPath: other.path).lastPathComponent)
            guard FileManager.default.fileExists(atPath: candidate.path),
                  var found = await media.importFile(candidate, replacing: other),
                  let j = project.assets.firstIndex(where: { $0.id == other.id }) else { continue }
            found.bookmark = Bookmark.make(found.path)
            project.assets[j] = found
        }
        // Undo snapshots still hold the old paths, so they can't be kept.
        undoStack.removeAll()
        redoStack.removeAll()
        redoKnown.removeAll()
        didChange()
        return true
    }

    // MARK: Files changed on disk

    private var checkingDisk = false

    /// Opens again any library files that changed on disk since they were opened (saved over,
    /// re-exported from another app). Run when Editroom comes back to the front. A file still being
    /// written (its size or date still moving) is waited on, and looked at again a little later.
    func reloadChangedMedia() {
        guard !checkingDisk, !media.changedOnDisk(project.assets).isEmpty else { return }
        checkingDisk = true
        Task {
            defer { checkingDisk = false }
            for _ in 0..<60 {
                let changed = media.changedOnDisk(project.assets)
                if changed.isEmpty { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let now = media.changedOnDisk(project.assets)
                let settled = Set(changed.filter { now[$0.key] == $0.value }.map(\.key))
                if !settled.isEmpty { await reloadMedia(settled) }
                if settled.count == changed.count { return }
            }
        }
    }

    /// Opens library items' files again as they are on disk now (Reload from Disk). Clips keep their
    /// places and trims; a clip past the end of a file that got shorter is cut to fit (one undo step).
    func reloadMedia(_ ids: Set<UUID>) async {
        let olds = project.assets.filter { ids.contains($0.id) && FileManager.default.fileExists(atPath: $0.path) }
        guard !olds.isEmpty else { return }
        var reloaded = Set<UUID>()
        var described = false
        for old in olds {
            guard let fresh = await media.reload(old),
                  let i = project.assets.firstIndex(where: { $0.id == old.id }) else { continue }
            reloaded.insert(old.id)
            var a = project.assets[i]
            a.playablePath = fresh.playablePath
            a.duration = fresh.duration
            a.width = fresh.width
            a.height = fresh.height
            a.fps = fresh.fps
            a.hasAudio = fresh.hasAudio
            if a != project.assets[i] {
                commitLive()
                project.assets[i] = a
                described = true
            }
        }
        guard !reloaded.isEmpty else { return }
        sourcePreview.clear()
        if described {
            isDirty = true
            mutate { $0.fitClips(toMedia: reloaded) }
        }
        objectWillChange.send()
        setNeedsRebuild()
    }

    /// Asks where a missing item's file is. With `thenOthers`, keeps asking for whatever is still
    /// missing afterwards until everything is found or the panel is cancelled.
    func locate(_ id: UUID, thenOthers: Bool = false) {
        guard let asset = project.assets.first(where: { $0.id == id }) else { return }
        let original = URL(fileURLWithPath: asset.path)
        let panel = NSOpenPanel()
        panel.message = "Locate “\(original.lastPathComponent)”"
        panel.prompt = "Locate"
        panel.allowedContentTypes = Self.importTypes
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = original.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if await relink(id, to: url) {
                if thenOthers, let next = missingAssets.first { locate(next.id, thenOthers: true) }
            } else {
                importError = "“\(url.lastPathComponent)” can't be used in place of “\(original.lastPathComponent)”."
            }
        }
    }

    private func offerToLocateMissing() {
        let missing = missingAssets
        guard let first = missing.first else { return }
        // A linked folder that's gone: located once, for everything in it.
        if let f = project.folders?.first(where: { f in !MediaFolder.isFolder(f.path) && missing.contains { MediaFolder.contains(f.path, $0.path) } }) {
            let n = missing.filter { MediaFolder.contains(f.path, $0.path) }.count
            let alert = EditroomAlert()
            alert.messageText = "The folder “\(f.name)” is missing"
            alert.informativeText = "\(n) item\(n == 1 ? " in it can't" : "s in it can't") be found. Locate the folder and everything in it is found again."
            alert.addButton(withTitle: "Locate…")
            alert.addButton(withTitle: "Not Now")
            if alert.runModal() == .alertFirstButtonReturn { locateFolder(f.id) }
            return
        }
        let names = missing.prefix(6).map { URL(fileURLWithPath: $0.path).lastPathComponent }
        let alert = EditroomAlert()
        alert.messageText = missing.count == 1 ? "1 media file is missing" : "\(missing.count) media files are missing"
        alert.informativeText = names.joined(separator: "\n") + (missing.count > names.count ? "\n…" : "")
            + "\n\nLocate one and any others in the same folder are found too."
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { locate(first.id, thenOthers: true) }
    }
}
