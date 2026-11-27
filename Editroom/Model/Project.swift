import Foundation
import CoreGraphics

// MARK: - Value types

struct RGBA: Codable, Hashable {
    var r: Double, g: Double, b: Double, a: Double
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)
}

enum TrackKind: String, Codable { case video, audio }

struct Track: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: TrackKind
    var hidden = false
    var muted = false
    var gainDB: Double = 0
    /// Audio only: while any track is soloed, only soloed tracks are heard.
    var solo = false
    /// A locked track's clips can't be selected, moved, trimmed or cut.
    var locked = false
    /// Audio only: this track is turned down while the named track has sound, such as music under a voice.
    var duckUnder: UUID?
    var duckDB: Double = -12

    init(kind: TrackKind) { self.kind = kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(TrackKind.self, forKey: .kind)
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        solo = try c.decodeIfPresent(Bool.self, forKey: .solo) ?? false
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        duckUnder = try c.decodeIfPresent(UUID.self, forKey: .duckUnder)
        duckDB = try c.decodeIfPresent(Double.self, forKey: .duckDB) ?? -12
    }
}

enum ClipKind: String, Codable {
    case video, audio, image, solid, text
    var trackKind: TrackKind { self == .audio ? .audio : .video }
    var usesSource: Bool { self == .video || self == .audio }
}

struct TextStyle: Codable, Hashable {
    var string = "Text"
    /// Font family; empty means the system font.
    var fontName = ""
    var bold = true
    /// Point size relative to a 1080px tall frame.
    var size: Double = 110
    var color = RGBA.white
    var x = 0.5
    var y = 0.5
}

enum FadeCurve: String, Codable, CaseIterable {
    case linear, easeIn, easeOut, smooth

    var label: String {
        switch self {
        case .linear: return "Linear"
        case .easeIn: return "Exponential"
        case .easeOut: return "Logarithmic"
        case .smooth: return "S-Curve"
        }
    }

    /// Maps fade progress (0 = silent/transparent, 1 = full) through the curve.
    func apply(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        switch self {
        case .linear: return x
        case .easeIn: return x * x * x
        case .easeOut: return 1 - pow(1 - x, 3)
        case .smooth: return x * x * (3 - 2 * x)
        }
    }
}

struct Clip: Identifiable, Codable, Hashable {
    var id = UUID()
    var trackID: UUID
    var kind: ClipKind
    var assetID: UUID?
    var start: Double
    var duration: Double
    var sourceStart: Double = 0
    var speed: Double = 1
    var fadeIn: Double = 0
    var fadeOut: Double = 0
    var fadeInCurve: FadeCurve?
    var fadeOutCurve: FadeCurve?
    var gainDB: Double = 0
    var linkID: UUID?
    var color = RGBA(r: 0.16, g: 0.16, b: 0.2, a: 1)
    var text = TextStyle()
    /// Colour correction for visual clips; nil means untouched.
    var grade: ColorGrade?
    /// Size and placement for video, image and solid clips; nil means fitted to the frame.
    var transform: ClipTransform?
    /// A transition into this clip from the clip that ends where it starts, on the same track.
    var transitionIn: Transition?
    /// A freeze frame: shows the single frame at `sourceStart` for its whole length.
    var freeze: Bool?
    /// Set on a reversed clip: where its footage came from, so reversing again restores it.
    var reversedFrom: ReverseSource?
    /// Plays its source backwards. Source time `s` is time `length - s` in the file, so trims and
    /// splits work as on any clip.
    var reversed: Bool?
    /// The speed changing across the clip; nil plays at `speed` throughout.
    var ramp: SpeedRamp?
    /// A sound clip whose speech shows on the caption track.
    var captioned: Bool?
    /// One camera of a multi-angle group (see Angles.swift): it can switch to another camera of the same moment.
    var angleGroup: UUID?

    var isFreeze: Bool { freeze == true }
    var playsBackwards: Bool { reversed == true }
    /// Reversed either way: playing backwards, or (in older projects) using a reversed copy of a file.
    var isReversed: Bool { playsBackwards || reversedFrom != nil }
    /// Plays through its source over time (so speed and source limits apply); a freeze frame doesn't.
    var playsSource: Bool { kind.usesSource && !isFreeze }

    /// Clips that can be scaled and moved in the frame (text has its own placement).
    var isTransformable: Bool { kind == .video || kind == .image || kind == .solid }

    var end: Double { start + duration }

    /// Level from the fades at a time on the timeline, 0...1.
    func fadeGain(at t: Double) -> Double {
        var g = 1.0
        if fadeIn > 0 { g = min(g, inCurve.apply((t - start) / fadeIn)) }
        if fadeOut > 0 { g = min(g, outCurve.apply((end - t) / fadeOut)) }
        return max(0, min(1, g))
    }
    var inCurve: FadeCurve { fadeInCurve ?? .linear }
    var outCurve: FadeCurve { fadeOutCurve ?? .linear }

    mutating func clampFades() {
        fadeIn = min(max(0, fadeIn), duration)
        fadeOut = min(max(0, fadeOut), duration - fadeIn)
    }

