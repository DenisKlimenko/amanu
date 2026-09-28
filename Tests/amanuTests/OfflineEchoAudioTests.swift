import AVFoundation
import Foundation
import Testing
@testable import amanu

struct OfflineEchoAudioTests {
    private final class DelayedPassThrough: EchoCancellationBackend {
        let sampleRate = 16_000
        let hopSize = 256
        private var pending = [Float](repeating: 0, count: 256)

        func process(microphone: [Float], reference: [Float]) throws -> [Float] {
            defer { pending = microphone }
            return pending
        }
    }

    /// Models a stateful processor whose output for each sample depends on the
    /// immediately preceding input sample. Like LocalVQE, it emits the
    /// processed result one hop late.
    private final class DelayedFirstDifference: EchoCancellationBackend {
        let sampleRate = 16_000
        let hopSize = 256
        private var previousSample: Float = 0
        private var pending = [Float](repeating: 0, count: 256)

        func process(microphone: [Float], reference: [Float]) throws -> [Float] {
            var difference = [Float](repeating: 0, count: hopSize)
            for index in microphone.indices {
                difference[index] = microphone[index] - previousSample
                previousSample = microphone[index]
            }
            defer { pending = difference }
            return pending
        }
    }

    /// Simulates an adaptive canceller whose acquisition uses absolute stream
    /// history. If it first sees playback before four seconds of model time,
    /// it locks into a bad state and leaves the echo untouched.
    private final class AbsoluteTimelineCanceller: EchoCancellationBackend {
        let sampleRate = 16_000
        let hopSize = 256
        private var samplesSeen = 0
        private var suppressesEcho: Bool?
        private var pending = [Float](repeating: 0, count: 256)

