import AppKit
import Foundation

struct MCPToolError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// The tools agents get. Reading is instant; every change to the cut is played by the agent's own
/// cursor (dragging from the library, trimming edges, working the grade panel) and is one undo step.
@MainActor
enum MCPTools {
    static let instructions = """
    Editroom is a video editor. Times are in seconds. Video tracks are V1, V2, … (V1 is the bottom; \
    higher tracks cover lower ones) and audio tracks are A1, A2, …. A video with sound is placed as a \
    linked pair: moving, trimming or deleting either moves both. Placing, moving or trimming a clip, \
    title or solid over another on the same track overwrites what's underneath, as on the timeline. Start with \
    get_project and list_media; analyze_media finds a clip's best moments or a song's beats; \
    look_at_media shows you a clip or photo, and get_frame shows you the cut; search_media finds shots by what they \
    show or what's said. After looking at a clip, save what you saw with note_media; list_media gives those notes \
    back next time, so trust a clip's notes and look again only for an exact frame. Each edit is shown to the person with your own cursor and can be undone with history. \
    auto_edit builds a whole cut on its own, and export delivers it to a file (vertical, square or portrait too, at a \
    loudness target).
    """

    static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    // MARK: Definitions

    private static func tool(_ name: String, _ title: String, _ description: String, _ props: [String: Any] = [:],
                             required: [String] = [], readOnly: Bool = false) -> [String: Any] {
        [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": ["type": "object", "properties": props, "required": required] as [String: Any],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false],
        ]
    }
    private static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    private static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }

    static var definitions: [[String: Any]] {
        [
            tool("get_project", "Get project", "The sequence (size, frame rate, length), tracks, and every clip with its id, track, times, source, grade, sound and transition.", readOnly: true),
            tool("list_media", "List media", "Everything in the library: id, name, kind (video, audio, image), the folder it's in, length, size, frame rate, what it shows, whether people talk in it, and notes saved from looking at it before.", readOnly: true),
            tool("import_media", "Import media", "Adds files to the library. A folder brings in everything in it (and in folders inside it) and stays linked: files added to it later come in too, and list_media gives each item's folder.", ["paths": ["type": "array", "items": ["type": "string"], "description": "Absolute paths of files or folders."]], required: ["paths"]),
            tool("download_media", "Download media", "Downloads one music or sound file you found online and adds it to the library, ready for add_clip. Give the direct link to the audio file (an .mp3, .m4a or .wav), not a web page. Only for music that's free to use; say where you found it and what its licence allows, which is noted beside the file.",
                 ["url": str("https link to the audio file itself."), "name": str("What to call it, like the track and artist."),
                  "source_page": str("The page you found it on."), "licence": str("What the licence says, for example \"Pixabay Content License: free to use, no attribution required\".")],
                 required: ["url", "source_page", "licence"]),
            tool("analyze_media", "Analyze media", "For a video or photo: its best moments, scored for focus, exposure, colour, faces and steadiness. For music: tempo, beats and where bars start. Done on this Mac; cached.",
                 ["asset_id": str("A library item's id."), "moment_length": num("Length of moments to look for, in seconds (default 2).")], required: ["asset_id"], readOnly: true),
            tool("get_transcript", "Get transcript", "What's said in a video or sound file, heard on this Mac: its sentences and pauses with their times in the file (and each word's time if you ask). Use it for anything with people talking: to cut pauses, retakes and filler, keep sentences whole, find a moment by what's said, or put pictures over the talking. Made in the background after import; cached.",
                 ["asset_id": str("A library item's id."), "words": ["type": "boolean", "description": "Also every word with its start and end (default false)."]], required: ["asset_id"], readOnly: true),
            tool("look_at_media", "Look at media", "Shows you a library item: a photo, or frames from across a video in a grid, each marked with its time in the file. Use it to see what's in each shot before choosing.",
                 ["asset_id": str("A library item's id."), "frames": ["type": "integer", "description": "How many frames from across a video (default 6, at most 12)."],
                  "times": ["type": "array", "items": ["type": "number"], "description": "Or exactly which times in the file to show, in seconds (at most 12)."]],
                 required: ["asset_id"], readOnly: true),
            tool("note_media", "Note what's in media", "Saves what you saw in a library item after looking at it, for later edits: what happens and where (times in the file), the people, the place, the light, how steady, and its best and weakest moments. Two or three short lines. list_media hands it back as \"notes\", so it needn't be looked at again. Replaces any note it had; kept on this Mac, never in the project.",
                 ["asset_id": str("A library item's id."), "notes": str("What's in it, with times, like \"0-3s girl in a high chair eating noodles; 3-8s close-up, laughing at the camera, best moment 5s; bright kitchen, handheld but steady.\"")],
                 required: ["asset_id", "notes"]),
            tool("get_frame", "Get frame", "A picture of the cut at a time (default: the playhead), 640 pixels on its longer side.", ["time": num("Seconds.")], readOnly: true),
            tool("add_clip", "Add clip", "Drags a library item onto the timeline. A video with sound brings its audio, linked.",
                 ["asset_id": str("A library item's id."), "start": num("Where on the timeline (default: the end of the track)."),
                  "track": str("V1, V2… for video and photos; A1, A2… for audio (default V1 or A1)."),
                  "source_start": num("Where in the file to start (default 0)."), "duration": num("How long (default: the rest of the file; 5 for a photo).")],
                 required: ["asset_id"]),
            tool("add_title", "Add title", "Adds a text title, typed in.", ["text": str("The words."), "start": num("Default 0."), "duration": num("Default 3."), "track": str("A video track (default: one that's free there, above V1).")], required: ["text"]),
            tool("move_clip", "Move clip", "Moves a clip (and anything linked to it) in time, and optionally to another track of the same kind.", ["clip_id": str("A clip's id."), "start": num("New start."), "track": str("Optional new track.")], required: ["clip_id", "start"]),
            tool("trim_clip", "Trim clip", "Moves a clip's start and/or end edge on the timeline (and its linked clip's). The source moves with the start edge.", ["clip_id": str("A clip's id."), "start": num("New start edge."), "end": num("New end edge.")], required: ["clip_id"]),
            tool("set_speed", "Set speed", "Speeds a clip (and its linked sound) up or slows it down, keeping the same part of the file: 4 plays four times as fast and a quarter as long (a timelapse), 0.5 is slow motion. Clips after it on the track move to stay butted up.",
                 ["clip_id": str("A clip's id."), "speed": num("0.05...100; 1 is normal.")], required: ["clip_id", "speed"]),
            tool("set_speed_ramp", "Set speed ramp", "A speed ramp on a clip (and its linked sound): it plays at `around` speed, eases into `speed` for the part of the file from `from` to `to`, then eases back. For a slow-motion moment (speed 0.25, around 1), fast-normal-fast B-roll (speed 1, around 4), or ramping into a cut (`to` left out, `speed` 4: it eases up toward the clip's end). Times are seconds in the file, like source_start. The clip's length changes; clips after it on the track move to stay butted up. remove: true takes a clip's ramp away.",
                 ["clip_id": str("A clip's id."), "speed": num("The speed from `from` to `to`, 0.05...100 (1 is normal)."),
                  "from": num("Seconds in the file where it reaches `speed` (default: the clip's start, so no ease in)."),
                  "to": num("Seconds in the file where it starts easing back (default: the clip's end, so no ease out)."),
                  "ease": num("Seconds of the file each ease takes (default 0.4)."),
                  "around": num("The speed before and after (default 1)."),
                  "remove": ["type": "boolean", "description": "Take the clip's ramp away (its speed stays)."]],
                 required: ["clip_id"]),
            tool("set_captions", "Set captions", "Captions from what's said: a caption track above the video shows the words of each captioned clip in short phrases, timed to the speech, and follows every trim and move of those clips. Give clip_ids to caption those clips' speech (a video's sound is its linked audio clip); with none, every clip of people talking is captioned (sound from video files and voiceover tracks, not music). Also sets the captions' style, and with edit fixes captions: a misheard word, a name spelled right, or a caption taken out. remove: true takes captions off clip_ids, or removes the caption track with none. Returns the captions.",
                 ["clip_ids": ["type": "array", "items": ["type": "string"], "description": "Clips whose speech to caption (or un-caption with remove)."],
                  "remove": ["type": "boolean", "description": "Take captions off instead."],
                  "size": num("Text size, 28...140 (default 64)."),
                  "position": num("Where they sit, 0.1 (top) to 0.95 (bottom) of the frame (default 0.78)."),
                  "highlight": ["type": "boolean", "description": "Light up each word as it's said (default true)."],
                  "hidden": ["type": "boolean", "description": "Hide or show the caption track (hidden captions aren't exported)."],
                  "edit": ["type": "array", "description": "Captions to change, each found by a timeline time inside it (as set_captions or get_project return them): the words it should say, or \"\" to take it out. The caption keeps its time.",
                           "items": ["type": "object", "properties": ["at": ["type": "number", "description": "Timeline seconds inside the caption."],
                                                                     "text": ["type": "string", "description": "What it should say."]],
                                     "required": ["at", "text"]]]]),
            tool("split_clip", "Split clip", "Cuts a clip (and its linked clip) in two with the blade. Returns the new right-hand pieces.", ["clip_id": str("A clip's id."), "at": num("Timeline time inside the clip.")], required: ["clip_id", "at"]),
            tool("delete_clips", "Delete clips", "Deletes clips and anything linked to them.", ["clip_ids": ["type": "array", "items": ["type": "string"]], "ripple": ["type": "boolean", "description": "Close the gap left behind (default false)."]], required: ["clip_ids"]),
            tool("set_grade", "Set grade", "Colour for video, photo and title clips. Leave out what shouldn't change.",
                 ["clip_ids": ["type": "array", "items": ["type": "string"]], "look": str("A look from list_looks, a .cube file path, or \"none\"."),
                  "look_intensity": num("0...1."), "exposure": num("Stops, -2...2."), "contrast": num("-50...50."), "saturation": num("-100...100."),
                  "temperature": num("-50...50, negative is cooler."), "tint": num("-50...50, positive is toward magenta.")], required: ["clip_ids"]),
            tool("list_looks", "List looks", "The built-in looks for set_grade.", readOnly: true),
            tool("set_audio", "Set level and fades", "A clip's sound level, and its fades: a sound clip's fade its sound, a video, photo, title or solid's fade its picture (in from black, out to black).", ["clip_id": str("A clip's id."), "gain_db": num("Sound level in dB, -60...12."), "fade_in": num("Seconds."), "fade_out": num("Seconds.")], required: ["clip_id"]),
            tool("set_transition", "Set transition", "A transition into a clip from the clip that ends where it starts on the same track.", ["clip_id": str("The later clip's id."), "kind": ["type": "string", "enum": ["dissolve", "dipToBlack", "wipe", "none"]], "duration": num("Seconds (default 0.5).")], required: ["clip_id", "kind"]),
            tool("add_track", "Add track", "Adds an empty track on top of the others of its kind.", ["kind": ["type": "string", "enum": ["video", "audio"]]], required: ["kind"]),
            tool("set_sequence", "Set sequence", "The frame size and frame rate of the cut.", ["width": ["type": "integer"], "height": ["type": "integer"], "fps": num("23.976, 24, 25, 29.97, 30, 50, 59.94, 60, 100, 119.88 or 120.")]),
            tool("playback", "Playback", "Play, pause or move the playhead.", ["action": ["type": "string", "enum": ["play", "pause", "seek"]], "time": num("For seek.")], required: ["action"]),
            tool("history", "Undo or redo", "Undoes or redoes the last change (each tool call is one change).", ["action": ["type": "string", "enum": ["undo", "redo"]]], required: ["action"]),
            tool("auto_edit", "Auto edit", "Builds a whole cut from the library on its own: best moments, cut to the beat of a song if there is one, titled. Replaces what's on the timeline (one undo brings it back)."),
            tool("save_project", "Save project", "Saves the project to its file. A project that's never been saved has to be saved by the person."),
        ] + moreDefinitions
    }

    // MARK: Calls

    static func call(_ name: String, _ args: [String: Any], model: EditorModel, client: MCPServer.Client?,
                     draft: MCPDraft? = nil) async throws -> [[String: Any]] {
        let who = client?.name ?? "Agent"
        draft?.called(name)
        /// The project as it is now: the Magic draft's while there is one.
        func now() -> Project { draft?.project ?? model.project }
        func notInMagic() throws {
            if draft != nil { throw MCPToolError("\(name) isn't available while making a Magic edit.") }
        }
        func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }
        func json(_ v: Any) -> [[String: Any]] {
            let d = (try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return text(String(data: d, encoding: .utf8) ?? "{}")
        }
        let p = now()

        switch name {
        case "get_project":
            return json(projectJSON(p, title: model.title, playhead: draft?.playhead ?? model.playhead))

        case "list_media":
            // Labels most of the library shares ("structure", "people" in a vlog) don't tell clips apart: left out.
            let tagged = p.assets.compactMap { model.media.sceneTags($0.id) }
            var counts: [String: Int] = [:]
            for t in tagged { for name in Set(t.tags.map(\.name)) { counts[name, default: 0] += 1 } }
            let common = tagged.count >= 4 ? Set(counts.filter { Double($0.value) >= Double(tagged.count) * 0.6 }.keys) : []
            let tree = MediaTree(p)
            return json(p.assets.map { a in
                var d = assetJSON(a, media: model.media, common: common)
                // The folder it's in, for media brought in as a folder ("B-roll / Drone").
                if let at = tree.folder(of: a) { d["folder"] = tree.label(at) }
                return d
            })

        case "list_looks":
            return json(BuiltInLook.all.map(\.name))

        case "import_media":
            // In a Magic run only when Settings lets Claude use files on this Mac (and then the run has no web).
            if !MagicAgent.filesAllowed { try notInMagic() }
            let paths = args["paths"] as? [String] ?? []
            let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            let missing = urls.filter { !FileManager.default.fileExists(atPath: $0.path) }
            guard missing.isEmpty else { throw MCPToolError("No file at " + missing.map(\.path).joined(separator: ", ")) }
            let assets: [MediaAsset] = await withCheckedContinuation { cont in
                model.importFiles(urls, offerMatch: false) { cont.resume(returning: $0) }
            }
            for a in assets { draft?.addAsset(a) }
            return json(["imported": assets.map(assetJSON), "failed": urls.count - assets.count])

        case "download_media":
            guard let link = args["url"] as? String, let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else {
                throw MCPToolError("url is needed: the https link to the audio file.")
            }
            let folder = MediaDownload.folder(for: model.fileURL)
            let file: URL
            do {
                file = try await MediaDownload.fetch(url, name: args["name"] as? String, sourcePage: args["source_page"] as? String,
                                                     licence: args["licence"] as? String, into: folder)
            } catch let e as MediaDownload.Failure {
                throw MCPToolError(e.message)
            }
            let assets: [MediaAsset] = await withCheckedContinuation { cont in
                model.importFiles([file], offerMatch: false) { cont.resume(returning: $0) }
            }
            guard let asset = assets.first else { throw MCPToolError("Downloaded it, but couldn't add it to the library.") }
            draft?.addAsset(asset)
            var out = assetJSON(asset)
            out["saved_to"] = file.path
            return json(["added": out, "note": "In the library now; add it with add_clip."])

        case "analyze_media":
            let asset = try assetArg(args, p)
            if asset.kind == .audio {
                guard let m = await MediaAnalyzer.music(asset.url) else { throw MCPToolError("Couldn't read the sound in \(asset.name).") }
                let bars = m.beats.indices.filter(m.isBarStart).map { round3(m.beats[$0]) }
                return json(["bpm": round3(m.bpm), "beat_length": round3(m.period), "beat_count": m.beats.count,
                             "first_beat": round3(m.beats.first ?? 0), "bar_starts": Array(bars.prefix(80))])
            }
            guard let a = await MediaAnalyzer.clip(asset.url, kind: asset.kind) else { throw MCPToolError("Couldn't look at \(asset.name).") }
            let length = (args["moment_length"] as? Double) ?? 2
            let score = AutoPlanner.scorer(a.samples)
            let moments = AutoPlanner.moments(a, limit: asset.duration, length: length, score: score)
            let mean = a.samples.map(\.luma).reduce(0, +) / Double(max(1, a.samples.count))
            var out: [String: Any] = [
                "duration": round3(min(a.duration, asset.duration)),
                "best_moments": moments.map { ["start": round3($0.start), "end": round3($0.end), "score": round3($0.score), "faces": $0.faces] },
                "average_brightness": round3(mean),
                "has_faces": a.samples.contains { $0.faces > 0 },
            ]
            if let created = a.created { out["filmed"] = ISO8601DateFormatter().string(from: created) }
            if a.samples.contains(where: { $0.utility == true }) { out["looks_like_a_screenshot_or_document"] = true }
            return json(out)

        case "get_transcript":
            let asset = try assetArg(args, p)
            guard asset.kind != .image, let url = model.media.soundURL(asset.id) else {
                return json(["asset_id": asset.id.uuidString, "status": "no_sound", "note": "\(asset.name) has no sound."])
            }
            guard Transcripts.available else {
                return json(["asset_id": asset.id.uuidString, "status": "unavailable", "note": "Hearing speech needs macOS 26 on this Mac."])
            }
            guard let t = await Transcripts.shared.ready(url) else {
                return json(["asset_id": asset.id.uuidString, "status": "failed", "note": "Couldn't hear what's said in \(asset.name)."])
            }
            return json(transcriptJSON(t, asset: asset, words: args["words"] as? Bool ?? false))

        case "look_at_media":
            let asset = try assetArg(args, p)
            guard asset.kind != .audio else { throw MCPToolError("\(asset.name) is sound only; analyze_media finds its beats.") }
            let frames = (args["frames"] as? Int) ?? 6
            let times = (args["times"] as? [Any])?.compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) }
            guard let sheet = await ContactSheet.make(asset, frames: frames, around: times) else { throw MCPToolError("Couldn't look at \(asset.name).") }
            let note = asset.kind == .image ? "\(asset.name), a photo." :
                "\(asset.name), \(round3(asset.duration))s long. Frames at " + sheet.times.map { String(format: "%.1fs", $0) }.joined(separator: ", ") + ", left to right, top to bottom."
            let saved = MediaNotes.note(for: asset.path).map { " Its saved notes: \($0.text) Update them with note_media if you see more." }
                ?? " Save what you see with note_media."
            return [["type": "image", "data": sheet.jpeg.base64EncodedString(), "mimeType": "image/jpeg"], ["type": "text", "text": note + saved]]

        case "note_media":
            let asset = try assetArg(args, p)
            guard let text = (args["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw MCPToolError("Give notes: what's in it, with times.")
            }
            MediaNotes.save(text, for: asset.path, by: client?.name)
            return [["type": "text", "text": "Saved. list_media will show it with \(asset.name)."]]

        case "get_frame":
            guard !p.clips.isEmpty else { throw MCPToolError("The timeline is empty.") }
            let t = (args["time"] as? Double) ?? draft?.playhead ?? model.playhead
            guard let img = await model.snapshot(of: p, at: t), let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                throw MCPToolError("Couldn't render a frame at \(t)s.")
            }
            return [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"],
                    ["type": "text", "text": "Frame at \(round3(t))s."]]

        case "add_clip":
            let asset = try assetArg(args, p)
            let audioOnly = asset.kind == .audio
            let track = try trackArg(args["track"] as? String ?? (audioOnly ? "A1" : "V1"), p, kind: audioOnly ? .audio : .video)
            let start = max(0, (args["start"] as? Double) ?? (p.clips.filter { $0.trackID == track }.map(\.end).max() ?? 0))
            let source = max(0, (args["source_start"] as? Double) ?? 0)
            guard asset.kind == .image || source < asset.duration - 0.05 else { throw MCPToolError("source_start is past the end of \(asset.name) (\(round3(asset.duration))s).") }
            let rest = asset.kind == .image ? 5 : asset.duration - source
            let length = max(1 / p.fps, min((args["duration"] as? Double) ?? rest, asset.kind == .image ? 3600 : rest))
            let audioTrack = audioOnly ? track : (p.freeTrack(.audio, start: start, duration: length) ?? p.audioTracks.first?.id ?? TrackToken.newAudio)
            var clips = model.makeClips(.asset(asset.id), at: p.snapFrame(start), videoTrack: audioOnly ? (p.videoTracks.first?.id ?? track) : track,
                                        audioTrack: audioTrack)
            for i in clips.indices {
                clips[i].sourceStart = asset.kind == .image ? 0 : source
                clips[i].duration = p.snapFrame(length)
            }
            guard !clips.isEmpty else { throw MCPToolError("Couldn't make a clip from \(asset.name).") }
            try await perform([.place(clips, asset: asset.id)], model, who, draft)
            return json(["added": clips.map { ["id": $0.id.uuidString, "track": trackName($0.trackID, now()), "start": round3($0.start), "end": round3($0.end)] }])

        case "add_title":
            let words = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { throw MCPToolError("The title needs some text.") }
            let start = max(0, (args["start"] as? Double) ?? 0)
            let length = max(0.2, (args["duration"] as? Double) ?? 3)
            let track: UUID
            var edits: [MagicEdit] = []
            if let name = args["track"] as? String {
                track = try trackArg(name, p, kind: .video)
            } else {
                // Above the picture: the first video track (not V1) that's free there.
                let free = p.videoTracks.dropFirst().first { t in !p.clips.contains { $0.trackID == t.id && $0.start < start + length && $0.end > start } }
                if let t = free?.id {
                    track = t
                } else if draft != nil {
                    // None free: a new one on top, in the same step as the title.
                    track = UUID()
                    edits.append(addTrackEdit(.video, id: track))
                } else {
                    model.addTrack(.video)
                    track = model.project.videoTracks.last!.id
                }
            }
            var clip = Clip(trackID: track, kind: .text, start: p.snapFrame(start), duration: p.snapFrame(length))
            clip.text.string = ""
            edits += [.place([clip], asset: nil), .type(clip.id, words)]
            try await perform(edits, model, who, draft)
            return json(["added": ["id": clip.id.uuidString, "track": trackName(track, now()), "start": round3(clip.start), "end": round3(clip.end)]])

        case "move_clip":
            let c = try clipArg(args, p)
            let start = max(0, try numArg(args, "start"))
            var tracks: [UUID: UUID] = [:]
            if let name = args["track"] as? String {
                tracks[c.id] = try trackArg(name, p, kind: c.kind.trackKind)
            }
            let ids = Array(p.unlocked(p.linked([c.id])))
            try await perform([.move(ids, from: c.start, to: p.snapFrame(start), tracks: tracks)], model, who, draft)
            return json(clipsJSON(ids, now()))

        case "trim_clip":
            let c = try clipArg(args, p)
            let ids = Array(p.unlocked(p.linked([c.id])))
            var edits: [MagicEdit] = []
            var newStart = c.start, newEnd = c.end
            if let s = args["start"] as? Double {
                // Not before the start of the file.
                let earliest = c.playsSource ? c.start - c.timelineSpan(from: 0, to: c.sourceStart) : 0
                newStart = p.snapFrame(max(max(0, earliest), s))
            }
            if let e = args["end"] as? Double {
                var latest = Double.infinity
                if c.playsSource, let limit = p.sourceLimit(c) { latest = c.start + c.timelineSpan(from: c.sourceStart, to: limit) }
                newEnd = p.snapFrame(min(latest, e))
            }
            guard newEnd - newStart >= 1 / p.fps else { throw MCPToolError("That would leave the clip with no length.") }
            if newStart != c.start { edits.append(.trimHead(ids, from: c.start, to: newStart)) }
            if newEnd != c.end { edits.append(.trimTail(ids, from: c.end, to: newEnd)) }
            guard !edits.isEmpty else { return json(clipsJSON(ids, p)) }
            try await perform(edits, model, who, draft)
            return json(clipsJSON(ids, now()))

        case "set_speed":
            let c = try clipArg(args, p)
            guard c.playsSource else { throw MCPToolError("Only video and sound clips have a speed.") }
            let speed = try numArg(args, "speed").clamped(to: 0.05...100)
            let ids = p.unlocked(p.linked([c.id]))
            let label = speed >= 1 ? String(format: "Speed ×%g", speed) : String(format: "Slow ×%g", speed)
            try await perform([.change(c.id, label) { proj in proj.setSpeed(ids: ids, speed: speed) }], model, who, draft)
            return json(clipsJSON(Array(ids), now()))

        case "set_captions":
            func number(_ k: String) -> Double? { (args[k] as? Double) ?? (args[k] as? Int).map(Double.init) }
            let given = Set((args["clip_ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:)))
            if !(args["clip_ids"] as? [String] ?? []).isEmpty, given.isEmpty { throw MCPToolError("clip_ids aren't clip ids from get_project.") }
            if args["remove"] as? Bool == true {
                let targets = p.captionTargets(given)
                try await perform([.change(targets.first, given.isEmpty ? "No captions" : "Remove captions") { proj in
                    if given.isEmpty { proj.removeCaptionTrack() } else { proj.removeCaptions(targets) }
                }], model, who, draft)
                return json(["captions": captionsJSON(draft?.project ?? model.project, model)])
            }
            guard Transcripts.available else { throw MCPToolError("Captions need speech recognition, which needs macOS 26 on this Mac.") }
            let targets = p.unlocked(given.isEmpty ? (p.captions == nil ? p.defaultCaptionTargets : []) : p.captionTargets(given))
            if !given.isEmpty, targets.isEmpty { throw MCPToolError("Those clips have no sound to caption.") }
            if p.captions == nil, targets.isEmpty { throw MCPToolError("There's no one talking to caption: give clip_ids of clips with speech.") }
            if args["edit"] != nil, p.captions == nil, targets.isEmpty { throw MCPToolError("There are no captions to edit.") }
            // What's said in them, heard first, so the captions are there when this returns.
            for c in p.clips where targets.contains(c.id) {
                if let id = c.assetID, let url = model.media.soundURL(id) { _ = await Transcripts.shared.ready(url) }
            }
            // Captions to fix, found on the captions as they'll be once these clips are captioned.
            var after = p
            after.addCaptions(targets)
            let shown = CaptionLayout.blocks(after) { model.media.transcript($0.id) }
            var fixes: [(CaptionBlock, String)] = []
            for e in args["edit"] as? [[String: Any]] ?? [] {
                guard let at = (e["at"] as? Double) ?? (e["at"] as? Int).map(Double.init), let text = e["text"] as? String else {
                    throw MCPToolError("Each edit needs at (timeline seconds) and text.")
                }
                let near = shown.first { at >= $0.start && at < $0.end }
                    ?? shown.min { abs(($0.start + $0.end) / 2 - at) < abs(($1.start + $1.end) / 2 - at) }.flatMap { b in
                        at >= b.start - 0.5 && at < b.end + 0.5 ? b : nil
                    }
                guard let b = near else { throw MCPToolError("No caption at \(String(format: "%.2f", at))s.") }
                fixes.append((b, text))
            }
            let size = number("size").map { $0.clamped(to: CaptionStyle.sizeRange) }
            let position = number("position").map { $0.clamped(to: 0.1...0.95) }
            let highlight = args["highlight"] as? Bool, hidden = args["hidden"] as? Bool
            try await perform([.change(targets.first, "Captions") { proj in
                proj.addCaptions(targets)
                if let size { proj.captions?.style.size = size }
                if let position { proj.captions?.style.y = position }
                if let highlight { proj.captions?.style.highlight = highlight }
                if let hidden { proj.captions?.hidden = hidden }
                for (b, text) in fixes { proj.setCaptionText(b, to: text) }
            }], model, who, draft)
            return json(["captions": captionsJSON(draft?.project ?? model.project, model)])

        case "set_speed_ramp":
            let c = try clipArg(args, p)
            guard c.playsSource else { throw MCPToolError("Only video and sound clips have a speed.") }
            let ids = p.unlocked(p.linked([c.id]))
            func number(_ k: String) -> Double? { (args[k] as? Double) ?? (args[k] as? Int).map(Double.init) }
            if args["remove"] as? Bool == true {
                try await perform([.change(c.id, "No ramp") { proj in proj.retime(ids: ids) { $0.ramp = nil } }], model, who, draft)
                return json(clipsJSON(Array(ids), now()))
            }
            guard let speed = number("speed")?.clamped(to: 0.05...100) else { throw MCPToolError("speed is needed (or remove: true).") }
            let s0 = c.sourceStart, L = max(1e-6, c.sourceLength), s1 = s0 + L
            let ease = max(0.04, number("ease") ?? 0.4)
            let around = (number("around") ?? 1).clamped(to: 0.05...100)
            let from = number("from").map { min(max($0, s0), s1) }
            let to = number("to").map { min(max($0, from ?? s0), s1) }
            guard from != nil || to != nil else { throw MCPToolError("Give from and/or to (seconds in the file); for one speed throughout, use set_speed.") }
            let f = { (s: Double) in min(1, max(0, (s - s0) / L)) }
            var points = (0.0, 0.0, 1.0, 1.0)
            if let from, from > s0 + 1e-3 { points.0 = f(from - ease); points.1 = f(from) }
            if let to, to < s1 - 1e-3 { points.2 = f(to); points.3 = f(to + ease) }
            if points.1 - points.0 < 0.001, points.3 - points.2 < 0.001 { throw MCPToolError("That ramp would sit outside the clip: from and to should be inside its part of the file (\(String(format: "%.2f", s0))–\(String(format: "%.2f", s1))s).") }
            let label = speed < around ? "Slow-mo ramp" : "Speed ramp"
            try await perform([.change(c.id, label) { proj in
                proj.setRamp(ids: ids, speed: speed, points: points, start: around, end: around)
            }], model, who, draft)
            return json(clipsJSON(Array(ids), now()))

        case "split_clip":
            let c = try clipArg(args, p)
            let at = p.snapFrame(try numArg(args, "at"))
            guard at > c.start + 0.5 / p.fps, at < c.end - 0.5 / p.fps else { throw MCPToolError("\(round3(at))s isn't inside the clip (\(round3(c.start))–\(round3(c.end))).") }
            let ids = Array(p.unlocked(p.linked([c.id])))
            var pieces: [UUID: UUID] = [:]
            for id in ids { pieces[id] = UUID() }
            try await perform([.blade(ids, at: at, pieces: pieces, link: UUID())], model, who, draft)
            return json(["left": clipsJSON(ids, now()), "right": clipsJSON(ids.compactMap { pieces[$0] }, now())])

        case "delete_clips":
            let raw = args["clip_ids"] as? [String] ?? []
            let ids = try raw.map { s -> UUID in
                guard let id = UUID(uuidString: s), p.clip(id) != nil else { throw MCPToolError("No clip with id \(s).") }
                return id
            }
            let all = Array(p.unlocked(p.linked(Set(ids))))
            guard !all.isEmpty else { throw MCPToolError("Nothing to delete (locked tracks?).") }
            try await perform([.remove(all, ripple: args["ripple"] as? Bool ?? false)], model, who, draft)
            return text("Deleted \(all.count) clip\(all.count == 1 ? "" : "s").")

        case "set_grade":
            let raw = args["clip_ids"] as? [String] ?? (args["clip_id"] as? String).map { [$0] } ?? []
            var edits: [MagicEdit] = []
            for s in raw {
                guard let id = UUID(uuidString: s), let c = p.clip(id) else { throw MCPToolError("No clip with id \(s).") }
                guard c.kind != .audio else { throw MCPToolError("\(p.name(of: c)) is sound; it has no colour.") }
                if let look = args["look"] as? String {
                    if look.lowercased() == "none" {
                        edits.append(.change(id, "No look") { proj in
                            if let i = proj.index(of: id) { var g = proj.clips[i].grade ?? ColorGrade(); g.look = nil; proj.clips[i].grade = g.isNeutral ? nil : g }
                        })
                    } else {
                        let path = (look as NSString).expandingTildeInPath
                        guard BuiltInLook.named(look) != nil || (path.hasSuffix(".cube") && GradeBaker.cubeFile(path) != nil) else {
                            throw MCPToolError("No look called \(look). list_looks has the built-in ones.")
                        }
                        edits.append(.look(id, name: BuiltInLook.named(look) != nil ? look : path))
                    }
                }
                for key in MagicGradeKey.allCases {
                    let field = key == .exposure ? "exposure" : key == .contrast ? "contrast" : "saturation"
                    if let v = args[field] as? Double { edits.append(.grade(id, key, to: v.clamped(to: key.range))) }
                }
                let intensity = args["look_intensity"] as? Double, temp = args["temperature"] as? Double, tint = args["tint"] as? Double
                if intensity != nil || temp != nil || tint != nil {
                    edits.append(.change(id, "Colour") { proj in
                        guard let i = proj.index(of: id) else { return }
                        var g = proj.clips[i].grade ?? ColorGrade()
                        if let intensity { g.lookIntensity = intensity.clamped(to: 0...1) }
                        if let temp { g.temperature = temp.clamped(to: -50...50) }
                        if let tint { g.tint = tint.clamped(to: -50...50) }
                        proj.clips[i].grade = g
                    })
                }
            }
            guard !edits.isEmpty else { throw MCPToolError("Nothing to change: give clip_ids and at least one setting.") }
            try await perform(edits, model, who, draft)
            return json(clipsJSON(raw.compactMap(UUID.init(uuidString:)), now()))

        case "set_audio":
            let c = try clipArg(args, p)
            var edits: [MagicEdit] = []
            if let g = args["gain_db"] as? Double { edits.append(.gain(c.id, from: c.gainDB, to: g.clamped(to: -60...12))) }
            if let f = args["fade_in"] as? Double { edits.append(.fadeIn(c.id, to: max(0, min(f, c.duration)))) }
            if let f = args["fade_out"] as? Double { edits.append(.fadeOut(c.id, to: max(0, min(f, c.duration)))) }
            guard !edits.isEmpty else { throw MCPToolError("Give gain_db, fade_in or fade_out.") }
            try await perform(edits, model, who, draft)
            return json(clipsJSON([c.id], now()))

        case "set_transition":
            let c = try clipArg(args, p)
            let kindName = args["kind"] as? String ?? "dissolve"
            if kindName == "none" {
                try await perform([.change(c.id, "No transition") { proj in if let i = proj.index(of: c.id) { proj.clips[i].transitionIn = nil } }], model, who, draft)
            } else {
                guard let kind = TransitionKind(rawValue: kindName) else { throw MCPToolError("kind is dissolve, dipToBlack, wipe or none.") }
                guard p.clips.contains(where: { $0.trackID == c.trackID && $0.id != c.id && abs($0.end - c.start) < 1e-3 }) else {
                    throw MCPToolError("Nothing ends where this clip starts on its track, so there's nothing to transition from.")
                }
                let t = Transition(kind: kind, duration: max(0.04, (args["duration"] as? Double) ?? 0.5))
                try await perform([.transition(c.id, t)], model, who, draft)
            }
            return json(clipsJSON([c.id], now()))

        case "add_track":
            let kind: TrackKind = (args["kind"] as? String) == "audio" ? .audio : .video
            if let draft { draft.apply([addTrackEdit(kind, id: UUID())]) } else { model.addTrack(kind) }
            let tracks = now().tracks(kind)
            return text("Added \(kind == .video ? "V" : "A")\(tracks.count).")

        case "set_sequence":
            var size: (Int, Int)?
            if let w = args["width"] as? Int, let h = args["height"] as? Int {
                guard w >= 16, h >= 16, w <= 8192, h <= 8192 else { throw MCPToolError("Width and height are 16…8192.") }
                size = (w, h)
            }
            let fps = (args["fps"] as? Double).map(EditorModel.standardFPS)
            if let draft {
                draft.apply([.change(nil, "Sequence") { proj in
                    if let size { proj.width = size.0; proj.height = size.1 }
                    if let fps { proj.fps = fps }
                    proj.settingsLocked = true
                }])
            } else {
                if let size { model.setSequence(width: size.0, height: size.1) }
                if let fps { model.setFPS(fps) }
            }
            let q = now()
            return json(["width": q.width, "height": q.height, "fps": q.fps])

        case "playback":
            if let draft {
                // Nothing plays during a Magic edit; seeking moves get_frame's default time.
                if args["action"] as? String == "seek" { draft.playhead = max(0, try numArg(args, "time")) }
                return text("Playhead at \(String(format: "%.3f", draft.playhead))s. Playback is off while making a Magic edit; use get_frame to see the cut.")
            }
            switch args["action"] as? String {
            case "play": model.play()
            case "pause": model.pause()
            case "seek": model.seek(to: max(0, try numArg(args, "time")))
            default: throw MCPToolError("action is play, pause or seek.")
            }
            return text("Playhead at \(String(format: "%.3f", model.playhead))s, \(model.isPlaying ? "playing" : "paused").")

        case "history":
            if let draft {
                switch args["action"] as? String {
                case "undo":
                    guard draft.canUndo else { throw MCPToolError("Nothing to undo.") }
                    draft.undo()
                case "redo":
                    guard draft.canRedo else { throw MCPToolError("Nothing to redo.") }
                    draft.redo()
                default: throw MCPToolError("action is undo or redo.")
                }
                return text("Done. \(draft.project.clips.count) clips on the timeline.")
            }
            switch args["action"] as? String {
            case "undo":
                guard model.canUndo else { throw MCPToolError("Nothing to undo.") }
                model.undo()
            case "redo":
                guard model.canRedo else { throw MCPToolError("Nothing to redo.") }
                model.redo()
            default: throw MCPToolError("action is undo or redo.")
            }
            return text("Done. \(model.project.clips.count) clips on the timeline.")

        case "auto_edit":
            try notInMagic()
            while MagicShow.isRunning || MagicState.shared.busy { try? await Task.sleep(nanoseconds: 50_000_000) }
            MagicShow.start(model: model, fromMouse: false)
            try? await Task.sleep(nanoseconds: 100_000_000)
            while MagicShow.isRunning || MagicState.shared.busy { try? await Task.sleep(nanoseconds: 100_000_000) }
            return json(projectJSON(model.project, title: model.title, playhead: model.playhead))

        case "save_project":
            try notInMagic()
            guard model.fileURL != nil else { throw MCPToolError("This project has never been saved; ask the person to save it (File > Save).") }
            model.save()
            return text("Saved.")

        default:
            if let out = try await callMore(name, args, model: model, who: who, draft: draft) { return out }
            throw MCPToolError("No tool called \(name).")
        }
    }

    // MARK: Performing

    /// Plays edits with the agent's cursor and waits until they're done; during a Magic edit, just
    /// makes them in the draft.
    private static func perform(_ edits: [MagicEdit], _ model: EditorModel, _ who: String, _ draft: MCPDraft?) async throws {
        if let draft { return draft.apply(edits) }
        reveal(edits, model)
        let color = Self.color(for: who)
        let start = AgentPresence.shared.take(who)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                await MagicShow.perform(model: model, edits: edits, as: MagicShow.Performer(name: who, color: color, start: start) { _ in
                    cont.resume()
                })
            }
        }
    }

    /// Scrolls the timeline so what's being edited is in view.
    private static func reveal(_ edits: [MagicEdit], _ model: EditorModel) {
        var times: [Double] = []
        for e in edits {
            switch e {
            case .place(let clips, _): times += clips.flatMap { [$0.start, $0.end] }
            case .move(_, let from, let to, _): times += [from, to]
            case .trimHead(_, let from, let to), .trimTail(_, let from, let to): times += [from, to]
            case .blade(_, let at, _, _): times.append(at)
            default: times += e.clipIDs.compactMap { model.project.clip($0) }.flatMap { [$0.start, $0.end] }
            }
        }
        guard let lo = times.min(), let hi = times.max() else { return }
        let v = model.view
        let first = Double(v.scrollX / v.pps), last = Double((v.scrollX + v.viewWidth) / v.pps)
        guard lo < first || hi > last else { return }
        if hi - lo > last - first {
            model.setView(pps: (v.viewWidth - 80) / CGFloat(max(1, hi - lo)), scrollX: CGFloat(lo) * ((v.viewWidth - 80) / CGFloat(max(1, hi - lo))) - 40)
        } else {
            model.setView(scrollX: CGFloat(lo) * v.pps - v.viewWidth * 0.2)
        }
    }

    /// Claude in its orange, OpenAI's agents in their green, anyone else in a colour of their own.
    static func color(for name: String) -> NSColor {
        switch name {
        case "Claude": return NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case "Codex", "ChatGPT": return NSColor(srgbRed: 0.06, green: 0.64, blue: 0.50, alpha: 1)
        default:
            var h: UInt64 = 1469598103934665603
            for b in name.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
            return NSColor(hue: CGFloat(h % 360) / 360, saturation: 0.65, brightness: 0.95, alpha: 1)
        }
    }

    // MARK: Arguments

    private static func numArg(_ args: [String: Any], _ key: String) throws -> Double {
        if let d = args[key] as? Double { return d }
        if let i = args[key] as? Int { return Double(i) }
        throw MCPToolError("\(key) is needed, in seconds.")
    }

    private static func assetArg(_ args: [String: Any], _ p: Project) throws -> MediaAsset {
        guard let s = args["asset_id"] as? String else { throw MCPToolError("asset_id is needed (see list_media).") }
        guard let a = p.assets.first(where: { $0.id.uuidString == s.uppercased() || $0.name == s }) else {
            throw MCPToolError("No library item with id \(s). list_media has them.")
        }
        return a
    }

    private static func clipArg(_ args: [String: Any], _ p: Project) throws -> Clip {
        guard let s = args["clip_id"] as? String else { throw MCPToolError("clip_id is needed (see get_project).") }
        guard let id = UUID(uuidString: s), let c = p.clip(id) else { throw MCPToolError("No clip with id \(s). get_project has them.") }
        guard !p.isLocked(c.trackID) else { throw MCPToolError("That clip is on a locked track.") }
        return c
    }

    private static func trackArg(_ name: String, _ p: Project, kind: TrackKind) throws -> UUID {
        let n = name.uppercased().trimmingCharacters(in: .whitespaces)
        let prefix = kind == .video ? "V" : "A"
        guard n.hasPrefix(prefix), let i = Int(n.dropFirst()), i >= 1 else {
            throw MCPToolError("\(name) isn't a \(kind == .video ? "video track (V1, V2…)" : "audio track (A1, A2…)").")
        }
        let tracks = p.tracks(kind)
        guard i <= tracks.count else { throw MCPToolError("There's no \(n); there are \(tracks.count). add_track adds one.") }
        guard !tracks[i - 1].locked else { throw MCPToolError("\(n) is locked.") }
        return tracks[i - 1].id
    }

    // MARK: JSON

    /// Three decimal places, written as such ("5.417", not "5.4169999999999998").
    private static func round3(_ v: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.3f", v)) }

    static func trackName(_ id: UUID, _ p: Project) -> String {
        if let i = p.trackIndex(id, kind: .video) { return "V\(i + 1)" }
        if let i = p.trackIndex(id, kind: .audio) { return "A\(i + 1)" }
        return "?"
    }

    /// A transcript in file seconds: sentences, the pauses between talking (and before and after it), and
    /// words if asked for.
    private static func transcriptJSON(_ t: Transcript, asset a: MediaAsset, words: Bool) -> [String: Any] {
        var d: [String: Any] = ["asset_id": a.id.uuidString, "name": a.name, "duration": round3(a.duration)]
        guard !t.isEmpty else {
            d["status"] = "no_speech"
            d["note"] = "Nobody talks in it (or only music or noise)."
            return d
        }
        d["status"] = "ready"
        d["language"] = t.language
        d["times"] = "Seconds in the file. A clip plays the file from its source_start."
        d["sentences"] = t.sentences().map { ["start": round3($0.start), "end": round3($0.end), "text": $0.text] }
        // Silence of half a second or more, which is where cuts can go (filler like "um" isn't written
        // out, so it shows as a pause).
        let talk = t.speech()
        var pauses: [[String: Any]] = []
        var at = 0.0
        for s in talk {
            if s.start - at >= 0.5 { pauses.append(["start": round3(at), "end": round3(s.start)]) }
            at = s.end
        }
        if a.duration - at >= 0.5 { pauses.append(["start": round3(at), "end": round3(a.duration)]) }
        d["pauses"] = pauses
        if words { d["words"] = t.words.map { [round3($0.start), round3($0.end), $0.text] as [Any] } }
        return d
    }

    private static func assetJSON(_ a: MediaAsset) -> [String: Any] {
        var d: [String: Any] = ["id": a.id.uuidString, "name": a.name, "kind": a.kind.rawValue, "path": a.path]
        if a.kind != .image { d["duration"] = round3(a.duration) }
        if a.kind != .audio { d["width"] = a.width; d["height"] = a.height }
        if a.kind == .video { d["fps"] = round3(a.fps); d["has_audio"] = a.hasAudio }
        return d
    }

    /// A library item with whether people talk in it (once it's been heard), for list_media.
    @MainActor private static func assetJSON(_ a: MediaAsset, media: MediaStore, common: Set<String> = []) -> [String: Any] {
        var d = assetJSON(a)
        if let s = media.sceneTags(a.id) {
            let shows = s.top(20).filter { !common.contains($0) }.prefix(8)
            if !shows.isEmpty { d["shows"] = Array(shows) }
        }
        if let n = MediaNotes.note(for: a.path) { d["notes"] = n.text }
        if let t = media.transcript(a.id) {
            d["speech"] = !t.isEmpty
            if !t.isEmpty { d["says"] = String(t.text.prefix(120)) + (t.text.count > 120 ? "…" : "") }
        }
        return d
    }

    private static func clipsJSON(_ ids: [UUID], _ p: Project) -> [[String: Any]] {
        ids.compactMap { p.clip($0) }.map { clipJSON($0, p) }
    }

    private static func clipJSON(_ c: Clip, _ p: Project) -> [String: Any] {
        var d: [String: Any] = ["id": c.id.uuidString, "name": p.name(of: c), "kind": c.kind.rawValue, "track": trackName(c.trackID, p),
                                "start": round3(c.start), "end": round3(c.end), "duration": round3(c.duration)]
        if c.kind.usesSource { d["source_start"] = round3(c.sourceStart); d["asset_id"] = c.assetID?.uuidString ?? "" }
        if c.speed != 1 { d["speed"] = c.speed }
        if c.isRamped, let r = c.ramp {
            // Speed ramp, in seconds of the file (as set_speed_ramp takes them): `speed` from `from` to `to`,
            // easing from `start_speed` before and to `end_speed` after.
            d["speed_ramp"] = ["from": r.inTo, "to": r.outFrom, "ease_in": r.inTo - r.inFrom, "ease_out": r.outTo - r.outFrom,
                               "start_speed": r.startSpeed, "end_speed": r.endSpeed]
        }
        if c.isReversed { d["reversed"] = true }
        if c.isFreeze { d["freeze_frame"] = true }
        if let link = c.linkID, let other = p.clips.first(where: { $0.linkID == link && $0.id != c.id }) { d["linked_to"] = other.id.uuidString }
        if c.kind == .audio || c.gainDB != 0 { d["gain_db"] = round3(c.gainDB) }
        if c.fadeIn > 0 { d["fade_in"] = round3(c.fadeIn) }
        if c.fadeOut > 0 { d["fade_out"] = round3(c.fadeOut) }
        if let t = c.transitionIn { d["transition_in"] = ["kind": t.kind.rawValue, "duration": t.duration] }
        if c.kind == .text {
            d["text"] = c.text.string
            d["style"] = ["font": c.text.fontName.isEmpty ? "System" : c.text.fontName, "size": round3(c.text.size), "bold": c.text.bold,
                          "color": hex(c.text.color), "x": round3(c.text.x), "y": round3(c.text.y)]
        }
        if c.kind == .solid { d["color"] = hex(c.color) }
        if let tf = c.transform, !tf.isIdentity {
            var t: [String: Any] = ["scale": round3(tf.scale), "x": round3(tf.x), "y": round3(tf.y)]
            // An animated zoom: seconds into the clip that it moves in and out.
            if let z = tf.zoom {
                var zd: [String: Any] = ["mode": z.mode == .zoomIn ? "in" : z.mode == .zoomOut ? "out" : "in_out", "smooth": z.smooth]
                if z.mode != .zoomOut { zd["in"] = [round3(z.p1), round3(z.p2)] }
                if z.mode != .zoomIn { zd["out"] = [round3(z.p3), round3(z.p4)] }
                t["zoom"] = zd
            }
            d["transform"] = t
        }
        if let g = c.grade {
            var gd: [String: Any] = [:]
            if let look = g.look { gd["look"] = g.lookLabel; if look != g.lookLabel { gd["look_file"] = look } }
            if g.lookIntensity != 1 { gd["look_intensity"] = g.lookIntensity }
            for (k, v) in [("exposure", g.exposure), ("contrast", g.contrast), ("saturation", g.saturation), ("temperature", g.temperature), ("tint", g.tint)] where v != 0 {
                gd[k] = round3(v)
            }
            d["grade"] = gd
        }
        return d
    }

    /// A new empty track with a known id, so the same edit makes the same track when it's played back.
    private static func addTrackEdit(_ kind: TrackKind, id: UUID) -> MagicEdit {
        .change(nil, kind == .video ? "Add video track" : "Add audio track") { proj in
            var t = Track(kind: kind)
            t.id = id
            if kind == .video { proj.videoTracks.append(t) } else { proj.audioTracks.append(t) }
        }
    }

    private static func projectJSON(_ p: Project, title: String, playhead: Double) -> [String: Any] {
        let tracks = p.videoTracks.enumerated().reversed().map { i, t in
            ["name": "V\(i + 1)", "kind": "video", "hidden": t.hidden, "locked": t.locked] as [String: Any]
        } + p.audioTracks.enumerated().map { i, t in
            ["name": "A\(i + 1)", "kind": "audio", "muted": t.muted, "solo": t.solo, "locked": t.locked, "gain_db": t.gainDB] as [String: Any]
        }
        let clips = p.clips.sorted {
            (trackName($0.trackID, p), $0.start) < (trackName($1.trackID, p), $1.start)
        }.map { clipJSON($0, p) }
        return [
            "name": title,
            "sequence": ["width": p.width, "height": p.height, "fps": p.fps, "duration": round3(p.duration)],
            "playhead": round3(playhead),
            "tracks": tracks,
            "clips": clips,
            "markers": p.markerList.map { ["id": $0.id.uuidString, "time": round3($0.time), "name": $0.name, "color": $0.tint.rawValue] },
            "in_out": p.playRange.map { ["in": round3($0.start), "out": round3($0.end)] } ?? NSNull(),
            "captions": p.captions.map { c in
                ["hidden": c.hidden, "size": c.style.size, "position": c.style.y, "highlight": c.style.highlight,
                 "clip_ids": p.captionedClips.map(\.id.uuidString)] as [String: Any]
            } ?? NSNull(),
        ]
    }

    /// The caption track and its captions, as set_captions returns them.
    @MainActor private static func captionsJSON(_ p: Project, _ model: EditorModel) -> Any {
        guard let track = p.captions else { return NSNull() }
        let blocks = CaptionLayout.blocks(p) { model.media.transcript($0.id) }
        return ["hidden": track.hidden, "size": track.style.size, "position": track.style.y, "highlight": track.style.highlight,
                "clip_ids": p.captionedClips.map(\.id.uuidString),
                "count": blocks.count,
                "captions": blocks.prefix(60).map { ["start": round3($0.start), "end": round3($0.end), "text": $0.text] }] as [String: Any]
    }
}