    mutating func trimHead(to t: Double) {
        let d = t - start
        let newSource = sourceTime(at: t)
        start = t
        duration -= d
        if playsSource { sourceStart = max(0, newSource) }
        clampFades()
        // A zoom stays on the picture it was on.
        transform?.zoom?.shift(by: d, length: duration)
    }

    mutating func trimTail(to t: Double) {
        duration = t - start
        clampFades()
        transform?.zoom?.fit(length: duration)
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

enum TransitionKind: String, Codable, CaseIterable {
    case dissolve, dipToBlack, wipe

    var label: String {
        switch self {
        case .dissolve: return "Dissolve"
        case .dipToBlack: return "Dip to Black"
        case .wipe: return "Wipe"
        }
    }
}

struct Transition: Codable, Hashable {
    var kind = TransitionKind.dissolve
    /// Seconds; may be shortened to what the clips allow.
    var duration = 0.5
}

/// A stretch of time over which a clip is brought in or taken out by a transition.
struct TransitionEdge: Hashable {
    var start: Double
    var end: Double
    var kind: TransitionKind

    func progress(_ t: Double) -> Double { ((t - start) / max(1e-6, end - start)).clamped(to: 0...1) }
}

/// How transitions change the way one clip is drawn: shown for longer, brought in, or taken out.
struct TransitionPlan: Hashable {
    /// Seconds shown before the clip's start, from media before its in point.
    var leadIn = 0.0
    /// Seconds shown after its end, from media after its out point.
    var tailOut = 0.0
    var reveal: TransitionEdge?
    var conceal: TransitionEdge?
}

/// The footage a reversed clip was made from.
struct ReverseSource: Codable, Hashable {
    var assetID: UUID
    var sourceStart: Double
}

/// Scale and position of a clip within the frame.
struct ClipTransform: Codable, Hashable {
    /// 1 is fitted to the frame.
    var scale = 1.0
    /// Offset of the clip's centre from the frame's centre, as a fraction of the frame's width and
    /// height. Positive y is down.
    var x = 0.0
    var y = 0.0
    /// Moving between the full frame and this framing over the clip (the zoom button on Scale).
    var zoom: ZoomMove?

    var isIdentity: Bool { self == ClipTransform() }
    static let scaleRange = 0.05...10.0
}

enum MediaKind: String, Codable { case video, audio, image }

struct MediaAsset: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String
    /// `path` as seen from the project file's folder, written on save. It lets a project folder that
    /// is moved or copied as a whole find its media again.
    var relativePath: String?
    /// Set when the original had to be converted to something AVFoundation can decode.
    var playablePath: String?
    var name: String
    var kind: MediaKind
    var duration: Double
    var width: Int
    var height: Int
    var fps: Double
    var hasAudio: Bool
    /// Finds the file again after it's renamed or moved on its drive.
    var bookmark: Data?

    var url: URL { URL(fileURLWithPath: playablePath ?? path) }
}

extension Project {
    /// Records where each file sits relative to the project's folder.
    mutating func stampRelativePaths(projectDir: URL) {
        let base = projectDir.standardizedFileURL.pathComponents
        for i in assets.indices {
            let file = URL(fileURLWithPath: assets[i].path).standardizedFileURL.pathComponents
            var shared = 0
            while shared < base.count, shared < file.count, base[shared] == file[shared] { shared += 1 }
            let parts = Array(repeating: "..", count: base.count - shared) + file[shared...]
            assets[i].relativePath = parts.joined(separator: "/")
        }
        for i in (folders ?? []).indices {
            let dir = URL(fileURLWithPath: folders![i].path).standardizedFileURL.pathComponents
            var shared = 0
            while shared < base.count, shared < dir.count, base[shared] == dir[shared] { shared += 1 }
            folders![i].relativePath = (Array(repeating: "..", count: base.count - shared) + dir[shared...]).joined(separator: "/")
        }
    }

