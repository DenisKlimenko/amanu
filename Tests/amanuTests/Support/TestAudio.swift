import AVFoundation
import Foundation

@testable import amanu

/// Audio and session folders made to order, for the tests that need a
/// recording to exist without anybody having recorded one.
enum TestAudio {
    /// A mono sine tone in amanu's own PCM track format.
    static func writeTone(
        to url: URL, seconds: Double, frequency: Double,
        amplitude: Float = 0.4, sampleRate: Double = 48_000
    ) throws {
        try write(to: url, seconds: seconds, sampleRate: sampleRate) { _, frame in
            amplitude * Float(sin(2 * .pi * frequency * Double(frame) / sampleRate))
        }
    }

    /// Samples of any shape — `sample(channel, frame)` — written in chunks,
    /// the way the recorders write. PCM in amanu's track format unless
    /// `settings` says otherwise (an AAC track, say).
    static func write(
        to url: URL, seconds: Double, sampleRate: Double = 48_000,
        channels: AVAudioChannelCount = 1, settings: [String: Any]? = nil,
        sample: (_ channel: Int, _ frame: Int) -> Float
    ) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: channels, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings ?? AudioFormats.pcmSettings(sampleRate: sampleRate, channels: channels),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        var written = 0
        let total = Int((seconds * sampleRate).rounded())
        while written < total {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            let count = min(4800, total - written)
            buffer.frameLength = AVAudioFrameCount(count)
            for channel in 0..<Int(channels) {
                let samples = buffer.floatChannelData![channel]
                for i in 0..<count { samples[i] = sample(channel, written + i) }
            }
            try file.write(from: buffer)
            written += count
        }
    }

    /// Exactly these samples, one array per channel, all the same length.
    static func write(to url: URL, sampleRate: Double, samples: [[Float]]) throws {
        try write(
            to: url, seconds: Double(samples[0].count) / sampleRate, sampleRate: sampleRate,
            channels: AVAudioChannelCount(samples.count)
        ) { channel, frame in samples[channel][frame] }
    }

    /// A finished recording with no transcript: two tone tracks and the
    /// meta.json that says they belong together. Naming and summarizing are
    /// marked as given up on unless `postProcessing` says otherwise, so that a
    /// test about the transcript reaches for no language model.
    static func rawSession(
        seconds: Double = 2, postProcessing: Bool = false, prefix: String = "amanu-session"
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeTone(to: dir.appendingPathComponent("mic.caf"), seconds: seconds, frequency: 220)
        try writeTone(to: dir.appendingPathComponent("system.caf"), seconds: seconds, frequency: 660)
        var meta: [String: Any] = [
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": ["mic": 0, "system": 0],
            "duration_seconds": Int(seconds),
        ]
        if !postProcessing {
            meta[SessionState.Key.speakersStatus] = "failed"
            meta[SessionState.Key.summaryStatus] = "failed"
        }
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }
}
