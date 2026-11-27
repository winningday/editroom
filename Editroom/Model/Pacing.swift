import Foundation

// Pacing for long recordings (a two-hour painting class): find the stretches where nothing happens (no one
// talks and nothing moves) and cut them out or speed them up, and turn a stretch into a timelapse.
// Measuring the files is in ActivityScan.swift; this is what to do with what it found.

/// How loud and how busy a file is over time, measured once and kept.
struct Activity: Codable, Hashable {
    static let version = 1
    /// Seconds between sound levels, and each level in dB (full scale, so 0 is the loudest).
    var levelStep: Double
    var levels: [Float]
    /// Seconds between pictures, and how much each changed since the one before (0...1). Empty for sound.
    var motionStep: Double
    var motion: [Float]

    func level(at s: Double) -> Float? {
        guard levelStep > 0, !levels.isEmpty, s >= 0 else { return nil }
        let i = Int(s / levelStep)
        return i < levels.count ? levels[i] : nil
    }

    func motion(at s: Double) -> Float? {
        guard motionStep > 0, !motion.isEmpty, s >= 0 else { return nil }
        let i = Int((s / motionStep).rounded())
        return i < motion.count ? motion[min(i, motion.count - 1)] : nil
    }

    private static func percentile(_ x: [Float], _ p: Double) -> Float? {
        guard !x.isEmpty else { return nil }
        let s = x.sorted()
        return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * p)))]
    }

    /// Quieter than this is "nobody's talking": a little above the room's own hum, within sensible limits.
    /// `sensitivity` 0...1: higher counts more as quiet.
    func quietBelow(sensitivity: Double = 0.5) -> Float {
        let floor = Self.percentile(levels, 0.1) ?? -60
        let margin = Float(6 + 10 * sensitivity)
        return min(-28, max(-58, floor + margin))
    }

    /// Changing less than this is "nothing moves": a few times the camera's own noise.
    func stillBelow(sensitivity: Double = 0.5) -> Float {
        let noise = Self.percentile(motion, 0.1) ?? 0
        return max(0.003, noise * Float(2 + 3 * sensitivity))
    }
}

enum DeadAirKind: String, CaseIterable {
    /// No one talks and nothing moves (the safest: painting quietly still counts as something happening).
    case quietAndStill = "quiet_and_still"
    /// No one talks, whatever the picture does.
    case quiet
    /// Nothing moves, whatever the sound does.
    case still

    var label: String {
        switch self {
        case .quietAndStill: "Nothing said and nothing moving"
        case .quiet: "Nothing said"
        case .still: "Nothing moving"
        }
    }
}

extension Project {
    /// Stretches of the timeline (within `range`, or all of it) where nothing happens, at least `minLength`
    /// long, each shrunk by `pad` at both ends so the cut never clips the end of a word or a stroke.
    func deadRanges(_ kind: DeadAirKind, activity: (UUID) -> Activity?, minLength: Double = 3, pad: Double = 0.4,
                    sensitivity: Double = 0.5, range: (start: Double, end: Double)? = nil) -> [(start: Double, end: Double)] {
        let lo = range?.start ?? 0, hi = range?.end ?? duration
        guard hi - lo > minLength else { return [] }
        let hiddenVideo = Set(videoTracks.filter(\.hidden).map(\.id))
        let audible = Set(audioTracks.filter { isAudible($0) }.map(\.id))
        var cache: [UUID: (Activity, Float, Float)] = [:]
        func act(_ id: UUID) -> (Activity, Float, Float)? {
            if let c = cache[id] { return c }
            guard let a = activity(id) else { return nil }
            let v = (a, a.quietBelow(sensitivity: sensitivity), a.stillBelow(sensitivity: sensitivity))
            cache[id] = v
            return v
        }
        let sound = clips.filter { $0.kind == .audio && $0.playsSource && audible.contains($0.trackID) && $0.gainDB > -59 }
        let picture = clips.filter { $0.kind == .video && $0.playsSource && !hiddenVideo.contains($0.trackID) }
        func dead(at t: Double) -> Bool {
            if kind != .still {
                for c in sound where c.start <= t && t < c.end {
                    guard let id = c.assetID, let (a, quiet, _) = act(id) else { return false }
                    if let l = a.level(at: c.sourceTime(at: t)), l >= quiet { return false }
                }
            }
            if kind != .quiet {
                for c in picture where c.start <= t && t < c.end {
                    guard let id = c.assetID, let (a, _, still) = act(id) else { return false }
                    if let m = a.motion(at: c.sourceTime(at: t)), m >= still { return false }
                }
            }
            return true
        }
        let step = 0.1
        var out: [(start: Double, end: Double)] = []
        var runStart: Double?
        var t = lo
        while t < hi {
            if dead(at: t) {
                if runStart == nil { runStart = t }
            } else if let s = runStart {
                if t - s >= minLength { out.append((s, t)) }
                runStart = nil
            }
            t += step
        }
        if let s = runStart, hi - s >= minLength { out.append((s, hi)) }
        return out.compactMap { r in
            let a = r.start <= lo + 1e-9 ? r.start : r.start + pad
            let b = r.end >= hi - 1e-9 ? r.end : r.end - pad
            return b - a >= 0.5 ? (snapFrame(a), snapFrame(b)) : nil
        }
    }