        func process(microphone: [Float], reference: [Float]) throws -> [Float] {
            defer {
                if suppressesEcho == nil, reference.contains(where: { $0 != 0 }) {
                    suppressesEcho = samplesSeen >= 4 * sampleRate
                }
                pending = suppressesEcho == true
                    ? [Float](repeating: 0, count: hopSize)
                    : microphone
                samplesSeen += hopSize
            }
            return pending
        }
    }

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ url: URL, rate: Double = 16000, channels: [[Float]]) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels.count))!
        let file = try AVAudioFile(forWriting: url, settings: AudioFormats.pcmSettings(sampleRate: rate, channels: AVAudioChannelCount(channels.count)))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
        buffer.frameLength = buffer.frameCapacity
        for (c, samples) in channels.enumerated() {
            buffer.floatChannelData![c].update(from: samples, count: samples.count)
        }
        try file.write(from: buffer)
    }

    private func read(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: b)
        return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
    }

    @Test("Offline preparation preserves source bytes, aligns offsets, and never truncates a partial final frame")
    func preservesAndAligns() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("original-mic.caf")
        let sys = dir.appendingPathComponent("original-system.caf")
        let speech = (0..<16_053).map { Float(sin(Double($0) * 0.1)) * 0.1 }
        try write(mic, channels: [speech])
        try write(sys, rate: 48000, channels: [.init(repeating: 0, count: 48000)])
        let storedSpeech = try read(mic)
        let micBytes = try Data(contentsOf: mic), systemBytes = try Data(contentsOf: sys)
        let result = try OfflineEchoAudio.prepare(
            microphone: .init(url: mic, offsetMs: 150), system: .init(url: sys), in: dir)
        #expect(result.frames == 18_453)
        let output = try read(result.microphone)
        #expect(output.count == 18_453)
        #expect(output.prefix(2400).allSatisfy { $0 == 0 })
        #expect(zip(output.dropFirst(2400), storedSpeech).allSatisfy { $0 == $1 })
        #expect(try read(result.system).count == 18_453)
        #expect(result.directory != dir)
        result.removeAudio()
        #expect(try Data(contentsOf: mic) == micBytes)
        #expect(try Data(contentsOf: sys) == systemBytes)
    }

    @Test("Stereo archives retain side identity and changed inputs get a different ASR cache namespace")
    func archiveChannelsAndCache() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appendingPathComponent("audio.caf")
        let local = (0..<1000).map { Float(sin(Double($0) * 0.1)) * 0.1 }
        try write(archive, channels: [local, .init(repeating: 0, count: 1000)])
        let storedLocal = try read(archive)
        let sources = (OfflineEchoAudio.Source(url: archive, channel: 0), OfflineEchoAudio.Source(url: archive, channel: 1))
        let first = try OfflineEchoAudio.prepare(microphone: sources.0, system: sources.1, in: dir)
        #expect(try read(first.microphone) == storedLocal)
        #expect(try read(first.system).allSatisfy { $0 == 0 })
        let cache = ProviderCache.url(
            in: first.microphone.deletingLastPathComponent(), provider: .assemblyAI, parts: ["mic"])
        #expect(cache.deletingLastPathComponent() != dir)
        try Data("keep cached provider response".utf8).write(to: cache)
        first.removeAudio()
        let second = try OfflineEchoAudio.prepare(microphone: sources.0, system: sources.1, in: dir)
        #expect(first.directory == second.directory)
        #expect(try String(contentsOf: cache, encoding: .utf8) == "keep cached provider response")
        let shifted = try OfflineEchoAudio.prepare(microphone: .init(url: archive, channel: 0, offsetMs: 100), system: sources.1, in: dir)
        #expect(shifted.directory != first.directory)
    }

    @Test("Missing or invalid channels fail without modifying the recording")
    func unreadableFails() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = dir.appendingPathComponent("audio.caf")
        try write(archive, channels: [.init(repeating: 0.1, count: 160)])
        let before = try Data(contentsOf: archive)
        #expect(throws: (any Error).self) {
            try OfflineEchoAudio.prepare(microphone: .init(url: archive), system: .init(url: archive, channel: 1), in: dir)
        }
        #expect(try Data(contentsOf: archive) == before)
    }

    @Test("Resampling a non-integral 44.1 kHz tail keeps the complete duration")
    func fractionalResampling() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("audio.caf")
        try write(source, rate: 44100, channels: [.init(repeating: 0.1, count: 44113), .init(repeating: 0, count: 44113)])
        let result = try OfflineEchoAudio.prepare(microphone: .init(url: source), system: .init(url: source, channel: 1), in: dir)
        #expect(result.frames == 16005)
        #expect(try read(result.microphone).count == 16005)
    }

    @Test("Cancelling offline processing removes derived audio and keeps sources")
    func cancellation() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("audio.caf")
        try write(source, channels: [.init(repeating: 0.1, count: 16000), .init(repeating: 0, count: 16000)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try OfflineEchoAudio.prepare(microphone: .init(url: source), system: .init(url: source, channel: 1), in: dir)
        }
        do {
            _ = try await task.value
            Issue.record("Cancellation returned usable derived audio")
        } catch is CancellationError { }
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!.allObjects as! [URL]
        #expect(files.filter { $0.pathExtension == "caf" }.count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("One echo-canceller stream stays warm across bounded-memory windows")
    func keepsWarmStateAcrossWindows() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("audio.caf")
        let count = 31 * 16_000 + 17
        try write(source, channels: [
            .init(repeating: 0.15, count: count),
            .init(repeating: 0.2, count: count),
        ])
        var creations = 0

        let result = try OfflineEchoAudio.prepare(
            microphone: .init(url: source),
            system: .init(url: source, channel: 1),
            in: dir
        ) {
            creations += 1
            return try EchoCanceller(backend: DelayedPassThrough())
        }

        #expect(creations == 1)
        #expect(try read(result.microphone).count == count)
        #expect(try read(result.system).count == count)
    }

    @Test("Leading reference silence advances the adaptive model from the start of the recording")
    func leadingReferenceSilenceWarmsModelTimeline() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("audio.caf")
        let leadingFrames = 5 * 16_000
        let activeFrames = 3 * EchoCanceller.frameSize
        let count = leadingFrames + activeFrames
        try write(source, channels: [
            .init(repeating: 0.25, count: count),
            .init(repeating: 0, count: leadingFrames)
                + .init(repeating: 0.2, count: activeFrames),
        ])

        let result = try OfflineEchoAudio.prepare(
            microphone: .init(url: source),
            system: .init(url: source, channel: 1),
            in: dir
        ) {
            try EchoCanceller(backend: AbsoluteTimelineCanceller())
        }

        let output = try read(result.microphone)
        let tolerance: Float = 0.000_01
        #expect(output.prefix(leadingFrames).allSatisfy { abs($0 - 0.25) < tolerance })
        #expect(output.dropFirst(leadingFrames).allSatisfy { abs($0) < tolerance })
    }

    @Test("An entirely absent reference preserves the microphone without loading the model")
    func allZeroReferenceAvoidsModel() throws {
        struct UnexpectedModelLoad: Error {}

        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("audio.caf")
        let microphone = (0..<20_000).map { Float(sin(Double($0) * 0.03)) * 0.1 }
        try write(source, channels: [microphone, .init(repeating: 0, count: microphone.count)])
        let storedMicrophone = try read(source)

        let result = try OfflineEchoAudio.prepare(
            microphone: .init(url: source),
            system: .init(url: source, channel: 1),
            in: dir
        ) {
            throw UnexpectedModelLoad()
        }

        #expect(try read(result.microphone) == storedMicrophone)
    }

    @Test("Bounded-memory windows do not insert samples into the stateful processor stream")
    func continuousSamplesAcrossWindows() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("audio.caf")
        let oldWindowBoundary = 15 * 16_000
        let count = oldWindowBoundary + 2 * EchoCanceller.frameSize
        try write(source, channels: [
            .init(repeating: 0.15, count: count),
            .init(repeating: 0.2, count: count),
        ])

        let result = try OfflineEchoAudio.prepare(
            microphone: .init(url: source),
            system: .init(url: source, channel: 1),
            in: dir
        ) {
            try EchoCanceller(backend: DelayedFirstDifference())
        }

        let output = try read(result.microphone)
        #expect(output.count == count)
        // CAF's integer PCM settings quantize the 0.15 fixture slightly.
        let tolerance: Float = 0.000_01
        #expect(abs(output[0] - 0.15) < tolerance)
        #expect(abs(output[oldWindowBoundary]) < tolerance)
        #expect(output.dropFirst().allSatisfy { abs($0) < tolerance })
    }
}
