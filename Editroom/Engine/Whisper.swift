import AVFoundation
import Foundation

/// Hearing what's said with Whisper, when it's installed on this Mac: works on any macOS version Editroom
/// runs on (Apple's own speech recognition needs macOS 26), and hears Chinese well. Uses whichever Whisper
/// is there, fastest first: mlx-whisper (Apple silicon), whisper.cpp (`whisper-cli`, from Homebrew), or
/// OpenAI's `whisper`. Everything runs on this Mac; the sound is never sent anywhere.
enum Whisper {
    enum Kind: String {
        case mlx, cpp, python
        var label: String {
            switch self {
            case .mlx: "mlx-whisper"
            case .cpp: "whisper.cpp"
            case .python: "OpenAI Whisper"
            }
        }
    }

    struct Install {
        var kind: Kind
        var program: URL
        /// whisper.cpp's model file.
        var model: URL?
    }

    // MARK: Settings (Settings › Subtitles)

    /// "auto" (Whisper when it's installed, else Apple's), "whisper" or "apple".
    static var engineChoice: String { UserDefaults.standard.string(forKey: "transcriber") ?? "auto" }
    /// "auto", "zh" or "en", or any language code Whisper knows.
    static var language: String { UserDefaults.standard.string(forKey: "transcriptLanguage") ?? "auto" }
    /// A program chosen by hand (any of the three), and a model name or file.
    static var customProgram: String? { UserDefaults.standard.string(forKey: "whisperProgram").flatMap { $0.isEmpty ? nil : $0 } }
    static var customModel: String? { UserDefaults.standard.string(forKey: "whisperModel").flatMap { $0.isEmpty ? nil : $0 } }