    /// Cuts these stretches out of every unlocked track, closing up behind them so everything stays in sync.
    mutating func cut(_ ranges: [(start: Double, end: Double)]) {
        let all = Set((videoTracks + audioTracks).map(\.id))
        // Latest first, so the earlier ones' times still hold.
        for r in ranges.sorted(by: { $0.start > $1.start }) {
            rippleRemove(from: r.start, to: r.end, tracks: all)
            markers = markers?.compactMap { m in
                if m.time >= r.end { var n = m; n.time -= r.end - r.start; return n }
                return m.time > r.start ? nil : m
            }
        }
    }

    /// Plays `a...b` `by` times faster on every unlocked track (a timelapse), closing up after it so everything
    /// stays in sync. With `muteSound`, the sound in it is turned right down.
    mutating func speedUp(from a: Double, to b: Double, by factor: Double, muteSound: Bool = true) {
        let s = min(max(factor, 1.01), 100)
        guard b - a > 1 / fps else { return }
        let tracks = Set((videoTracks + audioTracks).filter { !$0.locked }.map(\.id))
        let on = { (c: Clip) in tracks.contains(c.trackID) }
        split(ids: Set(clips.filter { on($0) && $0.start < a && $0.end > a }.map(\.id)), at: a)
        split(ids: Set(clips.filter { on($0) && $0.start < b && $0.end > b }.map(\.id)), at: b)
        let eps = 0.5 / fps
        let shrink = (b - a) * (1 - 1 / s)
        for i in clips.indices where on(clips[i]) {
            var c = clips[i]
            if c.start >= a - eps && c.end <= b + eps {
                let newStart = a + (c.start - a) / s
                if c.playsSource {
                    c.retime(snap: { $0 }, minimum: 1 / fps) { k in
                        k.speed = min(100, k.speed * s)
                        if k.ramp != nil {
                            k.ramp!.startSpeed = min(100, k.ramp!.startSpeed * s)
                            k.ramp!.endSpeed = min(100, k.ramp!.endSpeed * s)
                        }
                    }
                } else {
                    c.duration = max(1 / fps, c.duration / s)
                    c.clampFades()
                }
                c.start = newStart
                if muteSound, c.kind == .audio { c.gainDB = -60 }
            } else if c.start >= b - eps {
                c.start -= shrink
            }
            clips[i] = c
        }
        markers = markers?.compactMap { m in
            if m.time >= b { var n = m; n.time -= shrink; return n }
            if m.time > a { var n = m; n.time = a + (m.time - a) / s; return n }
            return m
        }
    }

    /// Speeds each stretch up (latest first, so earlier times still hold).
    mutating func speedUp(_ ranges: [(start: Double, end: Double)], by factor: Double, muteSound: Bool = true) {
        for r in ranges.sorted(by: { $0.start > $1.start }) { speedUp(from: r.start, to: r.end, by: factor, muteSound: muteSound) }
    }
}
