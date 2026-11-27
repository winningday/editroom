import Foundation

// Subtitles that come from somewhere other than what's heard: an SRT made elsewhere (a translation, a
// transcript fixed by hand), brought in as a layer the caption track can show instead of the speech.
// Like heard captions, a layer is kept by file, in each file's own time, so it follows every trim, cut and
// move of the clips it belongs to. Also SRT and plain-text export, and text that mixes Chinese and English.

// MARK: - SRT

struct SRTCue: Hashable {
    var start: Double
    var end: Double
    var text: String
}

enum SRT {
    /// Reads SRT (and WebVTT, which is close enough): numbered or not, comma or dot before the
    /// milliseconds, with or without hours, Windows or Mac line endings, a byte-order mark. Cue settings
    /// after the times (VTT's "align:start") and tags (<i>, {\an8}) are dropped.
    static func parse(_ raw: String) -> [SRTCue] {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var cues: [SRTCue] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            guard line.contains("-->"), let (a, b) = times(line) else { i += 1; continue }
            i += 1
            var body: [String] = []
            while i < lines.count {
                let l = lines[i].trimmingCharacters(in: .whitespaces)
                if l.isEmpty { break }
                // A cue with no blank line before the next one's times: the number line was the last text.
                if l.contains("-->"), times(l) != nil {
                    if let last = body.last, Int(last) != nil { body.removeLast() }
                    break
                }
                body.append(l)
                i += 1
            }
            let joined = clean(body.joined(separator: "\n"))
            if b > a, !joined.isEmpty { cues.append(SRTCue(start: a, end: b, text: joined)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "00:01:02,500 --> 00:01:04,000 align:start" as two times.
    private static func times(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        let rhs = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        guard let a = seconds(parts[0].trimmingCharacters(in: .whitespaces)), let b = seconds(rhs) else { return nil }
        return (a, b)
    }

    /// "01:02:03,456", "02:03.456" or "3.5" as seconds.
    static func seconds(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ":").map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for p in parts {
            guard let v = Double(p), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }

    private static func clean(_ s: String) -> String {
        var t = s
        // <i>, </font>, <00:01.000> and {\an8}-style tags.
        t = t.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\{\\[^}]*\}"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func timestamp(_ t: Double) -> String {
        let ms = Int((max(0, t) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }

    static func write(_ cues: [SRTCue]) -> String {
        var out = ""
        for (i, c) in cues.enumerated() {
            out += "\(i + 1)\n\(timestamp(c.start)) --> \(timestamp(c.end))\n\(c.text)\n\n"
        }
        return out
    }
}

// MARK: - Text in Chinese, English or both

enum SubtitleText {
    /// Chinese, Japanese and Korean characters, and their full-width punctuation: written without spaces.
    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            switch s.value {
            case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF,
                 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FFFF: return true
            default: return false
            }
        }
    }

    static func hasCJK(_ s: String) -> Bool { s.contains(where: isCJK) }

    /// Whether two words are written with a space between them: not when either side is Chinese.
    static func needsSpace(_ a: String, _ b: String) -> Bool {
        guard let l = a.last, let f = b.first else { return false }
        return !(isCJK(l) || isCJK(f))
    }

    static func join(_ words: [String]) -> String {
        var out = ""
        for w in words {
            if !out.isEmpty, needsSpace(out, w) { out += " " }
            out += w
        }
        return out
    }

    /// How wide a caption reads: a Chinese character takes about the room of two letters.
    static func width(_ s: String) -> Int { s.reduce(0) { $0 + (isCJK($1) ? 2 : 1) } }

    /// Words of a line: split at spaces, and Chinese split into characters (punctuation stays with the
    /// character before it), so each can light up as it's said and share the line's time fairly.
    static func words(from text: String) -> [String] {
        var out: [String] = []
        for token in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            guard hasCJK(token) else { out.append(token); continue }
            var latin = ""
            for c in token {
                if isCJK(c) {
                    if !latin.isEmpty { out.append(latin); latin = "" }
                    if isPunctuation(c), let last = out.last, !last.isEmpty { out[out.count - 1] = last + String(c) } else { out.append(String(c)) }
                } else if isPunctuation(c), latin.isEmpty, let last = out.last {
                    out[out.count - 1] = last + String(c)
                } else {
                    latin.append(c)
                }
            }
            if !latin.isEmpty { out.append(latin) }
        }
        return out
    }

    static func isPunctuation(_ c: Character) -> Bool {
        c.isPunctuation || "，。！？；：、）》」』】…".contains(c)
    }

    /// A sentence ends here, in either language.
    static func endsSentence(_ w: String) -> Bool {
        guard let c = w.last else { return false }
        return ".?!。？！…".contains(c)
    }

    static func endsClause(_ w: String) -> Bool {
        guard let c = w.last else { return false }
        return ",;:，；：、".contains(c)
    }
}

// MARK: - Layers

/// Subtitles brought in from a file, kept by library item in each file's own time.
struct SubtitleLayer: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var transcripts: [UUID: Transcript] = [:]
}