    /// Points assets whose file has gone from its saved place at the same file relative to the
    /// project's folder, when it's there. Returns how many were found that way.
    @discardableResult
    mutating func resolveMovedMedia(projectDir: URL) -> Int {
        var found = 0
        // A folder brought in whole, moved along with the project: everything in it moves with it.
        for f in folders ?? [] where !FileManager.default.fileExists(atPath: f.path) {
            guard let rel = f.relativePath else { continue }
            let candidate = projectDir.appendingPathComponent(rel).standardizedFileURL.path
            if MediaFolder.isFolder(candidate) { movePaths(from: f.path, to: candidate) }
        }
        for i in assets.indices where !FileManager.default.fileExists(atPath: assets[i].path) {
            guard let rel = assets[i].relativePath else { continue }
            let candidate = projectDir.appendingPathComponent(rel).standardizedFileURL.path
            if FileManager.default.fileExists(atPath: candidate) {
                assets[i].path = candidate
                found += 1
            }
        }
        return found
    }
}

enum TrackToken {
    /// Placeholder track ids used while a drag targets a track that doesn't exist yet.
    static let newVideo = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let newAudio = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
}

// MARK: - Project

struct Project: Codable, Equatable {
    var width = 1920
    var height = 1080
    var fps: Double = 30
    var settingsLocked = false
    /// Index 0 is the bottom-most video track (V1).
    var videoTracks: [Track] = [Track(kind: .video), Track(kind: .video)]
    /// Index 0 is the top-most audio track (A1).
    var audioTracks: [Track] = [Track(kind: .audio), Track(kind: .audio)]
    var clips: [Clip] = []
    var assets: [MediaAsset] = []
    /// Remembered so repeat exports don't ask again.
    var exportName: String?
    var exportDir: String?
    /// Named points on the timeline (optional so older projects open).
    var markers: [Marker]?
    /// The in/out range, set with I and O. Either can be set alone.
    var inPoint: Double?
    var outPoint: Double?
    /// Prompts sent with Magic in this project, newest first (optional so older projects open).
    var magicHistory: [MagicHistory.Entry]?
    /// The caption track, when there is one (see Captions.swift).
    var captions: CaptionTrack?
    /// Words fixed or left out on captions, by file.
    var captionFixes: [UUID: [CaptionFix]]?
    /// Folders on disk brought in whole, which the Media panel mirrors (see MediaFolders.swift).
    var folders: [MediaFolder]?
    /// Files (or whole folders) in those folders taken out of the project, so they don't come back when
    /// the folder is next looked at.
    var hiddenMedia: [String]?
    /// Subtitles brought in from files (a translation, say), which the caption track can show instead of
    /// what's heard (see Subtitles.swift).
    var subtitleLayers: [SubtitleLayer]?
    /// Changes whenever a subtitle layer does, so the captions are laid out again.
    var subtitleRevision: UUID?
    /// Cameras of the same session, synced by their sound (see Angles.swift).
    var angleGroups: [AngleGroup]?
    /// This lesson's trip through the translation and dubbing pipeline (see DubJob.swift).
    var dubJob: DubJob?
}

struct Marker: Codable, Hashable, Identifiable {
    enum Tint: String, Codable, CaseIterable {
        case white, yellow, green, blue, purple, red
        var hex: UInt32 {
            switch self {
            case .white: 0xEDEDEA
            case .yellow: 0xF2B33D
            case .green: 0x6CC08B
            case .blue: 0x5B9BF0
            case .purple: 0xB07CF0
            case .red: 0xF0503C
            }
        }
    }

    var id = UUID()
    var time: Double
    var name: String
    var tint: Tint = .yellow
}

extension Project {
    static let minClip = 1.0 / 60.0

    var duration: Double { clips.map(\.end).max() ?? 0 }
    var size: CGSize { CGSize(width: width, height: height) }
    var aspect: CGFloat { CGFloat(width) / CGFloat(max(1, height)) }

    func snapFrame(_ t: Double) -> Double { (t * fps).rounded() / fps }

    func asset(_ id: UUID?) -> MediaAsset? {
        guard let id else { return nil }
        return assets.first { $0.id == id }
    }

    func clip(_ id: UUID) -> Clip? { clips.first { $0.id == id } }

    func track(_ id: UUID) -> Track? { (videoTracks + audioTracks).first { $0.id == id } }
    func isLocked(_ trackID: UUID) -> Bool { track(trackID)?.locked ?? false }

    /// Drops clips on locked tracks.
    func unlocked(_ ids: Set<UUID>) -> Set<UUID> {
        let locked = Set((videoTracks + audioTracks).filter(\.locked).map(\.id))
        guard !locked.isEmpty else { return ids }
        return Set(clips.filter { ids.contains($0.id) && !locked.contains($0.trackID) }.map(\.id))
    }

    /// Whether an audio track is heard, taking mute and solo into account.
    func isAudible(_ track: Track) -> Bool {
        if track.muted { return false }
        return !audioTracks.contains(where: \.solo) || track.solo
    }
    func index(of id: UUID) -> Int? { clips.firstIndex { $0.id == id } }

    func tracks(_ kind: TrackKind) -> [Track] { kind == .video ? videoTracks : audioTracks }

    func trackIndex(_ id: UUID, kind: TrackKind) -> Int? {
        tracks(kind).firstIndex { $0.id == id }
    }

    func name(of clip: Clip) -> String {
        switch clip.kind {
        case .text:
            let s = clip.text.string.replacingOccurrences(of: "\n", with: " ")
            return s.isEmpty ? "Text" : s
        case .solid: return "Solid"
        default: return asset(clip.assetID)?.name ?? "Missing"
        }
    }

    /// Expands a set of clip ids to include everything linked to them.
    func linked(_ ids: Set<UUID>) -> Set<UUID> {
        let links = Set(clips.filter { ids.contains($0.id) }.compactMap(\.linkID))
        guard !links.isEmpty else { return ids }
        return ids.union(clips.filter { $0.linkID.map(links.contains) ?? false }.map(\.id))
    }

    func sourceLimit(_ clip: Clip) -> Double? {
        guard clip.playsSource else { return nil }
        return asset(clip.assetID)?.duration
    }

    /// Every clip edge (plus zero) that things can snap to.
    var markerList: [Marker] { (markers ?? []).sorted { $0.time < $1.time } }

