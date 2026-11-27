import AVFoundation
import CoreGraphics
import Foundation

/// Measures how loud and how busy each file is over time (see Activity in Pacing.swift): its sound level
/// every 25 ms, and how much the picture changes every two seconds. Read on this Mac, once per file, and kept
/// on disk, so finding dead air or lining cameras up again is instant.
enum ActivityScan {
    static let levelStep = 0.025
    static let motionStep = 2.0

    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Editroom/Activity", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Kept small: the numbers as raw bytes rather than as text.
    private struct Stored: Codable {
        var version: Int
        var levelStep: Double
        var levels: Data
        var motionStep: Double
        var motion: Data
    }

    private static func file(for url: URL) -> URL {
        folder.appendingPathComponent(ReverseAudio.cacheName(for: url) + "-v\(Activity.version).json")
    }

    private static func floats(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private static func data(_ f: [Float]) -> Data { f.withUnsafeBufferPointer { Data(buffer: $0) } }

    static func cached(_ url: URL) -> Activity? {
        guard let d = try? Data(contentsOf: file(for: url)), let s = try? JSONDecoder().decode(Stored.self, from: d),
              s.version == Activity.version else { return nil }
        return Activity(levelStep: s.levelStep, levels: floats(s.levels), motionStep: s.motionStep, motion: floats(s.motion))
    }

    /// The file's activity, measured now if it hasn't been. `picture`: also how much it moves (videos).
    static func activity(_ url: URL, picture: Bool) async -> Activity? {
        if let hit = cached(url), !picture || !hit.motion.isEmpty { return hit }
        let soundTask = Task { await levels(url) }
        let moves: [Float] = picture ? await motion(url) : []
        let sound = await soundTask.value ?? []
        let a = Activity(levelStep: levelStep, levels: sound, motionStep: motionStep, motion: moves)
        guard !a.levels.isEmpty || !a.motion.isEmpty else { return nil }
        let s = Stored(version: Activity.version, levelStep: a.levelStep, levels: data(a.levels), motionStep: a.motionStep, motion: data(a.motion))
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: file(for: url), options: .atomic) }
        return a
    }

    /// Sound level (dB, full scale) every `levelStep`, read in a stream so a long class never sits in memory.
    static func levels(_ url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let rate = 8000.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        guard reader.startReading() else { return nil }
        let window = Int(rate * levelStep)
        return await BlockingWork.run {
            let stall = StallGuard(reader)
            defer { stall.stop() }
            var result: [Float] = []
            var sum: Float = 0
            var count = 0
            var chunk: [Float] = []
            while let sb = out.copyNextSampleBuffer() {
                stall.tick()
                guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
                let n = CMBlockBufferGetDataLength(block) / 4
                guard n > 0 else { continue }
                if chunk.count < n { chunk = [Float](repeating: 0, count: n) }
                chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * 4, destination: $0.baseAddress!) }
                for i in 0..<n {
                    sum += chunk[i] * chunk[i]
                    count += 1
                    if count == window {
                        result.append(10 * log10(max(1e-10, sum / Float(window))))
                        sum = 0
                        count = 0
                    }
                }
            }
            return result.isEmpty || reader.status == .cancelled ? nil : result
        }
    }

    /// How much the picture changes, every `motionStep`: small grey frames compared with the one before.
    /// Frames near each asked-for time are fine (they decode much faster), so a two-hour class takes a minute.
    static func motion(_ url: URL) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0.5,
              (try? await asset.loadTracks(withMediaType: .video).first) != nil else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 96, height: 96)
        let tolerance = CMTime(seconds: motionStep / 2, preferredTimescale: 600)
        gen.requestedTimeToleranceBefore = tolerance
        gen.requestedTimeToleranceAfter = tolerance
        let times = stride(from: 0.0, to: duration, by: motionStep).map { CMTime(seconds: $0, preferredTimescale: 600) }
        let w = 48, h = 27
        var previous: [UInt8]?
        var out: [Float] = []
        for await result in gen.images(for: times) {
            guard let img = try? result.image else { out.append(out.last ?? 0); continue }
            var gray = [UInt8](repeating: 0, count: w * h)
            let drew = gray.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.interpolationQuality = .low
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drew else { out.append(out.last ?? 0); continue }
            if let prev = previous {
                var d = 0
                for i in 0..<(w * h) { d += abs(Int(gray[i]) - Int(prev[i])) }
                out.append(Float(d) / Float(w * h) / 255)
            } else {
                out.append(1)
            }
            previous = gray
        }
        // The first frame has nothing before it: it counts as busy as the next.
        if out.count > 1 { out[0] = out[1] }
        return out
    }
}
