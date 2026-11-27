import Foundation
#if canImport(Accelerate)
import Accelerate
#endif

// Several cameras filming the same session (a class from above, from the side, a face camera), synced by
// their sound. The timeline stays an ordinary edit: one camera's clip at a time on the main track, and the
// session's sound running underneath, unbroken. Switching camera swaps a stretch of the main track to
// another camera's footage of the same moment; picture-in-picture puts another camera small on a track above.

/// Cameras of one session, and how they line up. Angle 0 is the one the others were synced to.
struct AngleGroup: Codable, Hashable, Identifiable {
    struct Angle: Codable, Hashable {
        var assetID: UUID
        /// Where the session's moments are in this camera's file: file time = reference file time + offset.
        var offset: Double
        var name: String
    }

    var id = UUID()
    var angles: [Angle]

    func index(of asset: UUID?) -> Int? { angles.firstIndex { $0.assetID == asset } }
}

enum PictureCorner: String, CaseIterable {
    case bottomRight = "bottom_right", bottomLeft = "bottom_left", topRight = "top_right", topLeft = "top_left"

    var label: String {
        switch self {
        case .bottomRight: "Bottom Right"
        case .bottomLeft: "Bottom Left"
        case .topRight: "Top Right"
        case .topLeft: "Top Left"
        }
    }

    /// Small, in from the corner by a little margin.
    func transform(scale: Double = 0.32) -> ClipTransform {
        let edge = 0.5 - scale / 2 - 0.03
        let right = self == .bottomRight || self == .topRight
        let bottom = self == .bottomRight || self == .bottomLeft
        return ClipTransform(scale: scale, x: right ? edge : -edge, y: bottom ? edge : -edge)
    }
}

struct AngleError: Error { let message: String; init(_ m: String) { message = m } }

extension Project {
    func angleGroup(_ id: UUID?) -> AngleGroup? {
        guard let id else { return nil }
        return angleGroups?.first { $0.id == id }
    }

    /// The group's clips on the main track (the lowest video track it's on), not the picture-in-picture ones.
    func mainAngleClips(_ group: UUID) -> [Clip] {
        let mine = clips.filter { $0.angleGroup == group && $0.kind == .video }
        let lowest = mine.compactMap { trackIndex($0.trackID, kind: .video) }.min()
        return mine.filter { trackIndex($0.trackID, kind: .video) == lowest }.sorted { $0.start < $1.start }
    }

    /// Makes a group from a clip on the timeline and the other cameras' files. The reference clip's sound is
    /// unlinked from its picture, so it keeps playing while the picture changes camera.
    @discardableResult
    mutating func makeAngleGroup(reference clipID: UUID, angles: [AngleGroup.Angle]) throws -> UUID {
        guard let ref = clip(clipID), ref.kind == .video, let refAsset = ref.assetID else {
            throw AngleError("Pick the main camera's video clip on the timeline.")
        }
        guard !ref.isFreeze, !ref.isReversed else { throw AngleError("The main camera's clip can't be a freeze frame or reversed.") }
        let refName = asset(refAsset)?.name ?? "Camera 1"
        var group = AngleGroup(angles: [AngleGroup.Angle(assetID: refAsset, offset: 0, name: refName)])
        for a in angles where a.assetID != refAsset && !group.angles.contains(where: { $0.assetID == a.assetID }) {
            group.angles.append(a)
        }
        guard group.angles.count > 1 else { throw AngleError("Multi-angle needs at least two cameras.") }
        unlink(ids: [clipID])
        if let i = index(of: clipID) { clips[i].angleGroup = group.id }
        angleGroups = (angleGroups ?? []) + [group]
        return group.id
    }