    /// The in/out range, if one is set and longer than a frame. With only an in point it runs to
    /// the end; with only an out point it starts at zero.
    var playRange: (start: Double, end: Double)? {
        guard inPoint != nil || outPoint != nil else { return nil }
        let a = inPoint ?? 0, b = outPoint ?? duration
        let lo = min(a, b), hi = max(a, b)
        return hi - lo >= 1 / fps ? (lo, hi) : nil
    }

    /// Just the in/out range, moved to start at zero: clips are cut at its edges and anything
    /// outside goes.
    func cropped(to range: (start: Double, end: Double)) -> Project {
        var p = self
        let all = Set(p.clips.map(\.id))
        _ = p.split(ids: all, at: range.start)
        _ = p.split(ids: Set(p.clips.map(\.id)), at: range.end)
        p.clips.removeAll { $0.end <= range.start + 1e-6 || $0.start >= range.end - 1e-6 }
        for i in p.clips.indices { p.clips[i].start -= range.start }
        p.markers = p.markers?.filter { $0.time >= range.start && $0.time <= range.end }
            .map { var m = $0; m.time -= range.start; return m }
        p.inPoint = nil
        p.outPoint = nil
        return p
    }

    func snapTargets(excluding ids: Set<UUID>) -> [Double] {
        var out: [Double] = [0]
        out += (markers ?? []).map(\.time)
        if let i = inPoint { out.append(i) }
        if let o = outPoint { out.append(o) }
        for c in clips where !ids.contains(c.id) {
            out.append(c.start)
            out.append(c.end)
        }
        return out
    }

    /// Sorted, de-duplicated edit points for playhead jumping.
    var editPoints: [Double] {
        var set = Set<Double>([0])
        for c in clips { set.insert(c.start); set.insert(c.end) }
        for m in markers ?? [] { set.insert(m.time) }
        return set.sorted()
    }

    /// Allowed delta range for dragging a clip edge.
    func trimLimits(_ c: Clip, left: Bool, excluding ids: Set<UUID>) -> ClosedRange<Double> {
        let others = clips.filter { $0.trackID == c.trackID && !ids.contains($0.id) && $0.id != c.id }
        let minDur = max(Project.minClip, 1 / fps)
        if left {
            let prevEnd = others.filter { $0.end <= c.start + 1e-6 }.map(\.end).max() ?? 0
            var lo = prevEnd - c.start
            if c.playsSource { lo = max(lo, -c.timelineSpan(from: 0, to: c.sourceStart)) }
            let hi = c.duration - minDur
            return min(lo, hi)...hi
        } else {
            let nextStart = others.filter { $0.start >= c.end - 1e-6 }.map(\.start).min() ?? .infinity
            var hi = nextStart - c.end
            if let limit = sourceLimit(c) {
                hi = min(hi, c.timelineSpan(from: c.sourceStart, to: limit) - c.duration)
            }
            let lo = minDur - c.duration
            return lo...max(lo, hi)
        }
    }

    /// First track of a kind (bottom-up for video, top-down for audio) that is empty across a range.
    func freeTrack(_ kind: TrackKind, start: Double, duration: Double) -> UUID? {
        for t in tracks(kind) where !t.locked {
            let busy = clips.contains { $0.trackID == t.id && $0.start < start + duration - 1e-6 && $0.end > start + 1e-6 }
            if !busy { return t.id }
        }
        return nil
    }

    /// The earliest place at or after `time` where a clip of this length fits on an open video track
    /// without covering anything, preferring lower tracks when two are equally early.
    func firstFreeVideoSpot(from time: Double, duration: Double) -> (track: UUID, start: Double)? {
        var best: (track: UUID, start: Double)?
        for t in videoTracks where !t.locked {
            let here = clips.filter { $0.trackID == t.id }.sorted { $0.start < $1.start }
            var candidates = [time] + here.map(\.end).filter { $0 > time }
            candidates.sort()
            for start in candidates {
                let busy = here.contains { $0.start < start + duration - 1e-6 && $0.end > start + 1e-6 }
                if !busy {
                    if best == nil || start < best!.start - 1e-9 { best = (t.id, start) }
                    break
                }
            }
        }
        return best
    }

    // MARK: Mutations

    @discardableResult
    mutating func addTrack(_ kind: TrackKind) -> UUID {
        let t = Track(kind: kind)
        if kind == .video { videoTracks.append(t) } else { audioTracks.append(t) }
        return t.id
    }

    mutating func removeTrack(_ id: UUID) {
        if let i = videoTracks.firstIndex(where: { $0.id == id }), videoTracks.count > 1 {
            videoTracks.remove(at: i)
            clips.removeAll { $0.trackID == id }
        } else if let i = audioTracks.firstIndex(where: { $0.id == id }), audioTracks.count > 1 {
            audioTracks.remove(at: i)
            clips.removeAll { $0.trackID == id }
        }
    }

    mutating func updateTrack(_ id: UUID, _ body: (inout Track) -> Void) {
        if let i = videoTracks.firstIndex(where: { $0.id == id }) { body(&videoTracks[i]) }
        if let i = audioTracks.firstIndex(where: { $0.id == id }) { body(&audioTracks[i]) }
    }

