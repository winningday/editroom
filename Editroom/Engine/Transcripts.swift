import AVFoundation
import Foundation
#if canImport(Speech)
import Speech
#endif

/// What's said in a file: each word with its time in the file. Made once per file on this Mac (Apple's
/// on-device speech recognition), in the background after import, and kept on disk, so Magic and Media
/// search can use it at once and nothing is sent anywhere.
struct Transcript: Codable, Hashable {
    struct Word: Codable, Hashable {
        var start: Double
        var end: Double
        var text: String
        /// Starts a subtitle line of its own (words brought in from an SRT); nil for words that were heard.
        var cue: Bool? = nil
    }

    var words: [Word]
    var language: String

    var isEmpty: Bool { words.isEmpty }
    var text: String { SubtitleText.join(words.map(\.text)) }

    /// Stretches of talking: words closer than `gap` seconds run together.
    func speech(gap: Double = 0.45) -> [(start: Double, end: Double)] {
        var out: [(Double, Double)] = []
        for w in words {
            if let last = out.last, w.start - last.1 < gap {
                out[out.count - 1].1 = max(last.1, w.end)
            } else {
                out.append((w.start, w.end))
            }
        }
        return out.map { (start: $0.0, end: $0.1) }
    }

    /// Sentences (or runs of talking, if there's no punctuation), with their times.
    func sentences(gap: Double = 0.8) -> [(start: Double, end: Double, text: String)] {
        var out: [(Double, Double, [String])] = []
        for w in words {
            let ends = out.last?.2.last.map { $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!") } ?? true
            if let last = out.last, !ends, w.start - last.1 < gap {
                out[out.count - 1].1 = w.end
                out[out.count - 1].2.append(w.text)
            } else {
                out.append((w.start, w.end, [w.text]))
            }
        }
        return out.map { (start: $0.0, end: $0.1, text: $0.2.joined(separator: " ")) }
    }

    /// Whether they say these words, in this order (case and punctuation aside). With `typing`, the last
    /// word can be the start of one ("gu" finds "guys"), for searching as it's typed.
    func says(_ phrase: String, typing: Bool = false) -> Bool {
        let want = Self.tokens(phrase)
        guard !want.isEmpty else { return false }
        let have = Self.tokens(text)
        guard have.count >= want.count else { return false }
        for i in 0...(have.count - want.count) {
            let run = have[i..<(i + want.count)]
            let whole = zip(run.dropLast(), want.dropLast()).allSatisfy { $0 == $1 }
            let last = typing ? run.last!.hasPrefix(want.last!) : run.last! == want.last!
            if whole && last { return true }
        }
        return false
    }

    /// A few words either side of where they say this, for showing why a clip matched:
    /// ("okay", "guys,", "we're on the way…").
    func snippet(_ phrase: String, typing: Bool = false) -> (before: String, match: String, after: String)? {
        let want = Self.tokens(phrase)
        guard !want.isEmpty, words.count >= want.count else { return nil }
        let have = words.map { Self.tokens($0.text).first ?? "" }
        for i in 0...(words.count - want.count) {
            let run = have[i..<(i + want.count)]
            let whole = zip(run.dropLast(), want.dropLast()).allSatisfy { $0 == $1 }
            let last = typing ? run.last!.hasPrefix(want.last!) : run.last! == want.last!
            guard whole && last else { continue }
            let from = max(0, i - 3), to = min(words.count, i + want.count + 4)
            let before = words[from..<i].map(\.text).joined(separator: " ")
            let match = words[i..<(i + want.count)].map(\.text).joined(separator: " ")
            let after = words[(i + want.count)..<to].map(\.text).joined(separator: " ")
            return ((from > 0 ? "…" : "") + before, match, after + (to < words.count ? "…" : ""))
        }
        return nil
    }

    /// Every place they say these words, with their times in the file and a few words around.
    func occurrences(_ phrase: String) -> [(start: Double, end: Double, context: String)] {
        let want = Self.tokens(phrase)
        guard !want.isEmpty, words.count >= want.count else { return [] }
        let have = words.map { Self.tokens($0.text).first ?? "" }
        var out: [(Double, Double, String)] = []
        for i in 0...(words.count - want.count) where Array(have[i..<(i + want.count)]) == want {
            let from = max(0, i - 4), to = min(words.count, i + want.count + 5)
            out.append((words[i].start, words[i + want.count - 1].end, words[from..<to].map(\.text).joined(separator: " ")))
        }
        return out.map { (start: $0.0, end: $0.1, context: $0.2) }
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }
}

/// Transcripts for the library: made in the background, one file at a time, and kept on disk by file.
@MainActor
final class Transcripts: ObservableObject {
    static let shared = Transcripts()

    enum State: Equatable {
        case waiting, working, ready, failed
    }

    /// Ready transcripts by file (path), and what's waiting or being made.
    @Published private(set) var states: [String: State] = [:]
    private var made: [String: Transcript] = [:]
    private var queue: [URL] = []
    private var working: URL?
    private var waiters: [String: [CheckedContinuation<Transcript?, Never>]] = [:]
    /// Being heard from a file that has since changed: thrown away when done, and heard again.
    private var stale = Set<String>()

    /// A file changed on disk: what was heard in it goes (its saved transcript is named for the old file).
    func forget(_ url: URL) {
        made[url.path] = nil
        states[url.path] = nil
        if working == url { stale.insert(url.path) }
    }

