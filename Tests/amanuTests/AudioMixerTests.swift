import AVFoundation
import Foundation
import Testing

@testable import amanu

/// The mix is what a diarizing engine transcribes, and a mix that silently
/// leaves a side out is a transcript that reports success with half the
/// meeting missing.
struct AudioMixerTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-mix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A 48 kHz 16-bit track with a tone on the channels named in `loud`.
    private func writeTrack(
        _ url: URL, seconds: Double, channels: AVAudioChannelCount, loud: Set<Int>
    ) throws {
        let rate = 48_000.0
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels,
            interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormats.pcmSettings(sampleRate: rate, channels: channels),
            commonFormat: .pcmFormatFloat32, interleaved: false)
        let total = Int(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        for channel in 0..<Int(channels) {
            let data = buffer.floatChannelData![channel]
            for i in 0..<total {
                data[i] = loud.contains(channel) ? 0.5 * Float(sin(2 * .pi * 440 * Double(i) / rate)) : 0
            }
        }
        try file.write(from: buffer)
    }

    private func peak(of url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        return (0..<Int(buffer.frameLength)).reduce(Float(0)) { max($0, abs(samples[$1])) }
    }

    @Test("A stereo track heard only on the right is in the mix")
    func rightOnlyStereoTrackIsMixed() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let system = dir.appendingPathComponent("system.caf")
        try writeTrack(system, seconds: 1, channels: 2, loud: [1])
        let mixed = dir.appendingPathComponent("mixed.m4a")

        try await AudioMixer.mix([AudioMixer.Track(url: system, offset: 0)], to: mixed)

        #expect(try peak(of: mixed) > 0.1)
    }

    /// A track that is there and cannot be read is not a missing track. Mixing
    /// on without it produced a one-sided transcript that said it had worked.
    @Test("A track that exists and cannot be read fails the mix")
    func unreadableTrackFailsTheMix() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.caf")
        let system = dir.appendingPathComponent("system.caf")
        try writeTrack(mic, seconds: 1, channels: 1, loud: [0])
        try Data("not audio".utf8).write(to: system)
        let mixed = dir.appendingPathComponent("mixed.m4a")

        await #expect(throws: (any Error).self) {
            try await AudioMixer.mix(
                [AudioMixer.Track(url: mic, offset: 0), AudioMixer.Track(url: system, offset: 0)],
                to: mixed)
        }
        #expect(!FileManager.default.fileExists(atPath: mixed.path))
    }

    @Test("A track that is simply not there is left out")
    func missingTrackIsLeftOut() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.caf")
        try writeTrack(mic, seconds: 1, channels: 1, loud: [0])
        let mixed = dir.appendingPathComponent("mixed.m4a")

        try await AudioMixer.mix(
            [AudioMixer.Track(url: mic, offset: 0),
             AudioMixer.Track(url: dir.appendingPathComponent("system.caf"), offset: 0)],
            to: mixed)

        #expect(try peak(of: mixed) > 0.1)
    }

    /// The coordinator reuses any mixed.m4a it finds. A mix that failed
    /// partway through used to be left at that name and transcribed as the
    /// meeting on the next attempt.
    @Test("A mix that fails partway leaves nothing at the mix's name")
    func failedMixLeavesNothingBehind() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.caf")
        try writeTrack(mic, seconds: 3, channels: 1, loud: [0])
        let bytes = try #require(
            (try FileManager.default.attributesOfItem(atPath: mic.path))[.size] as? Int)
        let handle = try FileHandle(forWritingTo: mic)
        try handle.truncate(atOffset: UInt64(bytes / 2))
        try handle.close()
        let mixed = dir.appendingPathComponent("mixed.m4a")

        await #expect(throws: (any Error).self) {
            try await AudioMixer.mix([AudioMixer.Track(url: mic, offset: 0)], to: mixed)
        }
        #expect(!FileManager.default.fileExists(atPath: mixed.path))
        #expect(!FileManager.default.fileExists(atPath: AudioMixer.temporary(for: mixed).path))
    }
}