    /// Replaces placeholder track tokens with freshly created tracks.
    mutating func materializeTokens() {
        var newV: UUID?, newA: UUID?
        for i in clips.indices {
            if clips[i].trackID == TrackToken.newVideo {
                if newV == nil { newV = addTrack(.video) }
                clips[i].trackID = newV!
            } else if clips[i].trackID == TrackToken.newAudio {
                if newA == nil { newA = addTrack(.audio) }
                clips[i].trackID = newA!
            }
        }
    }

    /// Overwrite edit: the given clips win, anything underneath is trimmed, split or removed.
    mutating func resolveOverlaps(keeping ids: Set<UUID>) {
        let eps = 1e-6
        for m in clips.filter({ ids.contains($0.id) }) {
            var result: [Clip] = []
            result.reserveCapacity(clips.count + 1)
            for var c in clips {
                if ids.contains(c.id) || c.trackID != m.trackID || c.end <= m.start + eps || c.start >= m.end - eps {
                    result.append(c)
                    continue
                }
                let head = c.start < m.start - eps
                let tail = c.end > m.end + eps
                if head && tail {
                    var right = c
                    right.id = UUID()
                    right.linkID = nil
                    right.fadeIn = 0
                    right.trimHead(to: m.end)
                    c.fadeOut = 0
                    c.trimTail(to: m.start)
                    result.append(c)
                    result.append(right)
                } else if head {
                    c.trimTail(to: m.start)
                    result.append(c)
                } else if tail {
                    c.trimHead(to: m.end)
                    result.append(c)
                }
            }
            clips = result
        }
    }

    /// Splits clips at a time. Returns ids of the new right-hand pieces.
    @discardableResult
    mutating func split(ids: Set<UUID>, at t: Double) -> Set<UUID> {
        let minDur = 0.5 / fps
        var created = Set<UUID>()
        var linkMap: [UUID: UUID] = [:]
        for id in ids {
            guard let i = index(of: id) else { continue }
            let c = clips[i]
            guard t > c.start + minDur, t < c.end - minDur else { continue }
            var right = c
            right.id = UUID()
            right.fadeIn = 0
            right.trimHead(to: t)
            if let l = c.linkID {
                let mapped = linkMap[l] ?? UUID()
                linkMap[l] = mapped
                right.linkID = mapped
            }
            clips[i].fadeOut = 0
            clips[i].trimTail(to: t)
            clips.append(right)
            created.insert(right.id)
        }
        return created
    }

    mutating func remove(ids: Set<UUID>, ripple: Bool) {
        let removed = clips.filter { ids.contains($0.id) }.sorted { $0.start > $1.start }
        clips.removeAll { ids.contains($0.id) }
        guard ripple else { return }
        for r in removed {
            for i in clips.indices where clips[i].trackID == r.trackID && clips[i].start >= r.end - 1e-6 {
                clips[i].start = max(0, clips[i].start - r.duration)
            }
        }
    }

    /// Takes the time from `a` to `b` out of these tracks and closes it up: clips crossing either end are cut
    /// there, what's between goes, and everything after slides left by the same amount, so the tracks stay in
    /// sync with each other. Locked tracks are left alone.
    mutating func rippleRemove(from a: Double, to b: Double, tracks: Set<UUID>) {
        let tracks = tracks.filter { !isLocked($0) }
        let gap = b - a
        guard gap > 1e-9, !tracks.isEmpty else { return }
        let on = { (c: Clip) in tracks.contains(c.trackID) }
        split(ids: Set(clips.filter { on($0) && $0.start < a && $0.end > a }.map(\.id)), at: a)
        split(ids: Set(clips.filter { on($0) && $0.start < b && $0.end > b }.map(\.id)), at: b)
        let eps = 0.5 / fps
        clips.removeAll { on($0) && $0.start >= a - eps && $0.end <= b + eps }
        for i in clips.indices where on(clips[i]) && clips[i].start >= b - eps {
            clips[i].start = max(0, clips[i].start - gap)
        }
    }

    /// Changes playback speed of the given clips, keeping each one's source span.
    /// Changed clips on a track stay butted together (later ones slide by however much earlier ones
    /// grew or shrank), and anything that would be overlapped is pushed later instead.
    mutating func setSpeed(ids: Set<UUID>, speed: Double, sticky: Bool = false) {
        let speed = min(max(speed, 0.05), 100)
        retime(ids: ids, sticky: sticky) { $0.speed = speed }
    }

    /// Sets the speed ramp drawn in the inspector on these clips (each over its own footage), with the
    /// middle speed: `points` are where the ramps start and end (fractions of each clip's footage, see
    /// `SpeedRamp.drawn`), `start` and `end` the speeds outside them. Each keeps its footage; its length follows.
    mutating func setRamp(ids: Set<UUID>, speed: Double, points: (Double, Double, Double, Double), start: Double, end: Double, sticky: Bool = false) {
        let clamp = { (v: Double) in min(max(v, 0.05), 100) }
        retime(ids: ids, sticky: sticky) { c in
            let s0 = c.sourceStart, s1 = c.sourceStart + c.sourceLength
            c.speed = clamp(speed)
            c.ramp = SpeedRamp.drawn(s0: s0, s1: s1, points: points, start: clamp(start), end: clamp(end), mid: c.speed)
        }
    }