    /// Hearing speech needs Whisper installed on this Mac, or macOS 26 (Apple's own speech recognition).
    static var available: Bool {
        if Whisper.engineChoice != "apple", Whisper.find() != nil { return true }
        if Whisper.engineChoice == "whisper" { return false }
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Hears a file again (after changing the language or switching to Whisper): its saved transcript goes.
    func redo(_ url: URL) {
        try? FileManager.default.removeItem(at: file(for: url))
        forget(url)
        make(url, soon: true)
    }

    func transcript(for url: URL) -> Transcript? { made[url.path] ?? load(url) }

    func state(for url: URL) -> State? { made[url.path] != nil ? .ready : states[url.path] }

    /// Queues a file. `soon` puts it first (Magic is asking for it now).
    func make(_ url: URL, soon: Bool = false) {
        guard Self.available, made[url.path] == nil else { return }
        if working == url, stale.contains(url.path) { states[url.path] = .waiting; return }
        if let t = load(url) {
            made[url.path] = t
            states[url.path] = .ready
            return
        }
        guard working != url else { return }
        if let i = queue.firstIndex(of: url) {
            guard soon else { return }
            queue.remove(at: i)
        }
        if soon { queue.insert(url, at: 0) } else { queue.append(url) }
        states[url.path] = .waiting
        next()
    }

    /// The transcript, made now if it isn't yet (waiting up to `limit` seconds).
    func ready(_ url: URL, limit: Double = 90) async -> Transcript? {
        if let t = transcript(for: url) { return t }
        guard Self.available else { return nil }
        if states[url.path] == .failed { return nil }
        make(url, soon: true)
        return await withCheckedContinuation { cont in
            waiters[url.path, default: []].append(cont)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1e9))
                if let list = self.waiters[url.path], !list.isEmpty {
                    self.waiters[url.path] = nil
                    for c in list { c.resume(returning: nil) }
                }
            }
        }
    }

    private func next() {
        guard working == nil, !queue.isEmpty else { return }
        let url = queue.removeFirst()
        working = url
        states[url.path] = .working
        Task.detached(priority: .utility) {
            let result = await Self.transcribe(url)
            await MainActor.run {
                let t = Transcripts.shared
                t.working = nil
                if t.stale.remove(url.path) != nil {
                    // Heard from the old file; the new one goes to the back of the line.
                    if t.states[url.path] == .waiting {
                        t.queue.append(url)
                        t.next()
                        return
                    }
                    t.states[url.path] = nil
                } else if let result {
                    t.made[url.path] = result
                    t.states[url.path] = .ready
                    t.save(result, for: url)
                } else {
                    t.states[url.path] = .failed
                }
                for c in t.waiters[url.path] ?? [] { c.resume(returning: result) }
                t.waiters[url.path] = nil
                t.next()
            }
        }
    }

    // MARK: On disk

    nonisolated static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Editroom/Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func file(for url: URL) -> URL { Self.folder.appendingPathComponent(ReverseAudio.cacheName(for: url) + ".json") }

    private func load(_ url: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: file(for: url)), let t = try? JSONDecoder().decode(Transcript.self, from: data) else { return nil }
        made[url.path] = t
        return t
    }

    private func save(_ t: Transcript, for url: URL) {
        if let data = try? JSONEncoder().encode(t) { try? data.write(to: file(for: url), options: .atomic) }
    }

    // MARK: Listening

    /// Every word in the file's sound, with its time. Nil if it couldn't be read; empty if nothing's said.
    nonisolated static func transcribe(_ url: URL) async -> Transcript? {
        // Whisper first when it's installed (any macOS, and strong at Chinese); Apple's if it fails.
        if let whisper = Whisper.inUse, let t = await Whisper.transcribe(url, with: whisper) { return t }
        if Whisper.engineChoice == "whisper" { return nil }
        #if canImport(Speech)
        if #available(macOS 26, *) {
            return try? await SpeechReader.read(url)
        }
        #endif
        return nil
    }
}

#if canImport(Speech)
@available(macOS 26, *)
private enum SpeechReader {
    static func read(_ url: URL) async throws -> Transcript? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return Transcript(words: [], language: "")
        }
        // The language chosen in Settings › Subtitles, else the Mac's own.
        let wanted: Locale = switch Whisper.language {
        case "auto": Locale.current
        case "zh": Locale(identifier: "zh-CN")
        case "en": Locale(identifier: "en-US")
        default: Locale(identifier: Whisper.language)
        }
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) ?? Locale(identifier: "en-US")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        // The language's model, once per Mac.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let format = AVAudioFormat(commonFormat: best.commonFormat, sampleRate: best.sampleRate,
                                         channels: best.channelCount, interleaved: true) else { return nil }

        // The file's sound, decoded to what the recogniser wants.
        let reader = try AVAssetReader(asset: asset)
        let isFloat = format.commonFormat == .pcmFormatFloat32
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: isFloat ? 32 : 16,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let (inputs, feed) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collect = Task { () -> [Transcript.Word] in
            var words: [Transcript.Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    words.append(Transcript.Word(start: range.start.seconds, end: range.end.seconds, text: text))
                }
            }
            return words
        }
        try await analyzer.start(inputSequence: inputs)
        let stall = StallGuard(reader)
        defer { stall.stop() }
        while let sample = output.copyNextSampleBuffer() {
            stall.tick()
            if let buffer = pcm(sample, format: format) { feed.yield(AnalyzerInput(buffer: buffer)) }
        }
        feed.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let words = try await collect.value.sorted { $0.start < $1.start }
        return Transcript(words: words, language: locale.identifier)
    }

    /// A decoded chunk of sound as the buffer the recogniser reads.
    private static func pcm(_ sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
#endif