    // MARK: Finding it

    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// Where people's command-line programs usually are, including Python's.
    private static var binFolders: [String] {
        var dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/miniconda3/bin", "\(home)/anaconda3/bin",
                    "\(home)/miniforge3/bin", "\(home)/.pyenv/shims", "\(home)/bin"]
        let py = "\(home)/Library/Python"
        for v in ((try? FileManager.default.contentsOfDirectory(atPath: py)) ?? []).sorted(by: >) { dirs.append("\(py)/\(v)/bin") }
        return dirs
    }

    private static func kind(of program: URL) -> Kind {
        let n = program.lastPathComponent.lowercased()
        if n.contains("mlx") { return .mlx }
        if n.contains("cli") || n.contains("cpp") || n == "main" { return .cpp }
        return .python
    }

    /// The Whisper to use, if one is installed.
    static func find() -> Install? {
        let fm = FileManager.default
        if let p = customProgram {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            guard fm.isExecutableFile(atPath: url.path) else { return nil }
            let k = kind(of: url)
            return Install(kind: k, program: url, model: k == .cpp ? cppModel() : nil)
        }
        for (name, k) in [("mlx_whisper", Kind.mlx), ("whisper-cli", .cpp), ("whisper-cpp", .cpp), ("whisper", .python)] {
            for dir in binFolders {
                let path = "\(dir)/\(name)"
                guard fm.isExecutableFile(atPath: path) else { continue }
                if k == .cpp {
                    guard let m = cppModel() else { continue }
                    return Install(kind: k, program: URL(fileURLWithPath: path), model: m)
                }
                return Install(kind: k, program: URL(fileURLWithPath: path), model: nil)
            }
        }
        return nil
    }

    /// A whisper.cpp model (ggml-*.bin): the one chosen, else the best one found in the usual places.
    static func cppModel() -> URL? {
        let fm = FileManager.default
        if let m = customModel, m.hasSuffix(".bin") {
            let p = (m as NSString).expandingTildeInPath
            return fm.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
        }
        let dirs = ["\(home)/Library/Application Support/Editroom/Whisper", "\(home)/whisper.cpp/models", "\(home)/.cache/whisper",
                    "\(home)/.cache/whisper.cpp", "/opt/homebrew/share/whisper-cpp", "/opt/homebrew/share/whisper.cpp/models",
                    "/usr/local/share/whisper-cpp", "\(home)/models", "\(home)/Downloads"]
        var found: [URL] = []
        for d in dirs {
            for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.hasPrefix("ggml-") && f.hasSuffix(".bin") {
                found.append(URL(fileURLWithPath: d).appendingPathComponent(f))
            }
        }
        let rank = ["large-v3-turbo", "large-v3", "large-v2", "large", "medium", "small", "base", "tiny"]
        func score(_ u: URL) -> Int {
            let n = u.lastPathComponent
            // English-only models (".en") can't hear Chinese.
            let penalty = n.contains(".en") ? 100 : 0
            return (rank.firstIndex { n.contains($0) } ?? rank.count) + penalty
        }
        return found.min { score($0) < score($1) }
    }

    /// Whisper is the one to use for new transcripts.
    static var inUse: Install? {
        engineChoice == "apple" ? nil : find()
    }

    // MARK: Hearing

    /// Every word in the file's sound, with its time. Nil if Whisper couldn't run.
    static func transcribe(_ url: URL, with install: Install) async -> Transcript? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("editroom-whisper-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let wav = work.appendingPathComponent("audio.wav")
        guard await writeWAV(from: url, to: wav) else { return Transcript(words: [], language: "") }

        let lang = language
        let zh = lang == "zh" || lang.hasPrefix("zh")
        // Asked for in Simplified Chinese, the way Whisper is nudged into writing it.
        let prompt = zh ? "以下是普通话的句子，使用简体中文。" : nil
        var args: [String]
        switch install.kind {
        case .mlx:
            args = [wav.path, "--model", customModel ?? "mlx-community/whisper-large-v3-turbo", "--output-format", "json",
                    "--output-dir", work.path, "--word-timestamps", "True", "--verbose", "False"]
            if lang != "auto" { args += ["--language", lang] }
            if let prompt { args += ["--initial-prompt", prompt] }
        case .python:
            args = [wav.path, "--model", customModel ?? "turbo", "--output_format", "json", "--output_dir", work.path,
                    "--word_timestamps", "True", "--verbose", "False", "--fp16", "False"]
            if lang != "auto" { args += ["--language", lang] }
            if let prompt { args += ["--initial_prompt", prompt] }
        case .cpp:
            guard let model = install.model else { return nil }
            args = ["-m", model.path, "-f", wav.path, "-oj", "-of", work.appendingPathComponent("out").path, "-np",
                    "-ml", "60", "-sow", "-l", lang == "auto" ? "auto" : lang]
            if let prompt { args += ["--prompt", prompt] }
        }
        let ok = await run(install.program, args)
        guard ok else { return nil }
        let json = ((try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? []).first { $0.pathExtension == "json" }
        guard let json, let data = try? Data(contentsOf: json) else { return nil }
        return parse(data, kind: install.kind, language: lang)
    }

    /// Reads Whisper's JSON: OpenAI's and mlx's (segments with words), or whisper.cpp's (segments).
    static func parse(_ data: Data, kind: Kind, language: String) -> Transcript? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var words: [Transcript.Word] = []
        if let segments = root["segments"] as? [[String: Any]] {
            for seg in segments {
                let s0 = number(seg["start"]) ?? 0, s1 = number(seg["end"]) ?? s0
                if let ws = seg["words"] as? [[String: Any]], !ws.isEmpty {
                    for w in ws {
                        let text = (w["word"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty, let a = number(w["start"]), let b = number(w["end"]) else { continue }
                        words.append(Transcript.Word(start: a, end: max(b, a + 0.02), text: text))
                    }
                } else if let text = seg["text"] as? String {
                    words += heard(text, s0, s1)
                }
            }
        } else if let segments = root["transcription"] as? [[String: Any]] {
            for seg in segments {
                guard let text = seg["text"] as? String, let off = seg["offsets"] as? [String: Any],
                      let a = number(off["from"]), let b = number(off["to"]) else { continue }
                words += heard(text, a / 1000, b / 1000)
            }
        } else {
            return nil
        }
        let lang = (root["language"] as? String) ?? ((root["result"] as? [String: Any])?["language"] as? String) ?? language
        return Transcript(words: words.sorted { $0.start < $1.start }, language: lang)
    }

    /// A segment's words spread over its time (no line breaks of their own: captions are laid out as usual).
    private static func heard(_ text: String, _ a: Double, _ b: Double) -> [Transcript.Word] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // whisper.cpp marks silence and music like this.
        guard !t.isEmpty, !(t.hasPrefix("[") && t.hasSuffix("]")), !(t.hasPrefix("(") && t.hasSuffix(")")) else { return [] }
        return Transcript.words(for: t, from: a, to: max(b, a + 0.1)).map { var w = $0; w.cue = nil; return w }
    }

    private static func number(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) ?? (v as? NSNumber)?.doubleValue }

    /// Runs Whisper to the end, with the usual places for its helpers (ffmpeg) on the PATH.
    private static func run(_ program: URL, _ args: [String]) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let p = Process()
            p.executableURL = program
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = binFolders.joined(separator: ":") + ":/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
            env["PYTHONIOENCODING"] = "utf-8"
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            let err = Pipe()
            p.standardError = err
            // Read as it comes (Whisper's progress bars would otherwise fill the pipe and stall it); the end kept.
            let tail = ErrorTail()
            err.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { tail.add(d) }
            }
            p.terminationHandler = { proc in
                if proc.terminationStatus != 0 { NSLog("Whisper failed (%d): %@", proc.terminationStatus, tail.text) }
                c.resume(returning: proc.terminationStatus == 0)
            }
            do { try p.run() } catch { NSLog("Whisper didn't start: \(error)"); c.resume(returning: false) }
        }
    }

    /// The file's sound as 16 kHz mono 16-bit WAV, what every Whisper reads. False if it has no sound.
    static func writeWAV(from url: URL, to out: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        guard reader.startReading() else { return false }
        FileManager.default.createFile(atPath: out.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: out) else { return false }
        return await BlockingWork.run {
            let stall = StallGuard(reader)
            defer { stall.stop(); try? handle.close() }
            handle.write(Data(count: 44))
            var bytes = 0
            while let sb = output.copyNextSampleBuffer() {
                stall.tick()
                guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                let n = CMBlockBufferGetDataLength(block)
                guard n > 0 else { continue }
                var chunk = Data(count: n)
                chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }
                handle.write(chunk)
                bytes += n
            }
            guard bytes > 0, reader.status != .cancelled else { return false }
            // The header, now that the length is known.
            var h = Data()
            func u32(_ v: UInt32) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 4)) }
            func u16(_ v: UInt16) { var x = v.littleEndian; h.append(Data(bytes: &x, count: 2)) }
            h.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes)); h.append(contentsOf: Array("WAVE".utf8))
            h.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
            h.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
            try? handle.seek(toOffset: 0)
            handle.write(h)
            return true
        }
    }
}

/// The last few lines a program wrote to its error output, for the log when it fails.
private final class ErrorTail: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func add(_ d: Data) { lock.lock(); data.append(d); if data.count > 4000 { data = data.suffix(2000) }; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data.suffix(2000), as: UTF8.self) }
}
