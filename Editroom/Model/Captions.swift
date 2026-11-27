import Foundation

/// The caption track: one per sequence, above the video tracks. Its captions aren't stored; they're read
/// from what's said in each captioned clip (its file's transcript), so they follow every trim, cut and
/// move of the clip they come from.
struct CaptionTrack: Codable, Hashable {
    var hidden = false
    var style = CaptionStyle()
    /// The subtitle layer shown instead of what's heard (a translation); nil shows what's heard.
    var layer: UUID?
}

/// How every caption looks. One style for the whole track.
struct CaptionStyle: Codable, Hashable {
    /// Point size relative to a 1080px frame's shorter side.
    var size: Double = 64
    /// Where the captions sit, as a fraction down the frame (their middle).
    var y: Double = 0.78
    /// The word being said lights up.
    var highlight = true
    var textColor = RGBA.white
    var highlightColor = RGBA(r: 1, g: 0.84, b: 0.25, a: 1)
    /// A dark edge around the letters, so they read over anything.
    var outline = true
    var outlineColor = RGBA.black

    static let sizeRange = 28.0...140.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CaptionStyle()
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? d.y
        highlight = try c.decodeIfPresent(Bool.self, forKey: .highlight) ?? d.highlight
        textColor = try c.decodeIfPresent(RGBA.self, forKey: .textColor) ?? d.textColor
        highlightColor = try c.decodeIfPresent(RGBA.self, forKey: .highlightColor) ?? d.highlightColor
        outline = try c.decodeIfPresent(Bool.self, forKey: .outline) ?? d.outline
        outlineColor = try c.decodeIfPresent(RGBA.self, forKey: .outlineColor) ?? d.outlineColor
    }
}

/// A change to one word of a file's transcript, made on a caption: new text, or "" to leave it out.
/// Kept by file, so a fix shows wherever that file is used.
struct CaptionFix: Codable, Hashable {
    /// The word's start in the file, which identifies it.
    var start: Double
    var text: String
    /// Joined to the word before: its time goes to that word, whose text says them both.
    var merged: Bool?
}

/// One caption: a few words shown together.
struct CaptionBlock: Hashable, Identifiable {
    struct Word: Hashable {
        /// Timeline times.
        var start: Double
        var end: Double
        var text: String
        /// The word's start in its file, for fixes.
        var source: Double
        /// The words in the file it stands for (more than one when a retyped caption has new words).
        var covers: [Double]
        /// Starts a subtitle of its own (subtitles brought in from a file keep their lines as they were).
        var cue = false
    }

    /// The clip it comes from and its first word's time in the file: steady through trims and moves.
    var id: String { "\(clipID.uuidString)@\(Int((words.first?.source ?? 0) * 1000))" }
    var clipID: UUID
    var assetID: UUID
    var start: Double
    var end: Double
    var words: [Word]

    var text: String { SubtitleText.join(words.map(\.text)) }

    /// The words in the file the caption stands for, in order.
    var covered: [Double] {
        var out: [Double] = []
        for w in words { for c in w.covers where out.last != c && !out.contains(c) { out.append(c) } }
        return out
    }
}

extension Project {
    /// Clips whose speech is captioned: sound clips (a video's sound is its linked audio clip).
    var captionedClips: [Clip] {
        guard captions != nil else { return [] }
        return clips.filter { $0.captioned == true && $0.kind == .audio && $0.playsSource && !$0.playsBackwards }
    }

    /// The sound clips that captioning these clips means: each one's own sound, or its linked sound.
    func captionTargets(_ ids: Set<UUID>) -> Set<UUID> {
        let group = linked(ids)
        return Set(clips.filter { group.contains($0.id) && $0.kind == .audio && $0.playsSource }.map(\.id))
    }

    /// With nothing picked: the sound of clips from video files (people on camera), and of any track
    /// something ducks under (a voiceover). Music on its own track is left alone.
    var defaultCaptionTargets: Set<UUID> {
        let voices = Set(audioTracks.compactMap(\.duckUnder))
        return Set(clips.filter { c in
            guard c.kind == .audio, c.playsSource, let a = asset(c.assetID) else { return false }
            return a.kind == .video || voices.contains(c.trackID)
        }.map(\.id))
    }

