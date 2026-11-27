import Foundation

/// Tools for long, multi-camera painting classes: subtitles in and out (for translation and dubbing),
/// syncing and switching cameras, and taking out or speeding up where nothing happens.
extension MCPTools {
    private static func p(_ name: String, _ title: String, _ description: String, _ props: [String: Any] = [:],
                          required: [String] = [], readOnly: Bool = false) -> [String: Any] {
        [
            "name": name, "title": title, "description": description,
            "inputSchema": ["type": "object", "properties": props, "required": required] as [String: Any],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": false, "openWorldHint": false],
        ]
    }
    private static func n(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    private static func s(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    private static func b(_ d: String) -> [String: Any] { ["type": "boolean", "description": d] }
    private static func ids(_ d: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": d] }

    static var classDefinitions: [[String: Any]] {
        [
            p("export_subtitles", "Export subtitles", "Writes the captions as they show (what's heard, or the subtitle layer shown) to a file, timed to the timeline: SRT, plain text, or text with times. For translating or dubbing elsewhere. Captions must be on (set_captions).",
              ["path": s("Absolute path of the file to write (.srt or .txt)."), "format": ["type": "string", "enum": ["srt", "text", "text_with_times"]],
               "range_only": b("Only the in/out range, timed from its start (to match an export of just that range).")], required: ["path"]),
            p("import_subtitles", "Import subtitles", "Brings an SRT in as a subtitle layer (a translation, say) and shows it on the caption track. timing \"timeline\" (default): times are from the start of this timeline, as export_subtitles writes them. timing \"file\": times are from the start of one library item's own file (give asset_id). Importing the same name again replaces that layer.",
              ["path": s("Absolute path of the .srt or .vtt file."), "name": s("The layer's name, like \"English\" (default: the file's name)."),
               "timing": ["type": "string", "enum": ["timeline", "file"]], "asset_id": s("For timing \"file\": the library item it's timed to.")], required: ["path"]),
            p("list_subtitle_layers", "List subtitle layers", "The subtitle layers brought in, and which one the caption track shows (none: what's heard).", readOnly: true),
            p("set_subtitle_layer", "Show subtitle layer", "Which subtitles the caption track shows: a layer's name, or \"heard\" for what's said.",
              ["layer": s("A layer's name, or \"heard\".")], required: ["layer"]),
            p("import_dub", "Import dub", "Lays a narration file (a dub made from translated subtitles, timed to this timeline from 0) on a new sound track from the start, with the camera sound turned down under it.",
              ["path": s("Absolute path of the sound file."), "duck_db": n("How far the camera sound goes down while the dub speaks (default -24).")], required: ["path"]),
            p("transcribe_again", "Transcribe again", "Hears these library items afresh (after the language setting changed, or Whisper was installed).",
              ["asset_ids": ids("Library item ids.")], required: ["asset_ids"]),
            p("make_multicam", "Make multi-angle", "Several cameras of the same session as one multi-angle group. reference_clip_id is the main camera's video clip on the timeline (its sound plays all through). The other cameras are library items, lined up to it by their sound (or by sync_offsets if you know them). The reference clip's sound is unlinked from its picture, so switch_angle can change the picture while the sound runs on. Returns each camera's number and offset.",
              ["reference_clip_id": s("The main camera's video clip."), "asset_ids": ids("The other cameras' library items."),
               "sync_offsets": ["type": "array", "items": ["type": "number"], "description": "Optional, one per asset_id: seconds to add to a time in the main camera's file to find the same moment in that camera's file."]],
              required: ["reference_clip_id", "asset_ids"]),
            p("list_angles", "List cameras", "Multi-angle groups: each camera's number, name and offset, and which camera the main track shows where.", readOnly: true),
            p("switch_angle", "Switch camera", "From a time on (to the end of the multi-angle clip there), the main track shows another camera of the same moment. Call it at each time you want a cut.",
              ["time": n("Timeline seconds."), "camera": ["type": "integer", "description": "Camera number, 1 for the main camera."]], required: ["time", "camera"]),
            p("set_pip", "Picture in picture", "Another camera small in a corner, over the given multi-angle clips (or the one at time), on the video track above. Remove it with delete_clips.",
              ["camera": ["type": "integer", "description": "Camera number."], "clip_ids": ids("Multi-angle clips to put it over."), "time": n("Or the main clip at this time."),
               "corner": ["type": "string", "enum": PictureCorner.allCases.map(\.rawValue)], "scale": n("Size, 0.15...0.5 of the frame (default 0.32).")],
              required: ["camera"]),
            p("remove_dead_air", "Remove dead air", "Finds stretches where nothing happens and cuts them out (closing up every track, so sound and picture stay in sync) or speeds them up. kind \"quiet_and_still\" (default, safest for a painting class: painting in silence still counts as something happening), \"quiet\" (nobody talks) or \"still\" (nothing moves). With dry_run, only says where they are.",
              ["kind": ["type": "string", "enum": DeadAirKind.allCases.map(\.rawValue)], "min_length": n("Shortest stretch to take, in seconds (default 5)."),
               "action": ["type": "string", "enum": ["cut", "speed"]], "speed": n("For action speed: how many times faster (default 8)."),
               "start": n("Only from here (timeline seconds)."), "end": n("Only to here."), "sensitivity": n("0...1: higher finds more (default 0.5)."),
               "dry_run": b("Just list the stretches.")]),
            p("speed_up_range", "Speed up range", "A timelapse: start to end plays faster on every track, closing up after it so everything stays in sync. With only_quiet, only the parts where nobody talks are sped up, so explanations play at normal speed. Good for the long finishing stretch near the end of a class.",
              ["start": n("Timeline seconds."), "end": n("Timeline seconds (default: the end)."), "speed": n("How many times faster, 1.1...100."),
               "only_quiet": b("Only where nobody talks (default false)."), "mute_sound": b("Turn the sped-up sound off (default true)."),
               "min_quiet": n("With only_quiet: shortest quiet stretch to speed up, in seconds (default 3).")], required: ["start", "speed"]),
        ]
    }

    private static func out(_ v: Any) -> [[String: Any]] {
        let d = (try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return [["type": "text", "text": String(data: d, encoding: .utf8) ?? "{}"]]
    }
    private static func num(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) }
    private static func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    /// A local file the agent named, which must exist. In a Magic run, only when Claude may use files.
    private static func localFile(_ args: [String: Any], _ draft: MCPDraft?) throws -> URL {
        if draft != nil, !MagicAgent.filesAllowed { throw MCPToolError("Reading files isn't allowed in this Magic run.") }
        guard let path = args["path"] as? String, !path.isEmpty else { throw MCPToolError("path is needed.") }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MCPToolError("No file at \(url.path).") }
        return url
    }

    /// Makes a change (with the agent's cursor, or in the Magic draft), after checking it works on a copy.
    private static func change(_ label: String, anchor: UUID?, _ model: EditorModel, _ who: String, _ draft: MCPDraft?,
                               _ body: @escaping (inout Project) throws -> Void) async throws {
        var test = draft?.project ?? model.project
        do { try body(&test) } catch let e as AngleError { throw MCPToolError(e.message) }
        try await perform([.change(anchor, label) { proj in try? body(&proj) }], model, who, draft)
    }

    static func callClass(_ name: String, _ args: [String: Any], model: EditorModel, who: String, draft: MCPDraft?) async throws -> [[String: Any]]? {
        let proj = draft?.project ?? model.project
        switch name {
        case "export_subtitles":
            if draft != nil { throw MCPToolError("export_subtitles isn't available while making a Magic edit.") }
            guard proj.captions != nil else { throw MCPToolError("There are no captions: set_captions first.") }
            guard let path = args["path"] as? String, !path.isEmpty else { throw MCPToolError("path is needed.") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let blocks = CaptionLayout.blocks(proj) { model.media.transcript($0.id) }
            let range = args["range_only"] as? Bool == true ? proj.playRange : nil
            let text: String
            switch args["format"] as? String ?? (url.pathExtension.lowercased() == "txt" ? "text" : "srt") {
            case "text": text = proj.subtitleText(blocks)
            case "text_with_times": text = proj.subtitleText(blocks, times: true)
            default: text = SRT.write(proj.subtitleCues(blocks, range: range))
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
            return out(["file": url.path, "captions": blocks.count, "still_listening": model.captionsWaiting])

        case "import_subtitles":
            let url = try localFile(args, draft)
            guard let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .utf16)) else {
                throw MCPToolError("Couldn't read \(url.lastPathComponent) as text.")
            }
            let cues = SRT.parse(raw)
            guard !cues.isEmpty else { throw MCPToolError("No subtitles found in \(url.lastPathComponent).") }
            let layerName = (args["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
            var placed = 0, missed = 0
            if args["timing"] as? String == "file" {
                guard let id = (args["asset_id"] as? String).flatMap(UUID.init(uuidString:)), proj.asset(id) != nil else {
                    throw MCPToolError("asset_id is needed for timing \"file\".")
                }
                placed = cues.count
                try await change("Subtitles", anchor: nil, model, who, draft) { $0.importSubtitles(file: cues, asset: id, name: layerName) }
            } else {
                var test = proj
                (placed, missed) = test.importSubtitles(timeline: cues, name: layerName)
                guard placed > 0 else { throw MCPToolError("None of the subtitles fell on a clip with sound.") }
                try await change("Subtitles", anchor: nil, model, who, draft) { $0.importSubtitles(timeline: cues, name: layerName) }
            }
            return out(["layer": layerName, "placed": placed, "missed": missed, "shown": true])

        case "list_subtitle_layers":
            return out(["layers": (proj.subtitleLayers ?? []).map { ["name": $0.name, "files": $0.transcripts.count] as [String: Any] },
                        "shown": proj.activeSubtitleLayer?.name ?? "heard", "captions_on": proj.captions != nil])

        case "set_subtitle_layer":
            let want = (args["layer"] as? String ?? "heard").trimmingCharacters(in: .whitespaces)
            guard proj.captions != nil else { throw MCPToolError("There are no captions: set_captions first.") }
            let id: UUID?
            if want.lowercased() == "heard" { id = nil } else {
                guard let l = proj.subtitleLayers?.first(where: { $0.name.lowercased() == want.lowercased() }) else {
                    throw MCPToolError("No layer called \(want). list_subtitle_layers has them.")
                }
                id = l.id
            }
            try await change("Subtitles", anchor: nil, model, who, draft) { $0.showSubtitleLayer(id) }
            return out(["shown": want])

        case "import_dub":
            let url = try localFile(args, draft)
            let duck = num(args["duck_db"]) ?? -24
            let assets: [MediaAsset] = await withCheckedContinuation { c in
                model.importFiles([url], offerMatch: false) { c.resume(returning: $0) }
            }
            guard let a = assets.first, a.hasAudio || a.kind == .audio else { throw MCPToolError("\(url.lastPathComponent) has no sound.") }
            draft?.addAsset(a)
            try await change("Dub", anchor: nil, model, who, draft) { $0.layDub(a, duckDB: duck) }
            return out(["dub": a.name, "length": r3(a.duration)])

        case "transcribe_again":
            let wanted = (args["asset_ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            var n = 0
            for id in wanted { if let u = model.media.soundURL(id) { Transcripts.shared.redo(u); n += 1 } }
            return out(["queued": n])

        case "make_multicam":
            guard let refID = (args["reference_clip_id"] as? String).flatMap(UUID.init(uuidString:)), let ref = proj.clip(refID),
                  let refAsset = proj.asset(ref.assetID) else { throw MCPToolError("reference_clip_id must be a video clip on the timeline.") }
            let others = (args["asset_ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:)).compactMap { proj.asset($0) }
            guard !others.isEmpty else { throw MCPToolError("asset_ids: the other cameras' library items.") }
            let given = (args["sync_offsets"] as? [Any])?.compactMap(num)
            let refLevels = given == nil ? await ActivityScan.activity(refAsset.url, picture: false)?.levels ?? [] : []
            var angles: [AngleGroup.Angle] = []
            var report: [[String: Any]] = [["camera": 1, "name": refAsset.name, "offset": 0]]
            for (k, a) in others.enumerated() {
                var offset = 0.0, how = "given"
                if let g = given, k < g.count { offset = g[k] } else {
                    let levels = await ActivityScan.activity(a.url, picture: false)?.levels ?? []
                    if let f = SoundSync.offset(reference: refLevels, other: levels, step: ActivityScan.levelStep, maxShift: 900) {
                        offset = f.seconds
                        how = f.clarity >= 1.3 ? "by sound" : "by sound (unsure: check with get_frame)"
                    } else { how = "not found: lined up at the start" }
                }
                angles.append(AngleGroup.Angle(assetID: a.id, offset: offset, name: a.name))
                report.append(["camera": k + 2, "name": a.name, "offset": r3(offset), "synced": how])
            }
            try await change("Multi-angle", anchor: refID, model, who, draft) { try $0.makeAngleGroup(reference: refID, angles: angles) }
            return out(["cameras": report, "note": "switch_angle cuts to a camera; set_pip shows one in a corner."])

        case "list_angles":
            return out((proj.angleGroups ?? []).map { g in
                [
                    "cameras": g.angles.enumerated().map { ["camera": $0.offset + 1, "name": $0.element.name, "offset": r3($0.element.offset), "asset_id": $0.element.assetID.uuidString] as [String: Any] },
                    "main_track": proj.mainAngleClips(g.id).map { c in
                        ["clip_id": c.id.uuidString, "start": r3(c.start), "end": r3(c.end), "camera": (g.index(of: c.assetID) ?? 0) + 1] as [String: Any]
                    },
                ] as [String: Any]
            })

        case "switch_angle":
            guard let t = num(args["time"]), let cam = args["camera"] as? Int else { throw MCPToolError("time and camera are needed.") }
            let groups = proj.angleGroups ?? []
            guard let g = groups.first(where: { g in proj.mainAngleClips(g.id).contains { $0.start - 1e-6 <= t && t < $0.end } }) ?? groups.first else {
                throw MCPToolError("There's no multi-angle group: make_multicam first.")
            }
            guard g.angles.indices.contains(cam - 1) else { throw MCPToolError("Camera is 1...\(g.angles.count).") }
            try await change("Camera \(cam)", anchor: nil, model, who, draft) { try $0.switchAngle(group: g.id, to: cam - 1, at: t) }
            return out(["camera": cam, "from": r3(t)])

        case "set_pip":
            guard let cam = args["camera"] as? Int else { throw MCPToolError("camera is needed.") }
            var targets = (args["clip_ids"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
            if targets.isEmpty, let t = num(args["time"]) {
                targets = (proj.angleGroups ?? []).flatMap { proj.mainAngleClips($0.id) }.filter { $0.start <= t && t < $0.end }.map(\.id)
            }
            let corner = (args["corner"] as? String).flatMap(PictureCorner.init(rawValue:)) ?? .bottomRight
            let scale = (num(args["scale"]) ?? 0.32).clamped(to: 0.15...0.5)
            try await change("Picture in picture", anchor: targets.first, model, who, draft) {
                _ = try $0.addPictureInPicture(angle: cam - 1, over: targets, corner: corner, scale: scale)
            }
            let after = draft?.project ?? model.project
            let made = after.clips.filter { $0.angleGroup != nil && $0.transform?.scale == scale && !proj.clips.map(\.id).contains($0.id) }
            return out(["pip_clip_ids": made.map(\.id.uuidString)])

        case "remove_dead_air":
            let kind = (args["kind"] as? String).flatMap(DeadAirKind.init(rawValue:)) ?? .quietAndStill
            let minLength = max(1, num(args["min_length"]) ?? 5)
            let lo = num(args["start"]), hi = num(args["end"])
            let range: (start: Double, end: Double)? = lo != nil || hi != nil ? (start: lo ?? 0, end: hi ?? proj.duration) : nil
            let acts = await model.activities(for: proj.clips, picture: kind != .quiet)
            let ranges = proj.deadRanges(kind, activity: { acts[$0] }, minLength: minLength, sensitivity: (num(args["sensitivity"]) ?? 0.5).clamped(to: 0...1), range: range)
            let list = ranges.map { ["start": r3($0.start), "end": r3($0.end)] }
            let total = r3(ranges.reduce(0) { $0 + $1.end - $1.start })
            if args["dry_run"] as? Bool == true || ranges.isEmpty { return out(["stretches": list, "total_seconds": total, "changed": false]) }
            if args["action"] as? String == "speed" {
                let sp = (num(args["speed"]) ?? 8).clamped(to: 1.1...100)
                try await change("Speed up dead air", anchor: nil, model, who, draft) { $0.speedUp(ranges, by: sp) }
            } else {
                try await change("Cut dead air", anchor: nil, model, who, draft) { $0.cut(ranges) }
            }
            return out(["stretches": list, "total_seconds": total, "changed": true])

        case "speed_up_range":
            guard let a = num(args["start"]), let sp = num(args["speed"]) else { throw MCPToolError("start and speed are needed.") }
            let e = num(args["end"]) ?? proj.duration
            guard e - a > 1 / proj.fps else { throw MCPToolError("end must be after start.") }
            let speed = sp.clamped(to: 1.1...100), mute = args["mute_sound"] as? Bool ?? true
            if args["only_quiet"] as? Bool == true {
                let acts = await model.activities(for: proj.clips, picture: false)
                let quiet = proj.deadRanges(.quiet, activity: { acts[$0] }, minLength: max(1, num(args["min_quiet"]) ?? 3), pad: 0.3, range: (start: a, end: e))
                guard !quiet.isEmpty else { return out(["sped_up": [String](), "note": "Someone talks all through it; nothing changed."]) }
                try await change("Timelapse", anchor: nil, model, who, draft) { $0.speedUp(quiet, by: speed, muteSound: mute) }
                return out(["sped_up": quiet.map { ["start": r3($0.start), "end": r3($0.end)] }])
            }
            try await change("Timelapse", anchor: nil, model, who, draft) { $0.speedUp(from: a, to: e, by: speed, muteSound: mute) }
            return out(["sped_up": [["start": r3(a), "end": r3(e)]]])

        default:
            return nil
        }
    }
}