extension Transcript {
    /// Words for a line of text spread over `start...end` (by how long each word is to read), the first
    /// one starting a subtitle of its own.
    static func words(for text: String, from start: Double, to end: Double) -> [Word] {
        let parts = SubtitleText.words(from: text)
        guard !parts.isEmpty, end > start else { return [] }
        let weights = parts.map { Double(SubtitleText.width($0) + 1) }
        let total = weights.reduce(0, +)
        var t = start
        var out: [Word] = []
        for (i, (p, w)) in zip(parts, weights).enumerated() {
            let d = (end - start) * w / total
            out.append(Word(start: t, end: t + d, text: p, cue: i == 0 ? true : nil))
            t += d
        }
        return out
    }

    /// Replaces what's said between `a` and `b` (in the file) with these words.
    mutating func replace(from a: Double, to b: Double, with new: [Word]) {
        words.removeAll { w in
            let mid = (w.start + w.end) / 2
            return mid >= a - 1e-6 && mid < b + 1e-6
        }
        words += new
        words.sort { $0.start < $1.start }
    }
}

extension Project {
    /// The layer the caption track shows; nil means what's heard.
    var activeSubtitleLayer: SubtitleLayer? {
        guard let id = captions?.layer else { return nil }
        return subtitleLayers?.first { $0.id == id }
    }

    /// Changes a layer, marking the captions as changed so they're laid out again.
    mutating func updateSubtitleLayer(_ id: UUID, _ body: (inout SubtitleLayer) -> Void) {
        guard let i = subtitleLayers?.firstIndex(where: { $0.id == id }) else { return }
        body(&subtitleLayers![i])
        subtitleRevision = UUID()
    }

    /// Shows a layer on the caption track (nil: what's heard).
    mutating func showSubtitleLayer(_ id: UUID?) {
        guard captions != nil else { return }
        captions?.layer = id.flatMap { id in subtitleLayers?.contains { $0.id == id } == true ? id : nil }
        subtitleRevision = UUID()
    }

    mutating func removeSubtitleLayer(_ id: UUID) {
        subtitleLayers?.removeAll { $0.id == id }
        if subtitleLayers?.isEmpty == true { subtitleLayers = nil }
        if captions?.layer == id { captions?.layer = nil }
        subtitleRevision = UUID()
    }

    /// The sound clips that subtitles timed to the timeline are placed on: those already captioned, else the
    /// ones that would be (people talking), else any sound from a file.
    var subtitleHosts: [Clip] {
        let usable = clips.filter { $0.kind == .audio && $0.playsSource && !$0.playsBackwards && $0.assetID != nil }
        let captioned = usable.filter { $0.captioned == true }
        if !captioned.isEmpty { return captioned }
        let talking = defaultCaptionTargets
        let voices = usable.filter { talking.contains($0.id) }
        return voices.isEmpty ? usable : voices
    }

