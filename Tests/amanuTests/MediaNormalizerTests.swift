@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import amanu

/// The import boundary against real files, not stubs: whatever a person drags
/// in either becomes a readable M4A or fails with a sentence, and leaves
/// nothing half-written behind either way.
struct MediaNormalizerTests {
    private static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-normalize-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A sine tone at any rate and channel count, written as 16-bit PCM WAV.
    static func tone(
        _ url: URL, seconds: Double, rate: Double, channels: AVAudioChannelCount = 1
    ) throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate,
            channels: channels, interleaved: false)!
        let file = try AVAudioFile(
            forWriting: url,
            settings: AudioFormats.pcmSettings(sampleRate: rate, channels: channels),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        let total = Int(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total))!
        buffer.frameLength = AVAudioFrameCount(total)
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for index in 0..<total {
                samples[index] = 0.3 * Float(sin(2 * .pi * 440 * Double(index) / rate))
            }
        }
        try file.write(from: buffer)
    }

    /// Normalize, and whatever happens, say what is left in the folder
    /// besides the source.
    private static func normalize(_ source: URL) async -> (Result<Void, Error>, [String]) {
        let destination = source.deletingLastPathComponent().appendingPathComponent("source.m4a")
        let result: Result<Void, Error>
        do {
            let normalizer = MediaNormalizer()
            _ = try await normalizer.probe(source)
            try await normalizer.normalize(source, to: destination) { _ in }
            result = .success(())
        } catch {
            result = .failure(error)
        }
        let left = (try? FileManager.default.contentsOfDirectory(
            atPath: source.deletingLastPathComponent().path)) ?? []
        return (result, left.filter { $0 != source.lastPathComponent }.sorted())
    }

    private static func failure(_ result: Result<Void, Error>) -> MediaNormalizer.NormalizationError? {
        if case .failure(let error) = result { return error as? MediaNormalizer.NormalizationError }
        return nil
    }

    @Test("A 96 kHz recording is brought down to a rate AAC takes, mono or stereo")
    func highSampleRates() async throws {
        for channels: AVAudioChannelCount in [1, 2] {
            for rate in [96_000.0, 192_000.0] {
                let dir = try Self.folder("rate")
                defer { try? FileManager.default.removeItem(at: dir) }
                let source = dir.appendingPathComponent("studio.wav")
                try Self.tone(source, seconds: 0.3, rate: rate, channels: channels)

                let (result, left) = await Self.normalize(source)
                if case .failure(let error) = result {
                    Issue.record("\(Int(rate)) Hz × \(channels) failed: \(error)")
                    continue
                }
                #expect(left == ["source.m4a"])
                let normalized = try AVAudioFile(forReading: dir.appendingPathComponent("source.m4a"))
                #expect(normalized.fileFormat.sampleRate <= 48_000)
                #expect(normalized.processingFormat.channelCount == 1)
                let seconds = Double(normalized.length) / normalized.fileFormat.sampleRate
                #expect(abs(seconds - 0.3) < 0.1, "\(Int(rate)) Hz came out \(seconds) s long")
            }
        }
    }

    @Test("An odd sample rate is rounded up to one AAC supports")
    func oddSampleRate() async throws {
        let dir = try Self.folder("odd-rate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("odd.wav")
        try Self.tone(source, seconds: 0.3, rate: 37_800)

        let (result, left) = await Self.normalize(source)
        if case .failure(let error) = result { Issue.record("37.8 kHz failed: \(error)") }
        #expect(left == ["source.m4a"])
        #expect(MediaNormalizer.outputSampleRate(for: 37_800) == 44_100)
        #expect(MediaNormalizer.outputSampleRate(for: 96_000) == 48_000)
        #expect(MediaNormalizer.outputSampleRate(for: 16_000) == 16_000)
        #expect(MediaNormalizer.outputSampleRate(for: 4_000) == 8_000)
    }

    @Test("An empty file fails with a sentence and leaves nothing behind")
    func zeroLengthFile() async throws {
        let dir = try Self.folder("empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("empty.m4a")
        try Data().write(to: source)

        let (result, left) = await Self.normalize(source)
        let error = try #require(Self.failure(result))
        #expect(error.description.contains("empty.m4a"))
        #expect(left.isEmpty)
    }

    @Test("A corrupt file fails with a sentence and leaves nothing behind")
    func corruptFile() async throws {
        let dir = try Self.folder("corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("broken.wav")
        var bytes = Data("RIFF".utf8)
        bytes.append(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761) }))
        try bytes.write(to: source)

        let (result, left) = await Self.normalize(source)
        #expect(Self.failure(result) != nil)
        #expect(left.isEmpty)
    }

    /// A WAV whose format tag names a codec nothing on the Mac decodes.
    @Test("An audio codec the Mac cannot decode fails cleanly")
    func unsupportedCodec() async throws {
        let dir = try Self.folder("codec")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("strange.wav")
        try Self.wav(formatTag: 0x7A21, payload: Data(repeating: 0x5A, count: 32_000)).write(to: source)

        let (result, left) = await Self.normalize(source)
        #expect(Self.failure(result) != nil)
        #expect(left.isEmpty)
    }

    @Test("A video with no sound says so and leaves nothing behind")
    func videoWithoutAudio() async throws {
        let dir = try Self.folder("silent-video")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("screen.mov")
        try await Self.silentMovie(source)

        let (result, left) = await Self.normalize(source)
        let error = try #require(Self.failure(result))
        guard case .noAudioTrack = error else {
            Issue.record("Expected no audio track, got \(error)")
            return
        }
        #expect(error.description.contains("has no audio track"))
        #expect(left.isEmpty)
    }

    /// The same files through the importer, which owns the staging folder.
    @Test("Every kind of bad file fails in the importer with no staging folder left")
    func importerLeavesNoStaging() async throws {
        let root = try Self.folder("import-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty.m4a")
        try Data().write(to: empty)
        let strange = root.appendingPathComponent("strange.wav")
        try Self.wav(formatTag: 0x7A21, payload: Data(repeating: 0x5A, count: 32_000)).write(to: strange)
        let silent = root.appendingPathComponent("screen.mov")
        try await Self.silentMovie(silent)
        let studio = root.appendingPathComponent("studio.wav")
        try Self.tone(studio, seconds: 0.3, rate: 96_000, channels: 2)

        let coordinator = MediaImportCoordinator(root: root)
        let result = await coordinator.importFiles([empty, strange, silent, studio])

        #expect(result.failures.map(\.source.lastPathComponent).sorted()
            == ["empty.m4a", "screen.mov", "strange.wav"])
        #expect(result.imported.map(\.source.lastPathComponent) == ["studio.wav"])
        let staging = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".import-") }
        #expect(staging.isEmpty, "Left behind: \(staging)")
    }

    // MARK: - fixtures

    private static func wav(formatTag: UInt16, payload: Data) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        var fmt = Data()
        fmt += le(formatTag)
        fmt += le(UInt16(1))          // channels
        fmt += le(UInt32(16_000))     // sample rate
        fmt += le(UInt32(16_000))     // byte rate
        fmt += le(UInt16(1))          // block align
        fmt += le(UInt16(8))          // bits per sample
        var body = Data("WAVE".utf8)
        body += Data("fmt ".utf8) + le(UInt32(fmt.count)) + fmt
        body += Data("data".utf8) + le(UInt32(payload.count)) + payload
        return Data("RIFF".utf8) + le(UInt32(body.count)) + body
    }

    /// A few frames of black video and no audio track at all — what a screen
    /// recording made without sound looks like.
    private static func silentMovie(_ url: URL) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64,
            AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<10 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), 0, CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }
}