    /// Changes how the given clips play, each keeping its footage so its length follows.
    /// Changed clips on a track stay butted together (later ones slide by however much earlier ones
    /// grew or shrank), and anything that would be overlapped is pushed later instead.
    mutating func retime(ids: Set<UUID>, sticky: Bool = false, _ change: (inout Clip) -> Void) {
        if sticky {
            // Work out the changed clips as usual, then let whatever touched them follow.
            var plain = self
            plain.retime(ids: ids, change)
            var edited: [UUID: Clip] = [:]
            for c in plain.clips where ids.contains(c.id) { edited[c.id] = c }
            let carried = carried(by: edited)
            for i in clips.indices {
                if let c = edited[clips[i].id] ?? carried[clips[i].id] { clips[i] = c }
            }
            return
        }
        for track in videoTracks + audioTracks {
            let order = clips.indices.filter { clips[$0].trackID == track.id }.sorted { clips[$0].start < clips[$1].start }
            guard order.contains(where: { ids.contains(clips[$0].id) && clips[$0].playsSource }) else { continue }
            var shift = 0.0
            var prevEnd = 0.0
            for i in order {
                var c = clips[i]
                if ids.contains(c.id), c.playsSource {
                    let before = c.duration
                    c.retime(snap: snapFrame, minimum: 1 / fps, change)
                    c.start += shift
                    shift += c.duration - before
                } else if ids.contains(c.id) {
                    c.start += shift
                }
                c.start = max(c.start, prevEnd)
                prevEnd = c.end
                clips[i] = c
            }
        }
    }

    /// Sticky edges: when edited clips' ends move, clips touching those ends ride along, and so does
    /// anything touching them in turn, with linked partners kept in sync. A clip that a growing edit
    /// runs into joins in too. `edited` holds the edited clips' new states; the result holds the new
    /// state of every clip carried along.
    func carried(by edited: [UUID: Clip]) -> [UUID: Clip] {
        let touch = 0.5 / fps
        var out: [UUID: Clip] = [:]
        var queue: [(track: UUID, oldEnd: Double, newEnd: Double)] = []
        for (id, e) in edited {
            if let o = clip(id) { queue.append((o.trackID, o.end, e.end)) }
        }
        while !queue.isEmpty {
            let q = queue.removeFirst()
            let shift = q.newEnd - q.oldEnd
            guard abs(shift) > 1e-9 else { continue }
            // Only the next clip along can be touching or run into; ones further on are reached through it.
            guard !isLocked(q.track) else { continue }
            let after = clips.filter { $0.trackID == q.track && edited[$0.id] == nil && $0.start >= q.oldEnd - touch }
            guard let nearest = after.map(\.start).min() else { continue }
            for c in after where c.start <= nearest + 1e-9 && out[c.id] == nil {
                let touching = abs(c.start - q.oldEnd) <= touch
                let runInto = shift > 0 && c.start < q.newEnd - 1e-9
                guard touching || runInto else { continue }
                let s = q.newEnd - c.start
                for id in linked([c.id]) where edited[id] == nil && out[id] == nil {
                    guard var m = clip(id) else { continue }
                    let oldEnd = m.end
                    m.start += s
                    out[id] = m
                    queue.append((m.trackID, oldEnd, m.end))
                }
            }
        }
        return out
    }

    /// True when applying `changed` leaves nothing before zero and no two clips on a track overlapping.
    func fits(_ changed: [UUID: Clip]) -> Bool {
        if changed.values.contains(where: { $0.start < -1e-9 }) { return false }
        let all = clips.map { changed[$0.id] ?? $0 }
        for (track, group) in Dictionary(grouping: all, by: \.trackID) {
            _ = track
            let sorted = group.sorted { $0.start < $1.start }
            for (a, b) in zip(sorted, sorted.dropFirst()) where changed[a.id] != nil || changed[b.id] != nil {
                if a.end > b.start + 1e-6 { return false }
            }
        }
        return true
    }

    // MARK: Transitions

    /// The clip ending where this one starts, on the same track.
    func previous(touching c: Clip) -> Clip? {
        let tol = 0.5 / fps
        return clips.first { $0.id != c.id && $0.trackID == c.trackID && $0.kind != .audio && abs($0.end - c.start) <= tol }
    }

    /// The clip starting where this one ends, on the same track.
    func next(touching c: Clip) -> Clip? {
        let tol = 0.5 / fps
        return clips.first { $0.id != c.id && $0.trackID == c.trackID && $0.kind != .audio && abs($0.start - c.end) <= tol }
    }

    /// Unused media before a clip's in point, in timeline seconds.
    private func headRoom(_ c: Clip) -> Double {
        c.playsSource ? c.timelineSpan(from: 0, to: c.sourceStart) : .infinity
    }

    /// Unused media after a clip's out point, in timeline seconds.
    private func tailRoom(_ c: Clip) -> Double {
        guard c.playsSource, let limit = sourceLimit(c) else { return .infinity }
        return max(0, c.timelineSpan(from: c.sourceStart + c.sourceLength, to: limit))
    }