// MARK: - Delivering, finding, marking, framing, and the rest

extension MCPTools {
    static var moreDefinitions: [[String: Any]] {
        [
            tool("export", "Export", "Exports the cut to a file, in the background (export_status says how it's going, or set wait). Saved in the folder the person last exported to (else beside the project, else Movies); never over an existing file. Not available while making a Magic edit.",
                 ["name": str("File name, without extension (default: the project's)."),
                  "format": ["type": "string", "enum": ["video", "audio"], "description": "An MP4, or a WAV of the sound (default video)."],
                  "shape": ["type": "string", "enum": ["original", "vertical", "square", "portrait"], "description": "original is the sequence's own shape; vertical 9:16, square 1:1 and portrait 4:5 crop it."],
                  "height": ["type": "integer", "description": "Output height in pixels (for vertical, square and portrait: the short side), e.g. 720, 1080, 2160. Default: the sequence's."],
                  "codec": ["type": "string", "enum": ["h264", "hevc"]], "quality": ["type": "string", "enum": ["high", "web"]],
                  "include_audio": ["type": "boolean", "description": "Default true."],
                  "loudness": num("Target loudness in LUFS: -14 for YouTube and social, -16 for podcasts, -23 for broadcast. Leave out to keep the levels."),
                  "range_only": ["type": "boolean", "description": "Just the in/out range (see set_in_out)."],
                  "reframe_x": num("For a crop: which part to keep, 0 (left) to 1 (right). Default 0.5."),
                  "reframe_y": num("For a crop: 0 (top) to 1 (bottom). Default 0.5."),
                  "wait": ["type": "boolean", "description": "Wait until it's done (up to about 4 minutes) instead of returning straight away."]]),
            tool("export_status", "Export status", "Exports started from Editroom (by anyone): their files and whether they're waiting, running, done or failed.", readOnly: true),
            tool("search_media", "Search media", "Finds library items by what they show (people, places, things: \"beach\", \"dog\", \"car at night\") and/or what's said in them, with the times in each file. Much quicker than looking at or transcribing each one. Seen and heard on this Mac in the background after import, so a new file may not be searchable yet.",
                 ["shows": str("Words for what's in the shot; every word has to match."), "said": str("Words someone says, in order.")], readOnly: true),
            tool("set_marker", "Set marker", "Adds a marker on the timeline, or changes one (give marker_id, from get_project). Use markers when asked to mark moments (beats, highlights, places to cut).",
                 ["marker_id": str("To change an existing marker."), "time": num("Timeline seconds (needed for a new marker)."), "name": str("What to call it."),
                  "color": ["type": "string", "enum": Marker.Tint.allCases.map(\.rawValue)]]),
            tool("delete_markers", "Delete markers", "Removes markers.", ["marker_ids": ["type": "array", "items": ["type": "string"]], "all": ["type": "boolean", "description": "Remove every marker."]]),
            tool("set_in_out", "Set in and out", "The in/out range: what Loop plays and what export can be limited to (range_only).",
                 ["in": num("Timeline seconds."), "out": num("Timeline seconds."), "clear": ["type": "boolean", "description": "Remove the range."]]),
            tool("set_transform", "Position, scale and zoom", "Moves and scales a video, photo or solid in the frame, for reframing (keeping a subject in a vertical crop, a picture-in-picture). With zoom, it animates over the clip between the full frame and this scale and framing: pushing in on a moment, or following the action in a screen recording. A title's place is set with set_title_style.",
                 ["clip_id": str("A clip's id."), "scale": num("1 fits the frame; 2 is twice as big (0.05...10). With zoom, how far in it goes (default 2)."),
                  "x": num("Offset of its centre across, as a fraction of the frame's width (0 is centred, 0.5 is the right edge)."),
                  "y": num("Offset down, as a fraction of the frame's height (0 is centred, positive is lower)."),
                  "focus_x": num("Instead of x: the point to frame, across the picture (0 left edge, 0.5 centre, 1 right edge). Scaled up, the picture is placed so that point is centred, as near as its edges allow."),
                  "focus_y": num("Instead of y: the point to frame, down the picture (0 top, 0.5 centre, 1 bottom)."),
                  "zoom": ["type": "string", "enum": ["in", "in_out", "out", "off"], "description": "Animate: in (full frame to this framing), in_out (in, hold, back out at the end), out (from this framing back to the full frame), or off (stay at this framing)."],
                  "zoom_seconds": num("How long each move takes (default a quarter of the clip, 0.5 to 2 seconds)."),
                  "zoom_start": num("Seconds into the clip when the move starts: for in and in_out, when it starts moving in (default 0); for out, when it starts moving out (default so it ends with the clip)."),
                  "zoom_smooth": ["type": "boolean", "description": "Eased in and out (the default), or false for an even pace."],
                  "reset": ["type": "boolean", "description": "Back to fitted and centred, with no zoom."]],
                 required: ["clip_id"]),
            tool("set_title_style", "Title style", "A title's words and look. Leave out what shouldn't change.",
                 ["clip_id": str("A title clip's id."), "text": str("The words."), "font": str("A font family installed on this Mac, or \"System\"."),
                  "size": num("Points, for a 1080-pixel-tall frame (12...600; default 110)."), "bold": ["type": "boolean"],
                  "color": str("Hex, like #FFFFFF."), "x": num("Its centre across, 0 (left) to 1 (right)."), "y": num("Its centre down, 0 (top) to 1 (bottom).")],
                 required: ["clip_id"]),
            tool("freeze_frame", "Freeze frame", "Holds one frame of a video clip: the clip is cut there, the held frame goes in, and what follows on its tracks moves along to make room.",
                 ["clip_id": str("A video clip's id."), "at": num("Timeline time inside the clip (default: its middle)."), "seconds": num("How long to hold (default 2).")],
                 required: ["clip_id"]),
            tool("reverse_clip", "Reverse", "Plays a clip (and its linked sound) backwards; again plays it forwards.", ["clip_id": str("A clip's id.")], required: ["clip_id"]),
            tool("detach_audio", "Detach audio", "Unlinks a video from its sound, so each can be moved, trimmed or deleted on its own.", ["clip_id": str("The video's or its sound's id.")], required: ["clip_id"]),
            tool("duplicate_clip", "Duplicate clip", "Copies a clip (and anything linked to it) to another time.",
                 ["clip_id": str("A clip's id."), "start": num("Where the copy starts (default: straight after the clip).")], required: ["clip_id"]),
            tool("set_track", "Set track", "A track's switches and level.",
                 ["track": str("V1, V2… or A1, A2…"), "hidden": ["type": "boolean", "description": "Video tracks."], "muted": ["type": "boolean", "description": "Audio tracks."],
                  "solo": ["type": "boolean", "description": "Audio tracks."], "locked": ["type": "boolean"], "gain_db": num("Audio tracks, -60...12.")],
                 required: ["track"]),
            tool("add_solid", "Add solid", "Adds a solid colour (a background, a flash, a colour card).",
                 ["color": str("Hex, like #000000 (default black)."), "start": num("Default 0."), "duration": num("Default 3."), "track": str("A video track (default: one that's free there).")]),
            tool("set_solid_color", "Solid colour", "Changes a solid's colour.", ["clip_id": str("A solid's id."), "color": str("Hex, like #1A1A1A.")], required: ["clip_id", "color"]),
        ]
    }