    /// The clip, showing another camera of its group at the same moments. Trimmed to where that camera has
    /// footage; an error if it has none there.
    func clip(_ c: Clip, showing j: Int) throws -> Clip {
        guard let g = angleGroup(c.angleGroup), let i = g.index(of: c.assetID), g.angles.indices.contains(j) else {
            throw AngleError("That clip isn't part of a multi-angle group.")
        }
        guard !c.isFreeze, !c.isReversed else { throw AngleError("Freeze frames and reversed clips can't change camera.") }
        guard let target = asset(g.angles[j].assetID) else { throw AngleError("Camera \(j + 1)'s file isn't in the library.") }
        let shift = g.angles[j].offset - g.angles[i].offset
        var n = c
        n.assetID = target.id
        n.sourceStart = c.sourceStart + shift
        n.ramp = c.ramp?.shifted(by: shift)
        let limit = target.duration
        // Where this camera starts and stops, on the timeline.
        func at(_ s: Double) -> Double {
            var lo = n.start - 1e6, hi = n.end + 1e6
            for _ in 0..<80 { let m = (lo + hi) / 2; if n.sourceTime(at: m) < s { lo = m } else { hi = m } }
            return hi
        }
        if n.sourceTime(at: n.start) < 0 { n.trimHead(to: min(n.end, at(0))) }
        if n.sourceTime(at: n.end) > limit { n.trimTail(to: max(n.start, at(limit))) }
        let frame = 1 / fps
        guard n.duration >= frame, n.sourceStart >= -1e-3 else {
            throw AngleError("\(g.angles[j].name) wasn't recording then.")
        }
        n.sourceStart = max(0, n.sourceStart)
        return n
    }

    /// From time `t` to the end of the clip there, the main track shows camera `j`. Returns the new clip's id.
    @discardableResult
    mutating func switchAngle(group: UUID, to j: Int, at t: Double) throws -> UUID {
        guard let c = mainAngleClips(group).first(where: { $0.start - 1e-6 <= t && t < $0.end - 1e-6 }) else {
            throw AngleError("There's no multi-angle clip at \(Timecode.simple(t)).")
        }
        var id = c.id
        if t > c.start + 0.5 / fps, t < c.end - 0.5 / fps {
            guard let right = split(ids: [c.id], at: t).first else { throw AngleError("Couldn't cut there.") }
            id = right
        }
        guard let i = index(of: id) else { throw AngleError("Couldn't find the clip.") }
        let piece = clips[i]
        if angleGroup(group)?.index(of: piece.assetID) == j { return id }
        let n = try clip(piece, showing: j)
        clips[i] = n
        // Where the new camera starts late or stops early, the old one fills in.
        if n.start > piece.start + 1e-6 {
            var head = piece
            head.id = UUID()
            head.trimTail(to: n.start)
            clips.append(head)
        }
        if n.end < piece.end - 1e-6 {
            var tail = piece
            tail.id = UUID()
            tail.trimHead(to: n.end)
            clips.append(tail)
        }
        return id
    }

    /// The whole clip shows camera `j`.
    mutating func showAngle(_ j: Int, clip id: UUID) throws {
        guard let i = index(of: id) else { throw AngleError("No clip with id \(id).") }
        clips[i] = try clip(clips[i], showing: j)
    }

    /// Camera `j`, small in a corner over these clips, on the video track above them.
    @discardableResult
    mutating func addPictureInPicture(angle j: Int, over ids: [UUID], corner: PictureCorner, scale: Double = 0.32) throws -> [UUID] {
        var made: [UUID] = []
        for id in ids {
            guard let c = clip(id), c.angleGroup != nil, c.kind == .video else { continue }
            var pip = try clip(c, showing: j)
            pip.id = UUID()
            pip.linkID = nil
            pip.transitionIn = nil
            pip.transform = corner.transform(scale: scale)
            let above = (trackIndex(c.trackID, kind: .video) ?? 0) + 1
            let free = videoTracks.indices.dropFirst(above).first { k in
                let t = videoTracks[k]
                return !t.locked && !clips.contains { $0.trackID == t.id && $0.start < pip.end - 1e-6 && $0.end > pip.start + 1e-6 }
            }
            pip.trackID = free.map { videoTracks[$0].id } ?? addTrack(.video)
            clips.append(pip)
            made.append(pip.id)
        }
        guard !made.isEmpty else { throw AngleError("Pick multi-angle clips to put the other camera over.") }
        return made
    }
}

