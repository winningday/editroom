import Foundation

// One lesson going through the translation and dubbing pipeline in OpenClaw-Artist-Management/translator
// (see its PIPELINE.md): Chinese out of this edit → Job 0 cleanup → Maya approves (gate A) → Job 1
// translation → Maya reads it (gate B) → audition → Maya listens (gate C) → full dub → subtitles re-timed to
// the voice → back onto the timeline. Kept with the project, so a lesson can be picked up where it was left.

enum DubStage: Int, Codable, CaseIterable, Comparable {
    case send, cleanup, reviewCleanup, translate, reviewTranslation, audition, reviewAudition, dub, retime, deliver, done

    static func < (a: DubStage, b: DubStage) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .send: "Send the Chinese"
        case .cleanup: "Clean up (Job 0)"
        case .reviewCleanup: "Maya checks the Chinese"
        case .translate: "Translate (Job 1)"
        case .reviewTranslation: "Read the English"
        case .audition: "Audition the voice"
        case .reviewAudition: "Listen to the audition"
        case .dub: "Dub the whole lesson"
        case .retime: "Time subtitles to the voice"
        case .deliver: "Deliver to 交付 and main"
        case .done: "Done"
        }
    }

    /// A step where a person decides, not a program.
    var isGate: Bool { self == .reviewCleanup || self == .reviewTranslation || self == .reviewAudition }
}

struct DubJob: Codable, Hashable {
    /// The file written to translator/input/, e.g. "Lesson 3中字.srt".
    var name: String
    /// The English stem (marker stripped): "Lesson 3".
    var stem: String
    var stage: DubStage = .cleanup
    /// The edit as it was when the Chinese was sent: the dub only lines up with this cut.
    var cutStamp: String
    /// The English and the cleaned Chinese as they showed on the timeline when they came back, to find
    /// exactly what Maya changed (and nothing the timeline couldn't place).
    var deliveredEnglish: [SRTCue.Saved]?
    var deliveredClean: [SRTCue.Saved]?
    /// Maya changed the cleaned Chinese at gate A (the translator mirrors her wording).
    var mayaEditedClean: Bool?
    /// What Claude said last (the cleanup report is in Chinese, for Maya).
    var lastReport: String?

    var clean: String { (name as NSString).deletingPathExtension + "_clean.srt" }
    var en: String { "\(stem)_en.srt" }
    var enRaw: String { "\(stem)_en_raw.srt" }
    var zh: String { "\(stem)_zh.srt" }
    var dubFolder: String { "dub/\(stem)_en" }
    var auditionFolder: String { "dub/audition/\(stem)" }
    var dubsource: String { "\(dubFolder)/\(stem)_en_dubsource.srt" }
    var words: String { "\(dubFolder)/words.json" }
}

extension SRTCue {
    /// A cue as kept in the project (SRTCue itself isn't Codable, to keep it a plain value).
    struct Saved: Codable, Hashable { var start: Double; var end: Double; var text: String }
    var saved: Saved { Saved(start: start, end: end, text: text) }
}

/// A line Maya changed in Editroom.
struct SubtitleEdit: Hashable {
    var start: Double
    var before: String
    var after: String
}

enum DubPlan {
    /// The subtitle layer names the pipeline uses on the caption track.
    static let cleanLayer = "中文 (清理)"
    static let englishLayer = "English"
    static let chineseLayer = "中文"

    /// A fingerprint of the cut: where every clip sits and what it plays. Two edits with the same
    /// fingerprint play the same footage at the same times, so a dub made for one fits the other.
    static func cutStamp(_ p: Project) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ s: String) { for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 } }
        let order = p.clips.sorted { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }
        // The dub itself isn't part of the cut it's timed to.
        func isDub(_ c: Clip) -> Bool { p.asset(c.assetID).map { $0.path.contains("/dub/") && $0.path.hasSuffix("_dub.wav") } ?? false }
        for c in order where c.kind != .text && !isDub(c) {
            mix(String(format: "%@|%@|%.3f|%.3f|%.3f|%.4f|", c.kind.rawValue, c.assetID?.uuidString ?? "-", c.start, c.duration, c.sourceStart, c.speed))
            if let r = c.ramp { mix(String(format: "r%.3f,%.3f,%.3f,%.3f,%.3f,%.3f|", r.inFrom, r.inTo, r.outFrom, r.outTo, r.startSpeed, r.endSpeed)) }
        }
        return String(h, radix: 36)
    }

    /// What changed between the cues as delivered and as they are now: each delivered line matched to the
    /// line now starting nearest it (within half a second), and lines taken out.
    static func edits(delivered: [SRTCue], now: [SRTCue]) -> [SubtitleEdit] {
        var out: [SubtitleEdit] = []
        var used = Set<Int>()
        for d in delivered {
            let near = now.indices.filter { !used.contains($0) && abs(now[$0].start - d.start) < 0.5 }
                .min { abs(now[$0].start - d.start) < abs(now[$1].start - d.start) }
            guard let k = near else {
                out.append(SubtitleEdit(start: d.start, before: d.text, after: ""))
                continue
            }
            used.insert(k)
            let a = d.text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            let b = now[k].text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            if a != b { out.append(SubtitleEdit(start: d.start, before: a, after: b)) }
        }
        return out
    }

    /// The file name sent to the translator: the project's title, marked as Chinese subtitles the way Maya
    /// marks hers, with nothing a file name can't hold.
    static func inputName(title: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        var t = title.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == "Untitled" { t = "lesson" }
        let markers = ["中字", "中字幕", "中文字幕", "中文校对", "简体中文"]
        return (markers.contains { t.hasSuffix($0) } ? t : t + "中字") + ".srt"
    }

    /// The English stem for a Chinese file name, as srt_translator/naming.py makes it (used when Python
    /// can't be asked).
    static func fallbackStem(_ name: String) -> String {
        var s = (name as NSString).deletingPathExtension
        for m in ["简体中文字幕", "中英双语字幕", "中文字幕", "简体中文", "中英字幕", "中文校对", "中字幕", "中字", "中文", "双语", "简中", "中英"] where s.hasSuffix(m) {
            s = String(s.dropLast(m.count))
            break
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
        return s.isEmpty ? "lesson" : s
    }
}

extension DubPlan {
    /// The file's cues with Maya's edits made: each edited line found by its time and changed or taken out.
    /// Lines the timeline couldn't show are kept as they were.
    static func apply(_ edits: [SubtitleEdit], to file: [SRTCue]) -> [SRTCue] {
        var out = file
        var gone = Set<Int>()
        for e in edits {
            guard let k = out.indices.filter({ !gone.contains($0) && abs(out[$0].start - e.start) < 0.5 })
                .min(by: { abs(out[$0].start - e.start) < abs(out[$1].start - e.start) }) else { continue }
            if e.after.isEmpty { gone.insert(k) } else { out[k].text = e.after }
        }
        return out.indices.filter { !gone.contains($0) }.map { out[$0] }
    }
}

extension Project {
    /// Subtitles exactly as their lines were timed (a layer's lines start and end where they did in its file),
    /// for sending back to the translator.
    func exactCues(_ blocks: [CaptionBlock]) -> [SRTCue] {
        blocks.compactMap { b in
            let text = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let end = b.words.contains(where: \.cue) ? (b.words.last?.end ?? b.end) : b.end
            return end > b.start ? SRTCue(start: b.start, end: end, text: text) : nil
        }
    }

    func layer(named name: String) -> SubtitleLayer? { subtitleLayers?.first { $0.name == name } }
}