    /// Brings in subtitles timed to the timeline (an SRT exported from here and translated, say) as a new
    /// layer, and shows it. Each subtitle goes to the clip of people talking under its middle, in that clip's
    /// file time. Returns how many subtitles found a clip.
    @discardableResult
    mutating func importSubtitles(timeline cues: [SRTCue], name: String) -> (placed: Int, missed: Int) {
        var layer = SubtitleLayer(name: name)
        var captionedNow = Set<UUID>()
        var placed = 0
        let hosts = subtitleHosts
        let audio = audioTracks.map(\.id)
        let order = { (c: Clip) in audio.firstIndex(of: c.trackID) ?? 99 }
        for cue in cues {
            let mid = (cue.start + cue.end) / 2
            guard let clip = hosts.filter({ $0.start <= mid && mid < $0.end }).min(by: { order($0) < order($1) }),
                  let asset = clip.assetID else { continue }
            let a = clip.sourceTime(at: max(cue.start, clip.start)), b = clip.sourceTime(at: min(cue.end, clip.end))
            guard b > a else { continue }
            var t = layer.transcripts[asset] ?? Transcript(words: [], language: name)
            t.replace(from: a, to: b, with: Transcript.words(for: cue.text, from: a, to: b))
            layer.transcripts[asset] = t
            captionedNow.insert(clip.id)
            placed += 1
        }
        guard placed > 0 else { return (0, cues.count) }
        add(layer, captioning: captionedNow)
        return (placed, cues.count - placed)
    }

    /// Brings in subtitles timed to one file (a transcript made of the original recording) as a new layer.
    @discardableResult
    mutating func importSubtitles(file cues: [SRTCue], asset: UUID, name: String) -> Int {
        var t = Transcript(words: [], language: name)
        for cue in cues where cue.end > cue.start { t.words += Transcript.words(for: cue.text, from: cue.start, to: cue.end) }
        t.words.sort { $0.start < $1.start }
        guard !t.isEmpty else { return 0 }
        var layer = SubtitleLayer(name: name)
        layer.transcripts[asset] = t
        let theirs = Set(clips.filter { $0.assetID == asset && $0.kind == .audio && $0.playsSource }.map(\.id))
        add(layer, captioning: theirs)
        return cues.count
    }

    private mutating func add(_ layer: SubtitleLayer, captioning ids: Set<UUID>) {
        // Bringing the same name in again replaces it (a corrected translation).
        if let old = subtitleLayers?.first(where: { $0.name == layer.name }) { removeSubtitleLayer(old.id) }
        subtitleLayers = (subtitleLayers ?? []) + [layer]
        addCaptions(ids)
        captions?.layer = layer.id
        subtitleRevision = UUID()
    }

    /// Retypes a caption on a layer: its words make way for the new ones, over the same time.
    mutating func setLayerCaptionText(_ block: CaptionBlock, to text: String, layer id: UUID) {
        updateSubtitleLayer(id) { layer in
            guard var t = layer.transcripts[block.assetID] else { return }
            let covered = Set(block.covered.map { Int(($0 * 1000).rounded()) })
            let mine = t.words.filter { covered.contains(Int(($0.start * 1000).rounded())) }
            guard let a = mine.map(\.start).min(), let b = mine.map(\.end).max() else { return }
            t.replace(from: a, to: b, with: Transcript.words(for: text, from: a, to: b))
            layer.transcripts[block.assetID] = t
        }
    }

    /// Every caption as it shows, as SRT cues on the timeline (or, with `range`, from its start).
    func subtitleCues(_ blocks: [CaptionBlock], range: (start: Double, end: Double)? = nil) -> [SRTCue] {
        var out: [SRTCue] = []
        for b in blocks {
            var s = b.start, e = b.end
            if let r = range {
                guard e > r.start, s < r.end else { continue }
                s = max(s, r.start) - r.start
                e = min(e, r.end) - r.start
            }
            let text = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if e > s, !text.isEmpty { out.append(SRTCue(start: s, end: e, text: text)) }
        }
        return out
    }

    /// What's said, as plain text: a line per caption, a blank line where there's a long pause, and with
    /// `times` each line led by its time.
    func subtitleText(_ blocks: [CaptionBlock], times: Bool = false) -> String {
        var out = ""
        var lastEnd: Double?
        for b in blocks {
            if let e = lastEnd, b.start - e > 2 { out += "\n" }
            if times { out += "[\(Timecode.simple(b.start))] " }
            out += b.text + "\n"
            lastEnd = b.end
        }
        return out
    }
}