// MARK: - Lining cameras up by their sound

enum SoundSync {
    /// How loud each moment is, as onsets: where the sound gets louder (claps, a word starting, a brush
    /// tapped on the jar), which every microphone in the room hears at the same moment.
    static func onsets(_ levels: [Float]) -> [Float] {
        guard levels.count > 1 else { return levels }
        var out = [Float](repeating: 0, count: levels.count)
        for i in 1..<levels.count { out[i] = max(0, levels[i] - levels[i - 1]) }
        // Centred and scaled, so a loud camera and a quiet one count the same.
        let mean = out.reduce(0, +) / Float(out.count)
        var v: Float = 0
        for x in out { v += (x - mean) * (x - mean) }
        let sd = max(1e-6, (v / Float(out.count)).squareRoot())
        return out.map { ($0 - mean) / sd }
    }

    /// Averages `factor` steps into one.
    static func coarse(_ x: [Float], by factor: Int) -> [Float] {
        guard factor > 1 else { return x }
        return stride(from: 0, to: x.count - factor + 1, by: factor).map { i in
            var s: Float = 0
            for k in 0..<factor { s += x[i + k] }
            return s / Float(factor)
        }
    }

    /// The lag (in steps) that best lines `b` up with `a`: b[n + lag] matches a[n]. Searched within
    /// `range`, needing at least `minOverlap` steps in common. Also how clear a winner it is (best over the
    /// next best a little way off, > 1.5 is confident).
    static func bestLag(_ a: [Float], _ b: [Float], range: ClosedRange<Int>, minOverlap: Int) -> (lag: Int, score: Float, clarity: Float)? {
        var scores: [(Int, Float)] = []
        scores.reserveCapacity(range.count)
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                for lag in range {
                    let lo = max(0, -lag), hi = min(pa.count, pb.count - lag)
                    guard hi - lo >= minOverlap else { continue }
                    var s: Float = 0
                    #if canImport(Accelerate)
                    vDSP_dotpr(pa.baseAddress! + lo, 1, pb.baseAddress! + lo + lag, 1, &s, vDSP_Length(hi - lo))
                    #else
                    var n = lo
                    while n < hi { s += pa[n] * pb[n + lag]; n += 1 }
                    #endif
                    scores.append((lag, s / Float(hi - lo).squareRoot()))
                }
            }
        }
        guard let best = scores.max(by: { $0.1 < $1.1 }) else { return nil }
        let guardBand = max(3, range.count / 400)
        let runnerUp = scores.filter { abs($0.0 - best.0) > guardBand }.map(\.1).max() ?? 0
        return (best.0, best.1, runnerUp > 0 ? best.1 / runnerUp : 10)
    }

    /// Seconds to add to a time in `reference` to find the same moment in `other`, from loudness sampled
    /// every `step` seconds (`levels` in dB or any log scale). Coarse first over `maxShift`, then fine.
    static func offset(reference: [Float], other: [Float], step: Double, maxShift: Double) -> (seconds: Double, clarity: Float)? {
        // The first half hour of the reference is plenty to find, and keeps a long class quick.
        let keep = Int(1800 / step), reachSteps = Int(maxShift / step)
        let a = onsets(Array(reference.prefix(keep))), b = onsets(Array(other.prefix(keep + reachSteps)))
        let factor = max(1, Int((0.1 / step).rounded()))
        let ca = coarse(a, by: factor), cb = coarse(b, by: factor)
        let coarseStep = step * Double(factor)
        let reach = Int(maxShift / coarseStep)
        let minOverlap = max(10, Int(20 / coarseStep))
        guard let rough = bestLag(ca, cb, range: -reach...reach, minOverlap: minOverlap) else { return nil }
        let centre = rough.lag * factor
        let fine = bestLag(a, b, range: (centre - 2 * factor)...(centre + 2 * factor), minOverlap: minOverlap * factor)
        return (Double(fine?.lag ?? centre) * step, rough.clarity)
    }
}