    /// Turns captions on for these sound clips, making the caption track if there isn't one.
    mutating func addCaptions(_ ids: Set<UUID>) {
        if captions == nil { captions = CaptionTrack() }
        for i in clips.indices where ids.contains(clips[i].id) { clips[i].captioned = true }
    }

    /// Turns captions off for these clips; the track goes when nothing's captioned any more. Words fixed or
    /// left out in a file no captioned clip uses any more go too, so captioning it again starts afresh.
    mutating func removeCaptions(_ ids: Set<UUID>) {
        for i in clips.indices where ids.contains(clips[i].id) { clips[i].captioned = nil }
        if !clips.contains(where: { $0.captioned == true }) { return removeCaptionTrack() }
        let still = Set(clips.filter { $0.captioned == true }.compactMap(\.assetID))
        captionFixes = captionFixes?.filter { still.contains($0.key) }
        if captionFixes?.isEmpty == true { captionFixes = nil }
    }

    /// Removes the caption track, every clip's captions, and every word fixed or left out.
    mutating func removeCaptionTrack() {
        captions = nil
        captionFixes = nil
        for i in clips.indices { clips[i].captioned = nil }
    }

    /// Sets what a caption says. As many words as were said replace them one for one; otherwise the first
    /// word takes the whole text and the rest join it, so the caption keeps its time and the new words share
    /// it out. Empty text leaves them all out.
    mutating func setCaptionText(_ block: CaptionBlock, to text: String) {
        // Showing a layer (a translation): its own words change, nothing heard is touched.
        if let layer = activeSubtitleLayer { return setLayerCaptionText(block, to: text, layer: layer.id) }
        let new = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let said = block.covered
        var fixes = captionFixes?[block.assetID] ?? []
        func set(_ source: Double, _ t: String, merged: Bool = false) {
            fixes.removeAll { abs($0.start - source) < 0.0005 }
            fixes.append(CaptionFix(start: source, text: t, merged: merged ? true : nil))
        }
        if new.isEmpty {
            for source in said { set(source, "") }
        } else if new.count == said.count {
            // Every word set, so words an earlier edit left out or joined come back.
            for (source, t) in zip(said, new) { set(source, t) }
        } else {
            for (i, source) in said.enumerated() { set(source, i == 0 ? new.joined(separator: " ") : "", merged: i > 0) }
        }
        if captionFixes == nil { captionFixes = [:] }
        captionFixes?[block.assetID] = fixes.sorted { $0.start < $1.start }
    }
}

/// Lays out the captions: each captioned clip's words, where they're said on the timeline, in short
/// phrases that read at a glance.
enum CaptionLayout {
    /// Longest phrase, in characters, and longest time on screen.
    static let maxChars = 26
    static let maxSeconds = 2.6
    /// A pause this long starts a new caption.
    static let pause = 0.5

    static func blocks(_ project: Project, transcript: (MediaAsset) -> Transcript?) -> [CaptionBlock] {
        var out: [CaptionBlock] = []
        // A subtitle layer (a translation) in place of what's heard: its own words, and no fixes to what's heard.
        let layer = project.activeSubtitleLayer
        for clip in project.captionedClips {
            guard let asset = project.asset(clip.assetID) else { continue }
            let script = layer.map { $0.transcripts[asset.id] } ?? transcript(asset)
            guard let script, !script.isEmpty else { continue }
            out += blocks(for: clip, asset: asset, words: script.words, fixes: layer == nil ? project.captionFixes?[asset.id] ?? [] : [])
        }
        out.sort { $0.start < $1.start }
        // Overlapping speech (two people at once): each caption gives way to the next.
        for i in out.indices.dropLast() where out[i].end > out[i + 1].start {
            out[i].end = max(out[i].start + 0.05, out[i + 1].start)
        }
        return out
    }

