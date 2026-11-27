import AppKit
import Foundation

/// Runs a lesson through the translator in OpenClaw-Artist-Management (its PIPELINE.md), from this edit:
/// the Chinese goes out of the timeline, Claude Code cleans it up and translates it by the translator's own
/// CLAUDE.md, `srt_dubber` makes the English voice, `retime_to_words.py` times both subtitle files to the
/// voice, and everything comes back onto the timeline. Maya's three checks (gates A, B and C) happen here in
/// Editroom: she fixes the Chinese and the English in the subtitle list, and listens to the audition on the
/// timeline, before the next (paid) step runs.
///
/// Uses a copy of the translator on this Mac (Settings: found by itself, or chosen), the `claude` program
/// signed in to Maya's plan, and Python 3.10+. ElevenLabs' key is read from the translator's own `.env`.
@MainActor
final class DubPipeline: ObservableObject {
    static let shared = DubPipeline()

    /// What's running now, for the panel; nil when idle.
    @Published private(set) var running: String?
    @Published private(set) var log = ""
    @Published var problem: String?
    /// Something to offer when a step stopped short: Claude can fix these lines and go again.
    @Published private(set) var fixable: String?
    private var process: Process?
    private var stopped = false

    // MARK: Finding the tools

    static let folderKey = "translatorFolder"

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    private static func isTranslator(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("srt_dubber/__main__.py").path)
            && fm.fileExists(atPath: url.appendingPathComponent("CLAUDE.md").path)
    }

    /// The translator folder: the one chosen, else a copy of OpenClaw-Artist-Management in a usual place.
    static var translatorFolder: URL? {
        if let p = UserDefaults.standard.string(forKey: folderKey), !p.isEmpty {
            let u = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            let t = isTranslator(u) ? u : u.appendingPathComponent("translator")
            return isTranslator(t) ? t : nil
        }
        let parents = ["", "Documents", "Developer", "Projects", "code", "Code", "src", "GitHub", "Documents/GitHub", "Desktop"]
        for parent in parents {
            for repo in ["OpenClaw-Artist-Management", "openclaw-artist-management"] {
                let u = URL(fileURLWithPath: home).appendingPathComponent(parent).appendingPathComponent(repo).appendingPathComponent("translator")
                if isTranslator(u) { return u }
            }
        }
        return nil
    }

    /// Python 3.10 or later (the translator needs it; the Mac's own /usr/bin/python3 is often older).
    static var python: URL? {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "\(home)/.pyenv/shims/python3",
                          "\(home)/miniconda3/bin/python3", "\(home)/anaconda3/bin/python3", "\(home)/miniforge3/bin/python3",
                          "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3.11",
                          "/usr/bin/python3"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: c)
            p.arguments = ["-c", "import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            if p.terminationStatus == 0 { return URL(fileURLWithPath: c) }
        }
        return nil
    }

    /// What's missing to run the pipeline, in plain words; empty when all's there.
    func missing() -> [String] {
        var out: [String] = []
        if Self.translatorFolder == nil {
            out.append("The translator: a copy of OpenClaw-Artist-Management on this Mac (choose its folder below).")
        }
        if AgentConnect.shared.claudeCLI == nil { out.append("Claude Code (the `claude` program), signed in to your Claude plan.") }
        if Self.python == nil { out.append("Python 3.10 or later: brew install python") }
        return out
    }

    // MARK: Running things

    private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
        env["PYTHONIOENCODING"] = "utf-8"
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// Runs a program in the translator folder to the end, showing what it prints. Returns its exit status
    /// and output (the last 200 000 characters).
    private func run(_ title: String, _ program: URL, _ args: [String], input: String? = nil) async -> (Int32, String) {
        guard let folder = Self.translatorFolder else { return (-1, "No translator folder.") }
        running = title
        log += "\n▶ \(title)\n"
        defer { running = nil; process = nil }
        let p = Process()
        p.executableURL = program
        p.arguments = args
        p.currentDirectoryURL = folder
        p.environment = Self.environment
        let out = Pipe(), inPipe = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
        let collected = OutputBox()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            collected.add(d)
            let s = String(decoding: d, as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                self.log += s
                if self.log.count > 60_000 { self.log = String(self.log.suffix(40_000)) }
            }
        }
        process = p
        let writer = inPipe.fileHandleForWriting
        let status: Int32 = await withCheckedContinuation { c in
            p.terminationHandler = { proc in c.resume(returning: proc.terminationStatus) }
            do {
                try p.run()
                if let input {
                    writer.write(Data(input.utf8))
                    try? writer.close()
                }
            } catch {
                p.terminationHandler = nil
                collected.add(Data("Couldn't start \(program.lastPathComponent): \(error.localizedDescription)".utf8))
                c.resume(returning: -1)
            }
        }
        // The last of the output lands.
        try? await Task.sleep(nanoseconds: 200_000_000)
        return (status, collected.text)
    }

    /// Claude Code in the translator folder, following its CLAUDE.md, with the tools translate.sh gives it.
    /// Returns its final message, or nil (with `problem` set) if it failed.
    private func claude(_ title: String, _ prompt: String) async -> String? {
        guard let cli = AgentConnect.shared.claudeCLI else { problem = "Claude Code isn't installed."; return nil }
        let (status, out) = await run(title, cli, ["-p", "--output-format", "json", "--max-turns", "120",
                                                   "--allowedTools", "Read,Write,Edit,Glob,Grep,Bash"], input: prompt)
        // The JSON result is the last line that parses.
        let result = out.split(separator: "\n").reversed().lazy.compactMap { line -> [String: Any]? in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }.first
        if status != 0 || result?["is_error"] as? Bool == true {
            if !stopped {
                problem = (result?["result"] as? String) ?? "Claude Code stopped (\(status)). If it isn't signed in, run `claude` in Terminal once and sign in."
            }
            return nil
        }
        return (result?["result"] as? String) ?? out
    }

    private func python(_ title: String, _ args: [String]) async -> (Int32, String) {
        guard let py = Self.python else { return (-1, "Python 3.10 or later isn't installed.") }
        return await run(title, py, args)
    }

    func stop() {
        stopped = true
        if process?.isRunning == true { process?.terminate() }
    }

    // MARK: Files

    private func url(_ path: String) -> URL? { Self.translatorFolder?.appendingPathComponent(path) }

    private func read(_ path: String) -> [SRTCue]? {
        guard let u = url(path), let s = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        let cues = SRT.parse(s)
        return cues.isEmpty ? nil : cues
    }

    private func write(_ cues: [SRTCue], to path: String) throws {
        guard let u = url(path) else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SRT.write(cues).write(to: u, atomically: true, encoding: .utf8)
    }

    /// The cues a layer shows now (nil: what's heard), timed exactly as its lines are.
    private func layerCues(_ model: EditorModel, layer: UUID?) -> [SRTCue] {
        var q = model.project
        q.showSubtitleLayer(layer)
        return q.exactCues(CaptionLayout.blocks(q) { model.media.transcript($0.id) })
    }

    /// A file from the translator as a layer on the caption track (replacing one of the same name), shown.
    @discardableResult
    private func bringIn(_ model: EditorModel, _ path: String, as name: String) -> Bool {
        guard let cues = read(path) else { problem = "Couldn't find \(path) in the translator folder."; return false }
        var placed = 0
        model.mutate { p in placed = p.importSubtitles(timeline: cues, name: name).placed }
        if placed == 0 { problem = "None of \(path)'s subtitles fell on a clip with sound." }
        return placed > 0
    }

    private func setJob(_ model: EditorModel, _ change: (inout DubJob) -> Void) {
        model.mutate { p in if p.dubJob != nil { change(&p.dubJob!) } }
    }

    /// The edit has changed since the Chinese was sent: the dub would fall out of step with it.
    func cutChanged(_ model: EditorModel) -> Bool {
        guard let job = model.project.dubJob else { return false }
        return DubPlan.cutStamp(model.project) != job.cutStamp
    }

    // MARK: The steps

    /// Whatever the lesson's next step is. `approve` is Maya's yes at a gate.
    func next(_ model: EditorModel) async {
        problem = nil
        fixable = nil
        stopped = false
        guard missing().isEmpty else { problem = missing().joined(separator: "\n"); return }
        guard let job = model.project.dubJob else { return await send(model) }
        switch job.stage {
        case .send: await send(model)
        case .cleanup: await cleanup(model, job)
        case .reviewCleanup: await approveCleanup(model, job)
        case .translate: await translate(model, job)
        case .reviewTranslation: await approveTranslation(model, job)
        case .audition: await audition(model, job)
        case .reviewAudition: setJob(model) { $0.stage = .dub }; await dub(model, model.project.dubJob!)
        case .dub: await dub(model, job)
        case .retime: await retime(model, job)
        case .deliver: await deliver(model, job)
        case .done: break
        }
    }

    /// Starts again from the Chinese now on the timeline (after the edit changed).
    func restart(_ model: EditorModel) async {
        model.mutate { $0.dubJob = nil }
        await next(model)
    }

    /// 1. The Chinese captions, as they show, timed to this edit, to translator/input/.
    func send(_ model: EditorModel) async {
        guard model.project.captions != nil else {
            problem = "Add captions first (Clip › Add Captions) so there's Chinese to send. Or import Maya's Chinese SRT (Subtitles › Import Subtitles)."
            return
        }
        guard !model.captionsWaiting else { problem = "Still listening to some clips. Wait until their captions appear."; return }
        // Send what's heard, unless a Chinese layer of Maya's own is showing.
        let shown = model.project.activeSubtitleLayer
        let layer = shown.map { SubtitleText.hasCJK($0.transcripts.values.first?.text ?? "") ? $0.id : nil } ?? nil
        let cues = layerCues(model, layer: layer)
        guard !cues.isEmpty else { problem = "There are no captions to send."; return }
        let name = DubPlan.inputName(title: model.title)
        var stem = DubPlan.fallbackStem(name)
        let (status, out) = await python("Name", ["-m", "srt_translator.naming", name, "--stem"])
        if status == 0, let line = out.split(separator: "\n").last.map(String.init), !line.isEmpty { stem = line.trimmingCharacters(in: .whitespaces) }
        if let u = url("input/\(name)"), FileManager.default.fileExists(atPath: u.path) {
            let a = EditroomAlert()
            a.messageText = "input/\(name) is already in the translator"
            a.informativeText = "Replace it with the Chinese from this edit? Its cleaned and translated files stay until the new ones are made."
            a.addButton(withTitle: "Replace")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        do { try write(cues, to: "input/\(name)") } catch { problem = "Couldn't write to the translator: \(error.localizedDescription)"; return }
        log += "\nSent \(cues.count) Chinese subtitles to input/\(name)\n"
        let job = DubJob(name: name, stem: stem, stage: .cleanup, cutStamp: DubPlan.cutStamp(model.project))
        model.mutate { $0.dubJob = job }
        await cleanup(model, job)
    }

    /// 2. Job 0 by the translator's CLAUDE.md, then the cleaned Chinese onto the caption track for Maya.
    private func cleanup(_ model: EditorModel, _ job: DubJob) async {
        let prompt = """
        A lesson from Editroom, Maya's video editor: input/\(job.name) was exported from her finished edit, so its \
        timings match the video cut exactly. Do Job 0 only (SRT Cleanup), following CLAUDE.md exactly: read the \
        glossary, corrections and guides, then write input/\(job.clean). Do NOT translate and do NOT commit: Maya \
        checks and edits the cleaned Chinese in Editroom next (this is GATE A, and Editroom asks her). \
        End your reply with the report for Maya in Chinese: raw count, cleaned count, % reduction, what was merged \
        and dropped, and how many [待确认] flags.
        """
        guard let report = await claude("Cleaning up the Chinese (Job 0)", prompt) else { return }
        guard bringIn(model, "input/\(job.clean)", as: DubPlan.cleanLayer) else { return }
        setJob(model) { $0.stage = .reviewCleanup; $0.lastReport = report }
    }

    /// Gate A passed: Maya's edits to the cleaned Chinese go back to the translator (hers win).
    private func approveCleanup(_ model: EditorModel, _ job: DubJob) async {
        guard let layer = model.project.layer(named: DubPlan.cleanLayer) else { problem = "The cleaned Chinese isn't on the caption track any more."; return }
        let now = layerCues(model, layer: layer.id)
        let before = read("input/\(job.clean)") ?? []
        let edited = !DubPlan.edits(delivered: before, now: now).isEmpty
        if edited {
            do { try write(now, to: "input/\(job.clean)") } catch { problem = error.localizedDescription; return }
            log += "\nMaya's edits saved to input/\(job.clean)\n"
        }
        setJob(model) { $0.stage = .translate }
        await translate(model, model.project.dubJob!, mayaEdited: edited)
    }

    /// 3. Job 1 by CLAUDE.md, then the English onto the caption track to read through.
    private func translate(_ model: EditorModel, _ job: DubJob, mayaEdited: Bool = false) async {
        let prompt = """
        A lesson from Editroom, Maya's video editor. Maya approved the cleaned Chinese in input/\(job.clean) in \
        Editroom (GATE A passed)\(mayaEdited ? ", and edited it there herself: her wording and cuts win, mirror them" : ""). \
        Do Job 1 following CLAUDE.md exactly: translate it, keep the JSON batches in \(job.dubFolder)/translations/ \
        as well (later fixes regenerate from them), assemble output/\(job.enRaw) and output/\(job.en) with the \
        assembly snippet, run the Step 6 self-audit (zero dashes, one thought per entry, write for the ear because \
        this lesson will be dubbed, see DUBBING.md "Maya's standing dub rules"), and update the glossary and \
        corrections journal. Do not dub; Editroom runs the dub after Maya reads the English (GATE B). \
        Then follow CLAUDE.md's DELIVERY RULE for the subtitles. End with a short report: entry count, anything \
        flagged for Maya (Patreon reframings, [待确认]), and whether the files reached main.
        """
        guard let report = await claude("Translating (Job 1)", prompt) else { return }
        guard bringIn(model, "output/\(job.en)", as: DubPlan.englishLayer) else { return }
        let delivered = read("output/\(job.en)") ?? []
        setJob(model) { $0.stage = .reviewTranslation; $0.lastReport = report; $0.deliveredEnglish = delivered.map(\.saved) }
    }

    /// Gate B passed. Lines Maya changed go back to Claude, who fixes the translation itself (never the SRT by
    /// hand, per CLAUDE.md), then the audition runs.
    private func approveTranslation(_ model: EditorModel, _ job: DubJob) async {
        if let layer = model.project.layer(named: DubPlan.englishLayer), let delivered = job.deliveredEnglish {
            let changes = DubPlan.edits(delivered: delivered.map { SRTCue(start: $0.start, end: $0.end, text: $0.text) },
                                        now: layerCues(model, layer: layer.id))
            if !changes.isEmpty {
                let list = changes.map { e in
                    "- at \(SRT.timestamp(e.start)): \"\(e.before)\" → " + (e.after.isEmpty ? "(removed)" : "\"\(e.after)\"")
                }.joined(separator: "\n")
                let prompt = """
                Maya read output/\(job.en) in Editroom and changed these English subtitles (time, before → after):
                \(list)
                Apply each change to the translation itself: the JSON batches in \(job.dubFolder)/translations/ (or \
                /tmp), then regenerate output/\(job.enRaw) and output/\(job.en) with the assembly snippet, so the \
                subtitles and the dub say the same thing. Keep every CLAUDE.md rule (no dashes, one thought per \
                entry). Then follow the DELIVERY RULE. Reply with one line per change saying what you did.
                """
                guard let report = await claude("Applying Maya's English changes", prompt) else { return }
                guard bringIn(model, "output/\(job.en)", as: DubPlan.englishLayer) else { return }
                let delivered = read("output/\(job.en)") ?? []
                setJob(model) { $0.lastReport = report; $0.deliveredEnglish = delivered.map(\.saved) }
            }
        }
        setJob(model) { $0.stage = .audition }
        await audition(model, model.project.dubJob!)
    }

    /// 4. The first lines voiced, laid on the timeline under the edit for Maya to hear (gate C). Shares its cache
    /// with the full dub, so nothing auditioned is paid for twice.
    private func audition(_ model: EditorModel, _ job: DubJob) async {
        guard await dubber(model, job, ["output/\(job.en)", "--limit", "12", "-o", job.auditionFolder, "--cache-dir", "\(job.dubFolder)/cache"],
                           title: "Auditioning the first lines") else { return }
        guard let wav = newestDub(in: job.auditionFolder) else { problem = "The audition made no sound file."; return }
        layDub(model, wav)
        setJob(model) { $0.stage = .reviewAudition; $0.lastReport = report(job.auditionFolder) }
    }

    /// 5. The whole lesson. Lines too long for their time go back to Claude to shorten (the translator loop).
    private func dub(_ model: EditorModel, _ job: DubJob) async {
        if cutChanged(model) {
            let a = EditroomAlert()
            a.messageText = "The edit changed since the Chinese was sent"
            a.informativeText = "The dub is timed to the edit as it was then, so it won't line up with this one. Dub anyway, or start again from the new edit?"
            a.addButton(withTitle: "Start Again")
            a.addButton(withTitle: "Dub Anyway")
            a.addButton(withTitle: "Cancel")
            switch a.runModal() {
            case .alertFirstButtonReturn: return await restart(model)
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        // The SRT the dub is planned from, kept for re-timing and any later --redo (DUBBING.md rule 4).
        if let from = url("output/\(job.en)"), let to = url(job.dubsource) {
            try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: to)
            try? FileManager.default.copyItem(at: from, to: to)
        }
        guard await dubber(model, job, ["output/\(job.en)", "--mp3"], title: "Dubbing the whole lesson") else { return }
        // The translator loop: lines that can't fit at any speed.
        if let short = shortenCount(job), short > 0 {
            fixable = "\(short) line\(short == 1 ? " is" : "s are") too long to say in time. Claude can shorten \(short == 1 ? "it" : "them") (keeping every instruction) and dub again; only those lines are paid for again."
            setJob(model) { $0.lastReport = report(job.dubFolder) }
            return
        }
        guard let wav = newestDub(in: job.dubFolder) else { problem = "The dub made no sound file."; return }
        layDub(model, wav)
        setJob(model) { $0.stage = .retime; $0.lastReport = report(job.dubFolder) }
        await retime(model, model.project.dubJob!)
    }

    /// Runs srt_dubber. A stop from its fragment check is offered to Claude to fix.
    private func dubber(_ model: EditorModel, _ job: DubJob, _ args: [String], title: String) async -> Bool {
        let (status, out) = await python(title, ["-m", "srt_dubber"] + args)
        guard status == 0 else {
            if stopped { return false }
            if out.localizedCaseInsensitiveContains("fragment") {
                fixable = "The dubber stopped on lines that would sound broken spoken aloud (a sentence cut in two). Claude can rejoin them per DUBBING.md, then try again."
            } else {
                problem = "The dubber stopped:\n" + String(out.suffix(1500))
            }
            return false
        }
        return true
    }

    /// Claude fixes what the last step stopped on (broken fragments, lines too long), then that step runs again.
    func fixAndRetry(_ model: EditorModel) async {
        guard let job = model.project.dubJob, fixable != nil else { return }
        fixable = nil
        problem = nil
        let tail = String(log.suffix(6000))
        let prompt = """
        Editroom is dubbing \(job.stem) and the dubber stopped. Its output ends:
        \(tail)
        If it flagged fragments, rejoin each flagged cue into one connected sentence (DUBBING.md, "Dubbing exposes \
        translation problems that subtitles hide"). If \(job.dubFolder)/shorten.json lists lines, shorten each to about \
        its target_chars keeping every instruction (DUBBING.md 3b). Fix the translation itself (the JSON batches in \
        \(job.dubFolder)/translations/ or /tmp) and regenerate output/\(job.enRaw) and output/\(job.en) with the \
        assembly snippet, so subtitles and voice match. Don't run the dubber; Editroom runs it again. Reply with one \
        line per change.
        """
        guard let report = await claude("Fixing lines for the dub", prompt) else { return }
        bringIn(model, "output/\(job.en)", as: DubPlan.englishLayer)
        setJob(model) { $0.lastReport = report }
        await next(model)
    }

    /// 6. Both subtitle files timed to the words the voice says, Chinese cue for cue (Maya's rule 4), and onto
    /// the timeline in place of the earlier ones.
    private func retime(_ model: EditorModel, _ job: DubJob) async {
        guard let wav = newestDub(in: job.dubFolder) else { problem = "There's no dub to time the subtitles to."; return }
        let rel = wav.path.replacingOccurrences(of: (Self.translatorFolder?.path ?? "") + "/", with: "")
        // Word timings: the translator's own script (faster-whisper), else Whisper on this Mac.
        var (status, _) = await python("Hearing the voice's words", ["-I", "scripts/dub_words.py", rel, job.words])
        if status != 0 {
            guard await wordsFromWhisper(wav, to: job.words) else {
                problem = "Couldn't hear the dub's words. Install faster-whisper (pip3 install faster-whisper, and brew install ffmpeg) or Whisper (Settings › Subtitles)."
                return
            }
        }
        let zhTemp = FileManager.default.temporaryDirectory.appendingPathComponent("editroom-\(UUID().uuidString)_zh.srt")
        defer { try? FileManager.default.removeItem(at: zhTemp) }
        guard let clean = url("input/\(job.clean)") else { return }
        try? FileManager.default.copyItem(at: clean, to: zhTemp)
        (status, _) = await python("Timing subtitles to the voice",
                                   ["-I", "scripts/retime_to_words.py", ".", job.dubFolder, job.words, "output/\(job.enRaw)",
                                    "output/\(job.en)", zhTemp.path, job.dubsource])
        guard status == 0 else { if !stopped { problem = "Re-timing stopped. See the log." }; return }
        if let out = url("output/\(job.zh)") {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.copyItem(at: zhTemp, to: out)
        }
        bringIn(model, "output/\(job.zh)", as: DubPlan.chineseLayer)
        bringIn(model, "output/\(job.en)", as: DubPlan.englishLayer)
        if let clean = model.project.layer(named: DubPlan.cleanLayer) { model.removeSubtitleLayer(clean.id) }
        setJob(model) { $0.stage = .deliver }
    }

    /// 7. The 交付 folder, and everything onto main, by the translator's delivery rules.
    private func deliver(_ model: EditorModel, _ job: DubJob) async {
        let prompt = """
        Editroom has finished dubbing \(job.stem): output/\(job.en) and output/\(job.zh) are timed to the voice \
        (DUBBING.md rule 4 is done), and the dub is in \(job.dubFolder)/. Deliver it following CLAUDE.md and \
        DUBBING.md: the 交付/\(job.stem)/ folder with the English and Chinese subtitles, the narration (WAV, or the MP3 \
        when the WAV is over 100 MB, rule 5) and a zip; force-add what the delivery rules say to (the dubsource SRT \
        and words.json too); merge to main. Reply with what was delivered and whether it reached main.
        """
        guard let report = await claude("Delivering", prompt) else { return }
        setJob(model) { $0.stage = .done; $0.lastReport = report }
    }

    // MARK: Helpers

    private func newestDub(in folder: String) -> URL? {
        guard let dir = url(folder) else { return nil }
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "wav" && $0.lastPathComponent.contains("_dub") && !$0.lastPathComponent.contains("partial") }
        return files.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
    }

    private func report(_ folder: String) -> String? {
        url("\(folder)/report.md").flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map { String($0.prefix(4000)) }
    }

    private func shortenCount(_ job: DubJob) -> Int? {
        guard let u = url("\(job.dubFolder)/shorten.json"), let d = try? Data(contentsOf: u),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return (j["lines"] as? [Any])?.count
    }

    /// The dub on the timeline from 0, the camera sound turned down under it; an earlier dub of this lesson goes.
    private func layDub(_ model: EditorModel, _ wav: URL) {
        let old = Set(model.project.assets.filter { $0.path.contains("/dub/") && $0.path.hasSuffix("_dub.wav") && $0.path.contains(model.project.dubJob?.stem ?? "\u{0}") }.map(\.id))
        model.mutate { p in
            let gone = Set(p.clips.filter { old.contains($0.assetID ?? UUID()) }.map(\.trackID))
            p.clips.removeAll { old.contains($0.assetID ?? UUID()) }
            for t in gone where !p.clips.contains(where: { $0.trackID == t }) { p.removeTrack(t) }
            for i in p.audioTracks.indices where p.audioTracks[i].duckUnder.map(gone.contains) == true { p.audioTracks[i].duckUnder = nil }
        }
        model.importDub(wav)
    }

    /// words.json (as dub_words.py writes it) from Whisper on this Mac, when faster-whisper isn't installed.
    private func wordsFromWhisper(_ wav: URL, to path: String) async -> Bool {
        guard let install = Whisper.find(), let out = url(path) else { return false }
        running = "Hearing the voice's words (Whisper)"
        defer { running = nil }
        guard let t = await Whisper.transcribe(wav, with: install, language: "en") else { return false }
        let words = t.words.map { ["w": " " + $0.text, "s": Int($0.start * 1000), "e": Int($0.end * 1000)] as [String: Any] }
        guard let d = try? JSONSerialization.data(withJSONObject: words) else { return false }
        return (try? d.write(to: out)) != nil
    }
}

/// Output gathered from a program as it runs.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func add(_ d: Data) { lock.lock(); data.append(d); if data.count > 400_000 { data = data.suffix(200_000) }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