    /// Where the transition into `b` from `a` sits. A dissolve or wipe needs both pictures at once, so
    /// it ends at the cut using media from before `b`'s in point, or failing that starts at the cut
    /// using media after `a`'s out point. A dip to black needs neither and sits across the cut.
    func transitionSpan(from a: Clip, into b: Clip) -> (start: Double, end: Double, fromHead: Bool)? {
        guard let t = b.transitionIn, b.kind != .audio, a.kind != .audio else { return nil }
        let cut = b.start
        let frame = 1 / fps
        if t.kind == .dipToBlack {
            let d = min(t.duration, 2 * a.duration, 2 * b.duration)
            return d >= frame ? (cut - d / 2, cut + d / 2, false) : nil
        }
        let want = min(t.duration, a.duration, b.duration)
        let head = headRoom(b), tail = tailRoom(a)
        if head >= want { return (cut - want, cut, true) }
        if tail >= want { return (cut, cut + want, false) }
        let d = max(head, tail)
        guard d >= frame else { return nil }
        return head >= tail ? (cut - d, cut, true) : (cut, cut + d, false)
    }

    /// How transitions on either side of a clip change the way it's drawn.
    func transitionPlan(_ c: Clip) -> TransitionPlan {
        var plan = TransitionPlan()
        guard c.kind != .audio else { return plan }
        if let a = previous(touching: c), let span = transitionSpan(from: a, into: c), let kind = c.transitionIn?.kind {
            if kind == .dipToBlack {
                plan.reveal = TransitionEdge(start: c.start, end: span.end, kind: kind)
            } else {
                plan.reveal = TransitionEdge(start: span.start, end: span.end, kind: kind)
                if span.fromHead { plan.leadIn = c.start - span.start }
            }
        }
        if let b = next(touching: c), let span = transitionSpan(from: c, into: b), let kind = b.transitionIn?.kind {
            if kind == .dipToBlack {
                plan.conceal = TransitionEdge(start: span.start, end: c.end, kind: kind)
            } else if !span.fromHead {
                plan.tailOut = span.end - c.end
            }
        }
        return plan
    }

    // MARK: Gaps

    /// The empty stretch on a track around a time: from the end of the clip before (or the start of
    /// the timeline) to the start of the clip after. Nil if the time is on a clip or past the last one.
    func gap(on track: UUID, at t: Double) -> (start: Double, end: Double)? {
        let here = clips.filter { $0.trackID == track }
        guard !here.contains(where: { t >= $0.start && t < $0.end }) else { return nil }
        let before = here.filter { $0.end <= t + 1e-9 }.map(\.end).max() ?? 0
        guard let after = here.filter({ $0.start >= t - 1e-9 }).map(\.start).min(), after - before > 1e-6 else { return nil }
        return (before, after)
    }

    /// Pulls everything on a track from a time onward left by an amount, with linked clips on other
    /// tracks moving too. If something that isn't moving is in the way, it goes only as far as fits.
    /// Returns how far it moved.
    @discardableResult
    mutating func pullLeft(on track: UUID, from time: Double, by amount: Double) -> Double {
        guard !isLocked(track), amount > 1e-9 else { return 0 }
        let movers = unlocked(linked(Set(clips.filter { $0.trackID == track && $0.start >= time - 1e-6 }.map(\.id))))
        guard !movers.isEmpty else { return 0 }
        func moved(_ d: Double) -> [UUID: Clip] {
            var out: [UUID: Clip] = [:]
            for c in clips where movers.contains(c.id) { var m = c; m.start -= d; out[c.id] = m }
            return out
        }
        var d = amount
        if !fits(moved(d)) {
            var ok = 0.0, bad = d
            for _ in 0..<30 { let mid = (ok + bad) / 2; if fits(moved(mid)) { ok = mid } else { bad = mid } }
            d = snapFrame(ok) <= ok + 1e-9 ? snapFrame(ok) : ok
            if !fits(moved(d)) { d = ok }
        }
        guard d > 1e-9 else { return 0 }
        for (id, c) in moved(d) { if let i = index(of: id) { clips[i] = c } }
        return d
    }

    /// Closes every gap between clips on a track, so they run back to back from the first clip.
    mutating func closeAllGaps(on track: UUID) {
        for _ in 0..<500 {
            let here = clips.filter { $0.trackID == track }.sorted { $0.start < $1.start }
            guard let i = here.indices.dropLast().first(where: { here[$0 + 1].start - here[$0].end > 1e-6 }) else { return }
            let next = here[i + 1]
            let shift = next.start - here[i].end
            if pullLeft(on: track, from: next.start, by: shift) < 1e-9 { return }
        }
    }

    /// Breaks the link between the given clips and their partners.
    mutating func unlink(ids: Set<UUID>) {
        let all = linked(ids)
        for i in clips.indices where all.contains(clips[i].id) { clips[i].linkID = nil }
    }

