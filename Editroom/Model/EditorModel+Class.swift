import AppKit
import UniformTypeIdentifiers

/// The tools for long painting classes, as the menus run them: subtitles in and out (for translation and
/// dubbing elsewhere), several cameras of one class, and taking out or speeding up where nothing happens.
extension EditorModel {
    // MARK: Subtitles

    /// Subtitles (and transcripts) bring in and write out as these.
    static let subtitleTypes: [UTType] = [UTType(filenameExtension: "srt"), UTType(filenameExtension: "vtt")].compactMap { $0 }

    private func tell(_ title: String, _ text: String) {
        let a = EditroomAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    /// Subtitles › Import Subtitles…: an SRT timed to this timeline (say, one exported from here and translated)
    /// becomes a subtitle layer the caption track shows. With one clip picked, it can be timed to that clip's file instead.
    func importSubtitlesFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.subtitleTypes
        panel.prompt = "Import"
        panel.message = "Choose an SRT. Its times can be from this timeline (one exported from here), or from one clip's original file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .utf16)) else {
            return tell("Couldn't read that file", "It isn't a text file Editroom can read.")
        }
        let cues = SRT.parse(raw)
        guard !cues.isEmpty else { return tell("No subtitles in that file", "Editroom couldn't find any subtitles in \(url.lastPathComponent).") }
        let name = url.deletingPathExtension().lastPathComponent
        // One clip picked: ask which clock the file uses.
        let picked = project.clips.filter { selection.contains($0.id) && $0.playsSource && $0.assetID != nil }
        var fileAsset: UUID?
        if let one = picked.first, Set(picked.compactMap(\.assetID)).count == 1 {
            let ask = EditroomAlert()
            ask.messageText = "How is \(url.lastPathComponent) timed?"
            ask.informativeText = "From the start of this timeline (exported from Editroom), or from the start of \(project.name(of: one))'s own file?"
            ask.addButton(withTitle: "This Timeline")
            ask.addButton(withTitle: "The Clip's File")
            ask.addButton(withTitle: "Cancel")
            switch ask.runModal() {
            case .alertFirstButtonReturn: break
            case .alertSecondButtonReturn: fileAsset = one.assetID
            default: return
            }
        }
        var placed = 0, missed = 0
        mutate { p in
            if let asset = fileAsset {
                placed = p.importSubtitles(file: cues, asset: asset, name: name)
            } else {
                (placed, missed) = p.importSubtitles(timeline: cues, name: name)
            }
        }
        if placed == 0 {
            tell("Nothing to put them on", "None of the subtitles fell on a clip with sound. Put the class on the timeline first, then import its subtitles.")
        } else if missed > 0 {
            tell("Subtitles imported", "\(placed) of \(cues.count) subtitles are on the caption track as \"\(name)\". \(missed) fell where there's no clip with sound.")
        }
    }

    enum SubtitleFormat { case srt, text, textWithTimes }

    /// Subtitles › Export…: the captions as they show (what's heard, or the layer shown), as SRT or plain text,
    /// timed to the timeline: ready to translate, dub, or post beside the video.
    func exportSubtitles(_ format: SubtitleFormat) {
        guard project.captions != nil else {
            return tell("No captions yet", "Add captions first (Clip › Add Captions), so there's something to export.")
        }
        if captionsWaiting {
            let a = EditroomAlert()
            a.messageText = "Still listening"
            a.informativeText = "Some clips haven't been heard yet, so their words won't be in the file. Export anyway?"
            a.addButton(withTitle: "Export")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let panel = NSSavePanel()
        let ext = format == .srt ? "srt" : "txt"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        let layer = project.activeSubtitleLayer?.name
        panel.nameFieldStringValue = title + (layer.map { " - \($0)" } ?? "") + "." + ext
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let blocks = captionBlocks
        let text: String = switch format {
        case .srt: SRT.write(project.subtitleCues(blocks))
        case .text: project.subtitleText(blocks)
        case .textWithTimes: project.subtitleText(blocks, times: true)
        }
        do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
            tell("Couldn't save", error.localizedDescription)
        }
    }

    func showSubtitleLayer(_ id: UUID?) {
        mutate { $0.showSubtitleLayer(id) }
    }

    func removeSubtitleLayer(_ id: UUID) {
        mutate { $0.removeSubtitleLayer(id) }
    }

    /// Clip › Transcribe Again: the picked clips' files are heard afresh (after changing the language, or
    /// installing Whisper). With nothing picked, every file on the timeline.
    func transcribeAgain() {
        let picked = project.clips.filter { selection.isEmpty || project.linked(selection).contains($0.id) }
        let urls = Set(picked.compactMap { c in c.assetID.flatMap { media.soundURL($0) } })
        guard !urls.isEmpty else { return tell("Nothing to hear", "Pick clips with sound, or put some on the timeline.") }
        for u in urls { Transcripts.shared.redo(u) }
    }

    /// Subtitles › Import Dub…: a narration track (made from the translated subtitles) laid in from the start
    /// of the timeline on a new sound track, with the camera sound turned down while it speaks.
    func importDubFromPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Import"
        panel.message = "Choose the dub: a sound file timed to this timeline from its start."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importDub(url)
    }

    func importDub(_ url: URL, duckDB: Double = -24, then done: ((UUID?) -> Void)? = nil) {
        importFiles([url], offerMatch: false) { [weak self] assets in
            guard let self, let a = assets.first, a.hasAudio || a.kind == .audio else { done?(nil); return }
            var made: UUID?
            self.mutate { p in made = p.layDub(a, duckDB: duckDB) }
            done?(made)
        }
    }

    // MARK: Cameras

    /// Clip › Make Multi-Angle: the picked video clips are cameras of the same class. The one on the lowest track
    /// is the main camera (its sound plays throughout); the others are lined up to it by their sound and taken
    /// off the timeline, ready to switch to.
    func makeMultiAngle() {
        let picked = project.clips.filter { selection.contains($0.id) && $0.kind == .video && $0.playsSource }
        let order = { (c: Clip) in self.project.trackIndex(c.trackID, kind: .video) ?? 0 }
        guard let ref = picked.min(by: { (order($0), $0.start) < (order($1), $1.start) }), picked.count > 1,
              let refAsset = project.asset(ref.assetID) else {
            return tell("Pick the cameras", "Pick one video clip from each camera on the timeline (the main camera on the lowest track), then choose Make Multi-Angle again.")
        }
        let others = picked.filter { $0.id != ref.id && $0.assetID != ref.assetID }
        beginWaitingForFiles()
        Task {
            defer { self.endWaitingForFiles() }
            let refLevels = await ActivityScan.activity(refAsset.url, picture: false)?.levels ?? []
            var angles: [AngleGroup.Angle] = []
            var unsure: [String] = []
            for o in others {
                guard let a = self.project.asset(o.assetID) else { continue }
                let levels = await ActivityScan.activity(a.url, picture: false)?.levels ?? []
                // As they sit on the timeline, if their sound can't line them up.
                let t = max(ref.start, o.start)
                var offset = o.sourceTime(at: t) - ref.sourceTime(at: t)
                if let found = SoundSync.offset(reference: refLevels, other: levels, step: ActivityScan.levelStep, maxShift: 900),
                   found.clarity >= 1.3 {
                    offset = found.seconds
                } else {
                    unsure.append(a.name)
                }
                angles.append(AngleGroup.Angle(assetID: a.id, offset: offset, name: a.name))
            }
            var failure: String?
            let drop = self.project.linked(Set(others.map(\.id)))
            self.mutate { p in
                do {
                    try p.makeAngleGroup(reference: ref.id, angles: angles)
                    p.remove(ids: drop, ripple: false)
                } catch let e as AngleError { failure = e.message } catch { failure = error.localizedDescription }
            }
            self.selection = [ref.id]
            if let failure { return self.tell("Couldn't make multi-angle", failure) }
            var note = "Cameras: " + ([refAsset.name] + angles.map(\.name)).enumerated().map { "\($0.offset + 1) \($0.element)" }.joined(separator: ", ")
                + ".\n\nPlay the class and press ⌥1, ⌥2, ⌥3… to cut to a camera from the playhead on. Clip › Picture in Picture puts another camera small in a corner."
            if !unsure.isEmpty {
                note += "\n\nCouldn't line up \(unsure.joined(separator: ", ")) by sound, so they're synced as they were placed on the timeline."
            }
            self.tell("Multi-angle ready", note)
        }
    }

    /// The multi-angle group at the playhead (or of the picked clips).
    var activeAngleGroup: AngleGroup? {
        let at = project.clips.filter { $0.angleGroup != nil && ($0.start <= playhead && playhead < $0.end || selection.contains($0.id)) }
        return project.angleGroup(at.first?.angleGroup) ?? project.angleGroups?.first
    }

    /// ⌥1…⌥9: from the playhead on, the main track shows camera `j`.
    func switchAngle(to j: Int) {
        guard let g = activeAngleGroup, g.angles.indices.contains(j) else { return }
        var failure: String?
        let t = playhead
        mutate { p in
            do { try p.switchAngle(group: g.id, to: j, at: t) } catch let e as AngleError { failure = e.message } catch {}
        }
        if let failure { NSSound.beep(); NSLog("Switch camera: %@", failure) }
    }

    /// The picked multi-angle clips show camera `j` all through.
    func showAngle(_ j: Int) {
        let ids = project.clips.filter { selection.contains($0.id) && $0.angleGroup != nil }.map(\.id)
        var failure: String?
        mutate { p in
            for id in ids { do { try p.showAngle(j, clip: id) } catch let e as AngleError { failure = e.message } catch {} }
        }
        if let failure { tell("Couldn't change camera", failure) }
    }

    /// Camera `j` small in a corner over the picked multi-angle clips (or the one at the playhead).
    func addPictureInPicture(angle j: Int, corner: PictureCorner) {
        var ids = project.clips.filter { selection.contains($0.id) && $0.angleGroup != nil && $0.kind == .video }.map(\.id)
        if ids.isEmpty, let g = activeAngleGroup {
            ids = project.mainAngleClips(g.id).filter { $0.start <= playhead && playhead < $0.end }.map(\.id)
        }
        var failure: String?
        var made: [UUID] = []
        mutate { p in
            do { made = try p.addPictureInPicture(angle: j, over: ids, corner: corner) } catch let e as AngleError { failure = e.message } catch {}
        }
        if let failure { return tell("Couldn't add picture in picture", failure) }
        selection = Set(made)
    }

    // MARK: Pacing

    /// Every file under these clips, measured (sound, and pictures when `picture`), so pacing can be worked out.
    func activities(for clips: [Clip], picture: Bool) async -> [UUID: Activity] {
        var out: [UUID: Activity] = [:]
        for id in Set(clips.compactMap(\.assetID)) {
            guard let a = project.asset(id), a.kind != .image else { continue }
            if let act = await ActivityScan.activity(a.url, picture: picture && a.kind == .video) { out[id] = act }
        }
        return out
    }

    enum DeadAirAction { case cut, speed(Double) }

    /// Finds where nothing happens (in the in/out range, or the whole timeline) and cuts it out or speeds it up.
    func removeDeadAir(_ kind: DeadAirKind, minLength: Double, action: DeadAirAction, sensitivity: Double = 0.5,
                       then done: ((Int, Double) -> Void)? = nil) {
        let range = project.playRange
        beginWaitingForFiles()
        Task {
            defer { self.endWaitingForFiles() }
            let acts = await self.activities(for: self.project.clips, picture: kind != .quiet)
            let ranges = self.project.deadRanges(kind, activity: { acts[$0] }, minLength: minLength, sensitivity: sensitivity, range: range)
            let total = ranges.reduce(0) { $0 + $1.end - $1.start }
            if !ranges.isEmpty {
                self.mutate { p in
                    switch action {
                    case .cut: p.cut(ranges)
                    case .speed(let s): p.speedUp(ranges, by: s)
                    }
                }
            }
            if let done { return done(ranges.count, total) }
            if ranges.isEmpty {
                self.tell("Nothing to take out", "No stretch of \(Int(minLength)) seconds or more where \(kind.label.lowercased()).")
            } else {
                var verb = "Sped up"
                if case .cut = action { verb = "Cut" }
                self.tell("\(verb) \(ranges.count) stretch\(ranges.count == 1 ? "" : "es")", "\(Timecode.short(total)) in all. Undo puts it back.")
            }
        }
    }

    /// A timelapse: the in/out range (or from the playhead to the end) `factor` times faster. With
    /// `onlyQuiet`, only where nobody talks in it, so explanations still play at normal speed.
    func speedUp(by factor: Double, onlyQuiet: Bool, muteSound: Bool, minQuiet: Double = 3, then done: ((Int) -> Void)? = nil) {
        let r: (start: Double, end: Double) = project.playRange ?? (start: playhead, end: project.duration)
        guard r.end - r.start > 1 else { return tell("Nothing to speed up", "Set an in and out range (I and O), or put the playhead where the timelapse should start.") }
        guard onlyQuiet else {
            mutate { $0.speedUp(from: r.start, to: r.end, by: factor, muteSound: muteSound) }
            done?(1)
            return
        }
        beginWaitingForFiles()
        Task {
            defer { self.endWaitingForFiles() }
            let acts = await self.activities(for: self.project.clips, picture: false)
            let quiet = self.project.deadRanges(.quiet, activity: { acts[$0] }, minLength: minQuiet, pad: 0.3, range: r)
            if !quiet.isEmpty { self.mutate { $0.speedUp(quiet, by: factor, muteSound: muteSound) } }
            if let done { return done(quiet.count) }
            if quiet.isEmpty { self.tell("No quiet stretches", "Someone talks all through that part, so nothing was sped up.") }
        }
    }

    // MARK: Dialogs

    /// Class › Remove Dead Air…: what counts, how long, and what to do with it.
    func removeDeadAirDialog() {
        let a = EditroomAlert()
        a.messageText = "Remove dead air"
        a.informativeText = project.playRange != nil ? "In the in/out range." : "Over the whole timeline. Set an in/out range (I and O) to work on just part of it."
        let kind = NSPopUpButton(), length = NSPopUpButton(), action = NSPopUpButton()
        kind.addItems(withTitles: DeadAirKind.allCases.map(\.label))
        length.addItems(withTitles: ["2 seconds or longer", "3 seconds or longer", "5 seconds or longer", "10 seconds or longer", "30 seconds or longer"])
        length.selectItem(at: 2)
        action.addItems(withTitles: ["Cut it out", "Speed it up 4×", "Speed it up 8×", "Speed it up 16×"])
        let stack = NSStackView(views: [kind, length, action])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 90)
        a.accessoryView = stack
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let k = DeadAirKind.allCases[kind.indexOfSelectedItem]
        let len = [2.0, 3, 5, 10, 30][length.indexOfSelectedItem]
        let actions: [DeadAirAction] = [.cut, .speed(4), .speed(8), .speed(16)]
        let act = actions[action.indexOfSelectedItem]
        removeDeadAir(k, minLength: len, action: act)
    }

    /// Class › Speed Up…: a timelapse of the in/out range, or from the playhead to the end.
    func speedUpDialog() {
        let a = EditroomAlert()
        a.messageText = "Speed up"
        a.informativeText = project.playRange != nil ? "The in/out range." : "From the playhead (\(Timecode.simple(playhead))) to the end."
        let speed = NSPopUpButton()
        speed.addItems(withTitles: ["2× faster", "4× faster", "8× faster", "16× faster", "32× faster"])
        speed.selectItem(at: 2)
        let quiet = NSButton(checkboxWithTitle: "Only where nobody's talking", target: nil, action: nil)
        quiet.state = .on
        let mute = NSButton(checkboxWithTitle: "Turn the sped-up sound off", target: nil, action: nil)
        mute.state = .on
        let stack = NSStackView(views: [speed, quiet, mute])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 280, height: 80)
        a.accessoryView = stack
        a.addButton(withTitle: "Speed Up")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        speedUp(by: [2.0, 4, 8, 16, 32][speed.indexOfSelectedItem], onlyQuiet: quiet.state == .on, muteSound: mute.state == .on)
    }
}

extension Project {
    /// A dub on a new sound track from the start, and every other track with camera sound turned down under it.
    @discardableResult
    mutating func layDub(_ asset: MediaAsset, duckDB: Double) -> UUID {
        if !assets.contains(where: { $0.id == asset.id }) { assets.append(asset) }
        let track = addTrack(.audio)
        let clip = Clip(trackID: track, kind: .audio, assetID: asset.id, start: 0, duration: asset.duration)
        clips.append(clip)
        let cameraTracks = Set(clips.filter { c in c.kind == .audio && self.asset(c.assetID)?.kind == .video }.map(\.trackID))
        for i in audioTracks.indices where audioTracks[i].id != track && cameraTracks.contains(audioTracks[i].id) {
            audioTracks[i].duckUnder = track
            audioTracks[i].duckDB = duckDB
        }
        return clip.id
    }
}