    /// A run of talking cut into even phrases: as many as keep each within `maxChars` and `maxSeconds`,
    /// each cut at the word nearest an even share (a little nearer after a comma).
    private static func phrases(_ run: [CaptionBlock.Word]) -> [[CaptionBlock.Word]] {
        guard let first = run.first, let last = run.last else { return [] }
        // Characters up to the end of each word.
        var ends: [Int] = []
        var total = 0
        for (i, w) in run.enumerated() {
            total += SubtitleText.width(w.text) + (i > 0 && SubtitleText.needsSpace(run[i - 1].text, w.text) ? 1 : 0)
            ends.append(total)
        }
        let byChars = Int((Double(total) / Double(maxChars)).rounded(.up))
        let byTime = Int(((last.end - first.start) / maxSeconds).rounded(.up))
        let n = min(run.count, max(1, byChars, byTime))
        guard n > 1 else { return [run] }
        var cuts: [Int] = []
        var from = 0
        for k in 1..<n {
            let target = Double(total) * Double(k) / Double(n)
            // Cut after word i (from ... run.count - (n - k) - 1, leaving a word for each phrase to come).
            // Never inside a retyped word's new words: they're one edit.
            var best: Int?, bestScore = Double.infinity
            for i in from...(run.count - (n - k) - 1) where run[i].source != run[i + 1].source {
                var score = abs(Double(ends[i]) - target)
                if SubtitleText.endsClause(run[i].text) { score -= 6 }
                if score < bestScore { bestScore = score; best = i }
            }
            guard let best else { break }
            cuts.append(best)
            from = best + 1
            if from > run.count - 1 { break }
        }
        var out: [[CaptionBlock.Word]] = []
        var start = 0
        for c in cuts + [run.count - 1] {
            out.append(Array(run[start...c]))
            start = c + 1
        }
        return out
    }

    private static func blocks(for clip: Clip, asset: MediaAsset, words: [Transcript.Word], fixes: [CaptionFix]) -> [CaptionBlock] {
        let s0 = clip.sourceStart, s1 = s0 + clip.sourceLength
        let at = { (s: Double) in min(clip.end, max(clip.start, clip.start + clip.timelineSpan(from: s0, to: s))) }
        // The words heard in the clip (most of the word inside it), on the timeline, with any fixes. A word
        // joined to the one before lends it its time.
        var entries: [CaptionBlock.Word] = []
        var previous: Double?
        for w in words {
            let mid = (w.start + w.end) / 2
            guard mid >= s0, mid < s1 else { continue }
            defer { previous = w.start }
            let fix = fixes.first { abs($0.start - w.start) < 0.0005 }
            let a = at(max(w.start, s0)), b = at(min(w.end, s1))
            if fix?.merged == true {
                if let p = previous, let last = entries.last, last.covers.last == p {
                    entries[entries.count - 1].end = max(last.end, b)
                    entries[entries.count - 1].covers.append(w.start)
                }
                continue
            }
            let text = fix?.text ?? w.text
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty, b > a else { continue }
            entries.append(CaptionBlock.Word(start: a, end: b, text: text, source: w.start, covers: [w.start], cue: w.cue == true))
        }
        // A retyped word with several words in it: they share its time, by length.
        var heard: [CaptionBlock.Word] = []
        for e in entries {
            let parts = e.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count > 1 else { heard.append(e); continue }
            let weights = parts.map { Double($0.count + 1) }
            let total = weights.reduce(0, +)
            var t = e.start
            for (k, (part, wt)) in zip(parts, weights).enumerated() {
                let d = (e.end - e.start) * wt / total
                heard.append(CaptionBlock.Word(start: t, end: t + d, text: part, source: e.source, covers: e.covers, cue: k == 0 && e.cue))
                t += d
            }
        }

        // Runs of talking: broken by a pause or the end of a sentence. Each run is then cut into as few
        // even phrases as keep each one short, so no word is left on its own.
        // Subtitles brought in from a file keep their own lines: each starts where its line did.
        let cued = heard.contains { $0.cue }
        var runs: [[CaptionBlock.Word]] = []
        for w in heard {
            if cued {
                if w.cue || runs.isEmpty { runs.append([w]) } else { runs[runs.count - 1].append(w) }
            } else if let last = runs.last?.last, w.start - last.end < pause, !SubtitleText.endsSentence(last.text) {
                runs[runs.count - 1].append(w)
            } else {
                runs.append([w])
            }
        }
        let groups = cued ? runs : runs.flatMap(phrases)

        var out: [CaptionBlock] = []
        for (i, g) in groups.enumerated() {
            guard let first = g.first, let last = g.last else { continue }
            // Held a moment after the last word, never into the next caption or past the clip.
            let next = i + 1 < groups.count ? groups[i + 1][0].start : clip.end
            let end = min(next, clip.end, max(last.end + 0.25, first.start + 0.6))
            out.append(CaptionBlock(clipID: clip.id, assetID: asset.id, start: first.start, end: max(end, last.end), words: g))
        }
        return out
    }
}