    /// After files got shorter (saved over, re-exported): their clips that reach past the new end
    /// stop where it does, and any that start past it go.
    mutating func fitClips(toMedia ids: Set<UUID>) {
        var gone = Set<UUID>()
        for i in clips.indices {
            let c = clips[i]
            guard let id = c.assetID, ids.contains(id), let limit = sourceLimit(c), limit > 0,
                  c.sourceStart + c.sourceLength > limit + 1e-4 else { continue }
            if c.sourceStart >= limit - 1e-3 { gone.insert(c.id); continue }
            // Where on the timeline the clip reaches the file's end.
            var lo = c.start, hi = c.end
            for _ in 0..<40 {
                let m = (lo + hi) / 2
                if c.sourceTime(at: m) < limit { lo = m } else { hi = m }
            }
            clips[i].trimTail(to: lo)
        }
        clips.removeAll { gone.contains($0.id) }
    }

    mutating func sanitize() {
        let trackIDs = Set(videoTracks.map(\.id) + audioTracks.map(\.id))
        clips.removeAll { !trackIDs.contains($0.trackID) || $0.duration <= 1e-6 }
        for i in clips.indices {
            clips[i].start = max(0, clips[i].start)
            clips[i].clampFades()
            let length = clips[i].duration
            clips[i].transform?.zoom?.fit(length: length)
        }
        // The caption track goes with the last captioned clip (deleted, or its captions taken off): it could
        // never show anything again. Undo brings both back.
        if captions != nil, !clips.contains(where: { $0.captioned == true }) {
            captions = nil
            captionFixes = nil
        }
    }
}

// MARK: - Helpers

/// How times are shown (Settings > General): full timecode with frames, or plain minutes and seconds.
enum TimeStyle: String, CaseIterable, Identifiable {
    case timecode, simple
    var id: Self { self }
    static let key = "timeStyle"
    static var current: TimeStyle { UserDefaults.standard.string(forKey: key).flatMap(TimeStyle.init(rawValue:)) ?? .timecode }
}

enum Timecode {
    /// A time as the person chose to see times: "00:00:05:15", or "0:05.50".
    static func string(_ t: Double, fps: Double) -> String {
        TimeStyle.current == .simple ? simple(t) : full(t, fps: fps)
    }

    /// Minutes, seconds and hundredths ("0:05.50"), with hours when there are any ("1:02:05.50").
    static func simple(_ t: Double) -> String {
        let cs = Int((max(0, t) * 100).rounded())
        let c = cs % 100, secs = cs / 100
        let s = secs % 60, m = (secs / 60) % 60, h = secs / 3600
        return h > 0 ? String(format: "%d:%02d:%02d.%02d", h, m, s, c) : String(format: "%d:%02d.%02d", m, s, c)
    }

    static func full(_ t: Double, fps: Double) -> String {
        let f = max(1, Int(fps.rounded()))
        let total = Int((max(0, t) * fps).rounded())
        let frames = total % f
        let secs = total / f
        let s = secs % 60, m = (secs / 60) % 60, h = secs / 3600
        return String(format: "%02d:%02d:%02d:%02d", h, m, s, frames)
    }

    /// Reads a typed timecode. "1:02:03" counts from the right (frames, seconds, minutes, hours);
    /// plain digits are read in pairs from the right, so "1000" is 10 seconds.
    /// With simple times, a typed "0:05.50" or "1:05" is minutes and seconds (the way they're shown).
    static func parse(_ s: String, fps: Double) -> Double? {
        let f = max(1, Int(fps.rounded()))
        let text = s.trimmingCharacters(in: .whitespaces)
        if TimeStyle.current == .simple, text.range(of: #"^\d+(:\d{1,2}){0,2}(\.\d+)?$"#, options: .regularExpression) != nil {
            let parts = text.split(separator: ":").map { Double($0) ?? 0 }
            return parts.reduce(0) { $0 * 60 + $1 }
        }
        var parts: [Int] = []
        if text.contains(where: { ":;.".contains($0) }) {
            let comps = text.split(whereSeparator: { ":;.".contains($0) }).map(String.init)
            guard !comps.isEmpty, comps.count <= 4 else { return nil }
            for c in comps {
                guard let v = Int(c), v >= 0 else { return nil }
                parts.append(v)
            }
        } else {
            guard !text.isEmpty, text.allSatisfy(\.isNumber), text.count <= 8 else { return nil }
            var digits = Array(text)
            while !digits.isEmpty {
                let pair = digits.suffix(2)
                parts.insert(Int(String(pair)) ?? 0, at: 0)
                digits.removeLast(pair.count)
            }
        }
        let r = Array(parts.reversed()) + [0, 0, 0, 0]
        let frames = ((r[3] * 60 + r[2]) * 60 + r[1]) * f + r[0]
        return Double(frames) / fps
    }

    static func short(_ t: Double) -> String {
        let secs = Int(max(0, t).rounded())
        let s = secs % 60, m = (secs / 60) % 60, h = secs / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

func dbToLinear(_ db: Double) -> Double {
    db <= -59.5 ? 0 : pow(10, db / 20)
}

func formatDB(_ db: Double) -> String {
    if db <= -59.5 { return "−∞ dB" }
    let v = (db * 10).rounded() / 10
    return (v > 0 ? "+" : v < 0 ? "−" : "") + String(format: "%.1f dB", abs(v))
}