    static func hex(_ c: RGBA) -> String {
        String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    private static func colorArg(_ v: Any?) throws -> RGBA? {
        guard let s = (v as? String)?.trimmingCharacters(in: .whitespaces) else { return nil }
        let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard h.count == 6, let n = UInt32(h, radix: 16) else { throw MCPToolError("Colours are hex, like #FF4A1C.") }
        return RGBA(r: Double(n >> 16 & 255) / 255, g: Double(n >> 8 & 255) / 255, b: Double(n & 255) / 255, a: 1)
    }

    private static func double(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) }

    /// The tools above; nil for a name that isn't one of them.
    static func callMore(_ name: String, _ args: [String: Any], model: EditorModel, who: String, draft: MCPDraft?) async throws -> [[String: Any]]? {
        func now() -> Project { draft?.project ?? model.project }
        func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": s]] }
        func json(_ v: Any) -> [[String: Any]] {
            let d = (try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return text(String(data: d, encoding: .utf8) ?? "{}")
        }
        let p = now()

        switch name {
        case "export":
            if draft != nil { throw MCPToolError("export isn't available while making a Magic edit; the person can export it when it's done.") }
            model.commitLive()
            let q = model.project
            guard !q.clips.isEmpty else { throw MCPToolError("The timeline is empty.") }
            var s = ExportSettings()
            if (args["format"] as? String) == "audio" { s.format = .wav }
            if let shape = args["shape"] as? String {
                guard let v = ExportSettings.Shape(rawValue: shape) else { throw MCPToolError("shape is original, vertical, square or portrait.") }
                s.shape = v
            }
            if let h = args["height"] as? Int {
                guard (144...4320).contains(h) else { throw MCPToolError("height is 144…4320.") }
                s.height = h
            }
            if (args["codec"] as? String) == "hevc" { s.codec = .hevc }
            if (args["quality"] as? String) == "web" { s.quality = .web }
            if let a = args["include_audio"] as? Bool { s.includeAudio = a }
            if let l = double(args["loudness"]) {
                guard (-40...(-5)).contains(l) else { throw MCPToolError("loudness is a LUFS target, -40…-5 (like -14).") }
                s.loudness = l
            }
            if args["range_only"] as? Bool == true {
                guard q.playRange != nil else { throw MCPToolError("There's no in/out range; set_in_out sets one.") }
                s.rangeOnly = true
            }
            s.reframe = CGPoint(x: (double(args["reframe_x"]) ?? 0.5).clamped(to: 0...1), y: (double(args["reframe_y"]) ?? 0.5).clamped(to: 0...1))
            if s.format == .wav, !q.clips.contains(where: { $0.kind == .audio }) { throw MCPToolError("There's no sound on the timeline.") }
            // Where the person last exported to, else beside the project, else Movies.
            let fm = FileManager.default
            var isDir: ObjCBool = false
            let folder: URL = {
                if let d = q.exportDir, fm.fileExists(atPath: d, isDirectory: &isDir), isDir.boolValue { return URL(fileURLWithPath: d) }
                if let f = model.fileURL?.deletingLastPathComponent() { return f }
                return fm.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            }()
            var base = ((args["name"] as? String) ?? q.exportName ?? model.title).trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            if base.isEmpty { base = model.title }
            var url = folder.appendingPathComponent(base + "." + s.fileExtension)
            var n = 2
            while fm.fileExists(atPath: url.path) || model.exports.items.contains(where: { $0.url == url }) {
                url = folder.appendingPathComponent("\(base) \(n).\(s.fileExtension)")
                n += 1
            }
            model.exports.add(project: q, media: model.media, settings: s, url: url)
            let size = s.renderSize(for: s.output(q))
            var out: [String: Any] = ["file": url.path, "size": s.format == .wav ? "audio" : "\(Int(size.width))×\(Int(size.height))",
                                      "status": "started"]
            if args["wait"] as? Bool == true {
                let started = Date()
                while Date().timeIntervalSince(started) < 240 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let item = model.exports.items.first(where: { $0.url == url }) else { break }
                    switch item.status {
                    case .done: out["status"] = "done"; return json(out)
                    case .failed(let why): throw MCPToolError("The export failed: \(why)")
                    case .cancelled: out["status"] = "cancelled"; return json(out)
                    default: continue
                    }
                }
                out["status"] = "still exporting; export_status says when it's done"
            }
            return json(out)

        case "export_status":
            let items = model.exports.items.map { item -> [String: Any] in
                let status: String = switch item.status {
                case .waiting: "waiting"
                case .running: "running"
                case .done: "done"
                case .failed(let why): "failed: \(why)"
                case .cancelled: "cancelled"
                }
                var d: [String: Any] = ["file": item.url.path, "status": status]
                if item.status == .running { d["progress"] = NSDecimalNumber(string: String(format: "%.2f", model.exports.progress)) }
                return d
            }
            if items.isEmpty { return json(["exports": [Any](), "note": "Nothing exporting, and nothing finished recently."] as [String: Any]) }
            return json(["exports": items] as [String: Any])

        case "search_media":
            let shows = (args["shows"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let said = (args["said"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !shows.isEmpty || !said.isEmpty else { throw MCPToolError("Give shows and/or said.") }
            let words = shows.split(separator: " ").map(String.init).filter { !["a", "an", "the", "of", "in", "on", "at", "with"].contains($0) }
            var found: [[String: Any]] = []
            var unseen = 0, unheard = 0
            for a in p.assets {
                var hit: [String: Any] = ["asset_id": a.id.uuidString, "name": a.name]
                if !words.isEmpty {
                    let tags = model.media.sceneTags(a.id)
                    if tags == nil, a.kind != .audio { unseen += 1 }
                    guard words.allSatisfy({ w in a.name.lowercased().contains(w) || tags?.shows(w) == true }) else { continue }
                    let matched = words.flatMap { tags?.matching($0) ?? [] }
                    if !matched.isEmpty {
                        hit["shows"] = matched.map { ["tag": $0.name, "times": $0.times.prefix(8).map { round3($0) }] as [String: Any] }
                    }
                }
                if !said.isEmpty {
                    guard a.kind != .image else { continue }
                    guard let t = model.media.transcript(a.id) else { unheard += 1; continue }
                    let places = t.occurrences(said)
                    guard !places.isEmpty else { continue }
                    hit["said"] = places.prefix(10).map { ["start": round3($0.start), "end": round3($0.end), "words": $0.context] as [String: Any] }
                }
                found.append(hit)
            }
            var out: [String: Any] = ["found": found, "times": "Seconds in each file, like source_start."]
            var notes: [String] = []
            if unseen > 0 { notes.append("\(unseen) item\(unseen == 1 ? " hasn't" : "s haven't") been looked through yet") }
            if unheard > 0 { notes.append("\(unheard) haven't been heard yet (get_transcript hears one now)") }
            if !notes.isEmpty { out["note"] = notes.joined(separator: "; ") + "." }
            return json(out)

        case "set_marker":
            let tint = try (args["color"] as? String).map { c -> Marker.Tint in
                guard let t = Marker.Tint(rawValue: c) else { throw MCPToolError("color is " + Marker.Tint.allCases.map(\.rawValue).joined(separator: ", ") + ".") }
                return t
            }
            let time = double(args["time"]).map { p.snapFrame(max(0, $0)) }
            let label = args["name"] as? String
            var id = UUID()
            if let s = args["marker_id"] as? String {
                guard let m = p.markerList.first(where: { $0.id.uuidString == s.uppercased() }) else { throw MCPToolError("No marker \(s); get_project lists them.") }
                id = m.id
                try await perform([.change(nil, "Marker") { q in
                    guard let i = q.markers?.firstIndex(where: { $0.id == m.id }) else { return }
                    if let time { q.markers![i].time = time }
                    if let label { q.markers![i].name = label }
                    if let tint { q.markers![i].tint = tint }
                }], model, who, draft)
            } else {
                guard let time else { throw MCPToolError("time is needed for a new marker.") }
                let m = Marker(id: id, time: time, name: label ?? "Marker \((p.markers?.count ?? 0) + 1)", tint: tint ?? .yellow)
                try await perform([.change(nil, "Marker") { q in q.markers = (q.markers ?? []) + [m] }], model, who, draft)
            }
            guard let m = now().markerList.first(where: { $0.id == id }) else { throw MCPToolError("The marker didn't stick.") }
            return json(["id": m.id.uuidString, "time": round3(m.time), "name": m.name, "color": m.tint.rawValue])

        case "delete_markers":
            let ids: Set<UUID> = args["all"] as? Bool == true ? Set(p.markerList.map(\.id))
                : Set(((args["marker_ids"] as? [String]) ?? []).compactMap { UUID(uuidString: $0) })
            guard !ids.isEmpty else { throw MCPToolError("Give marker_ids, or all: true.") }
            try await perform([.change(nil, "Markers") { q in
                q.markers?.removeAll { ids.contains($0.id) }
                if q.markers?.isEmpty == true { q.markers = nil }
            }], model, who, draft)
            return text("\(now().markerList.count) marker\(now().markerList.count == 1 ? "" : "s") left.")

        case "set_in_out":
            if args["clear"] as? Bool == true {
                try await perform([.change(nil, "Clear in/out") { q in q.inPoint = nil; q.outPoint = nil }], model, who, draft)
                return text("No in/out range.")
            }
            let i = double(args["in"]).map { p.snapFrame(max(0, $0)) }
            let o = double(args["out"]).map { p.snapFrame(max(0, $0)) }
            guard i != nil || o != nil else { throw MCPToolError("Give in and/or out, or clear: true.") }
            if let i, let o, o <= i { throw MCPToolError("out has to be after in.") }
            try await perform([.change(nil, "In/out") { q in
                if let i { q.inPoint = i; if let out = q.outPoint, out <= i { q.outPoint = nil } }
                if let o { q.outPoint = o; if let inn = q.inPoint, inn >= o { q.inPoint = nil } }
            }], model, who, draft)
            let r = now().playRange
            return json(["in": r.map { round3($0.start) } ?? NSNull(), "out": r.map { round3($0.end) } ?? NSNull()])

        case "set_transform":
            let c = try clipArg(args, p)
            guard c.isTransformable else { throw MCPToolError(c.kind == .text ? "Titles are placed with set_title_style." : "Sound has no picture to move.") }
            var tf = args["reset"] as? Bool == true ? ClipTransform() : (c.transform ?? ClipTransform())
            if let s = double(args["scale"]) { tf.scale = s.clamped(to: ClipTransform.scaleRange) }
            if let x = double(args["x"]) { tf.x = x.clamped(to: -2...2) }
            if let y = double(args["y"]) { tf.y = y.clamped(to: -2...2) }
            // Zoom: from the full frame to this framing over the clip (as the Scale field's zoom button).
            if let z = args["zoom"] as? String {
                switch z {
                case "off":
                    tf.zoom = nil
                case "in", "in_out", "out":
                    let mode: ZoomMove.Mode = z == "in" ? .zoomIn : z == "out" ? .zoomOut : .inOut
                    let length = c.duration
                    if double(args["scale"]) == nil, tf.scale <= 1.01 { tf.scale = 2 }
                    var move = ZoomMove.starter(mode, length: length)
                    let m = double(args["zoom_seconds"]).map { min(max($0, 0.05), mode == .inOut ? length / 2 : length) }
                        ?? (move.p2 - move.p1 > 0 ? move.p2 - move.p1 : move.p4 - move.p3)
                    let start = double(args["zoom_start"])
                    switch mode {
                    case .zoomIn:
                        move.p1 = start ?? 0; move.p2 = move.p1 + m; move.p3 = length; move.p4 = length
                    case .zoomOut:
                        move.p1 = 0; move.p2 = 0; move.p3 = start ?? (length - m); move.p4 = move.p3 + m
                    case .inOut:
                        move.p1 = start ?? 0; move.p2 = move.p1 + m; move.p3 = max(move.p2, length - m); move.p4 = length
                    }
                    if let smooth = args["zoom_smooth"] as? Bool { move.smooth = smooth }
                    move.fit(length: length)
                    tf.zoom = move
                default:
                    throw MCPToolError("zoom is in, in_out, out or off.")
                }
            } else if let smooth = args["zoom_smooth"] as? Bool {
                tf.zoom?.smooth = smooth
            }
            // A point to frame: the picture is moved so that point is centred (kept within its edges when it fills).
            if let fx = double(args["focus_x"]) { tf.x = (-(fx.clamped(to: 0...1) - 0.5) * tf.scale).clamped(to: -2...2) }
            if let fy = double(args["focus_y"]) { tf.y = (-(fy.clamped(to: 0...1) - 0.5) * tf.scale).clamped(to: -2...2) }
            if tf.fills { (tf.x, tf.y) = tf.zoomedOffset }
            let set = tf
            try await perform([.change(c.id, "Transform") { q in if let i = q.index(of: c.id) { q.clips[i].transform = set.isIdentity ? nil : set } }], model, who, draft)
            return json(clipsJSON([c.id], now()))

        case "set_title_style":
            let c = try clipArg(args, p)
            guard c.kind == .text else { throw MCPToolError("That clip isn't a title.") }
            var font: String?
            if let f = (args["font"] as? String)?.trimmingCharacters(in: .whitespaces) {
                if f.lowercased() == "system" || f.isEmpty {
                    font = ""
                } else {
                    guard let family = NSFontManager.shared.availableFontFamilies.first(where: { $0.caseInsensitiveCompare(f) == .orderedSame }) else {
                        throw MCPToolError("\(f) isn't installed on this Mac. Try System, Helvetica Neue, Futura, Avenir Next, Georgia or Didot.")
                    }
                    font = family
                }
            }
            let color = try colorArg(args["color"])
            let words = args["text"] as? String
            let size = double(args["size"]).map { $0.clamped(to: 12...600) }
            let bold = args["bold"] as? Bool
            let x = double(args["x"]).map { $0.clamped(to: 0...1) }, y = double(args["y"]).map { $0.clamped(to: 0...1) }
            guard font != nil || color != nil || words != nil || size != nil || bold != nil || x != nil || y != nil else {
                throw MCPToolError("Give at least one of text, font, size, bold, color, x, y.")
            }
            var edits: [MagicEdit] = []
            if let words { edits.append(.type(c.id, words)) }
            edits.append(.change(c.id, "Title style") { q in
                guard let i = q.index(of: c.id) else { return }
                if let font { q.clips[i].text.fontName = font }
                if let color { q.clips[i].text.color = color }
                if let size { q.clips[i].text.size = size }
                if let bold { q.clips[i].text.bold = bold }
                if let x { q.clips[i].text.x = x }
                if let y { q.clips[i].text.y = y }
            })
            try await perform(edits, model, who, draft)
            return json(clipsJSON([c.id], now()))

        case "freeze_frame":
            let c = try clipArg(args, p)
            guard c.kind == .video, !c.isFreeze else { throw MCPToolError("Freeze frames are made from a video clip.") }
            let t = p.snapFrame(double(args["at"]) ?? (c.start + c.duration / 2))
            guard t > c.start, t < c.end else { throw MCPToolError("at has to be inside the clip (\(round3(c.start))…\(round3(c.end))).") }
            let hold = max(1 / p.fps, double(args["seconds"]) ?? 2)
            var source = c.sourceTime(at: t)
            if c.playsBackwards, let length = p.asset(c.assetID)?.duration { source = max(0, length - source - 0.001) }
            let made = UUID()
            try await perform([.change(c.id, "Freeze") { q in
                let group = q.linked([c.id])
                _ = q.split(ids: group, at: t)
                let tracks = Set(q.clips.filter { group.contains($0.id) }.map(\.trackID))
                var shifting = Set(q.clips.filter { tracks.contains($0.trackID) && $0.start >= t - 1e-6 }.map(\.id))
                shifting = q.unlocked(q.linked(shifting))
                for i in q.clips.indices where shifting.contains(q.clips[i].id) { q.clips[i].start += hold }
                var f = Clip(trackID: c.trackID, kind: .video, assetID: c.assetID, start: t, duration: hold, sourceStart: source)
                f.id = made
                f.freeze = true
                f.grade = c.grade
                f.transform = c.transform
                q.clips.append(f)
                q.resolveOverlaps(keeping: shifting.union([f.id]))
            }], model, who, draft)
            return json(clipsJSON([made], now()))

        case "reverse_clip":
            let c = try clipArg(args, p)
            guard c.playsSource, c.reversedFrom == nil else { throw MCPToolError("Only video and sound from a file can be reversed.") }
            let group = p.unlocked(p.linked([c.id]))
            let backwards = !c.playsBackwards
            for m in p.clips where group.contains(m.id) && m.kind == .audio && backwards {
                if let id = m.assetID { model.media.prepareReversedAudio(id) }
            }
            try await perform([.change(c.id, backwards ? "Reverse" : "Forwards") { q in
                for i in q.clips.indices where group.contains(q.clips[i].id) && q.clips[i].playsSource && q.clips[i].reversedFrom == nil {
                    guard let length = q.asset(q.clips[i].assetID)?.duration else { continue }
                    let m = q.clips[i]
                    q.clips[i].sourceStart = max(0, length - (m.sourceStart + m.sourceLength))
                    q.clips[i].ramp = m.ramp?.mirrored(length: length)
                    q.clips[i].reversed = backwards ? true : nil
                }
            }], model, who, draft)
            return json(clipsJSON(Array(group), now()))

        case "detach_audio":
            let c = try clipArg(args, p)
            guard c.linkID != nil else { throw MCPToolError("That clip isn't linked to anything.") }
            let group = p.linked([c.id])
            try await perform([.change(c.id, "Detach") { q in q.unlink(ids: group) }], model, who, draft)
            return json(clipsJSON(Array(group), now()))

        case "duplicate_clip":
            let c = try clipArg(args, p)
            let group = p.clips.filter { p.linked([c.id]).contains($0.id) }
            let t0 = group.map(\.start).min() ?? c.start
            let at = p.snapFrame(max(0, double(args["start"]) ?? (group.map(\.end).max() ?? c.end)))
            var links: [UUID: UUID] = [:]
            let copies = group.map { original -> Clip in
                var n = original
                n.id = UUID()
                if let l = n.linkID { if links[l] == nil { links[l] = UUID() }; n.linkID = links[l] }
                n.start = at + (original.start - t0)
                return n
            }
            try await perform([.place(copies, asset: c.assetID)], model, who, draft)
            return json(clipsJSON(copies.map(\.id), now()))

        case "set_track":
            guard let tn = args["track"] as? String else { throw MCPToolError("track is needed (V1, A1…).") }
            let isVideo = tn.uppercased().hasPrefix("V")
            let kind: TrackKind = isVideo ? .video : .audio
            let n = tn.uppercased().trimmingCharacters(in: .whitespaces)
            guard let i = Int(n.dropFirst()), i >= 1, i <= p.tracks(kind).count else { throw MCPToolError("There's no \(tn).") }
            let id = p.tracks(kind)[i - 1].id
            let hidden = args["hidden"] as? Bool, muted = args["muted"] as? Bool, solo = args["solo"] as? Bool, locked = args["locked"] as? Bool
            let gain = double(args["gain_db"]).map { $0.clamped(to: -60...12) }
            guard hidden != nil || muted != nil || solo != nil || locked != nil || gain != nil else {
                throw MCPToolError("Give hidden, muted, solo, locked or gain_db.")
            }
            try await perform([.change(nil, "Track") { q in
                func edit(_ t: inout Track) {
                    if let hidden { t.hidden = hidden }
                    if let muted { t.muted = muted }
                    if let solo { t.solo = solo }
                    if let locked { t.locked = locked }
                    if let gain { t.gainDB = gain }
                }
                if let j = q.videoTracks.firstIndex(where: { $0.id == id }) { edit(&q.videoTracks[j]) }
                if let j = q.audioTracks.firstIndex(where: { $0.id == id }) { edit(&q.audioTracks[j]) }
            }], model, who, draft)
            let t = now().tracks(kind)[i - 1]
            return json(["track": n, "hidden": t.hidden, "muted": t.muted, "solo": t.solo, "locked": t.locked, "gain_db": round3(t.gainDB)])

        case "add_solid":
            let color = try colorArg(args["color"]) ?? .black
            let start = p.snapFrame(max(0, double(args["start"]) ?? 0))
            let length = p.snapFrame(max(1 / p.fps, double(args["duration"]) ?? 3))
            var edits: [MagicEdit] = []
            let track: UUID
            if let tn = args["track"] as? String {
                track = try trackArg(tn, p, kind: .video)
            } else if let free = p.videoTracks.first(where: { t in !t.locked && !p.clips.contains { $0.trackID == t.id && $0.start < start + length && $0.end > start } }) {
                track = free.id
            } else {
                track = UUID()
                edits.append(addTrackEdit(.video, id: track))
            }
            var solid = Clip(trackID: track, kind: .solid, start: start, duration: length)
            solid.color = color
            edits.append(.place([solid], asset: nil))
            try await perform(edits, model, who, draft)
            return json(clipsJSON([solid.id], now()))

        case "set_solid_color":
            let c = try clipArg(args, p)
            guard c.kind == .solid else { throw MCPToolError("That clip isn't a solid.") }
            guard let color = try colorArg(args["color"]) else { throw MCPToolError("color is needed, like #000000.") }
            try await perform([.change(c.id, "Colour") { q in if let i = q.index(of: c.id) { q.clips[i].color = color } }], model, who, draft)
            return json(clipsJSON([c.id], now()))

        default:
            return nil
        }
    }
}
