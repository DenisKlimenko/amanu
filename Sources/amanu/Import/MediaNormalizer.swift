@preconcurrency import AVFoundation
import Foundation

/// The media boundary of importing: prove that a file contains real audio,
/// then copy its first audio track into the one compact format every
/// transcription engine can read. The source is opened read-only and is never
/// moved or rewritten.
protocol MediaNormalizing: Sendable {
    func probe(_ source: URL) async throws -> MediaNormalizer.Probe
    func normalize(
        _ source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

struct MediaNormalizer: MediaNormalizing, Sendable {
    struct Probe: Sendable {
        let duration: TimeInterval
        let sourceBytes: Int64
    }

    enum NormalizationError: Error, CustomStringConvertible {
        case noAudioTrack(URL)
        case invalidDuration(URL)
        case unreadable(URL, Error?)
        case unwritable(URL, Error?)

        var description: String {
            switch self {
            case .noAudioTrack(let url):
                return "\(url.lastPathComponent) has no audio track"
            case .invalidDuration(let url):
                return "\(url.lastPathComponent) has no playable duration"
            case .unreadable(let url, let error):
                return "can't read \(url.lastPathComponent)"
                    + (error.map { ": \($0)" } ?? "")
            case .unwritable(let url, let error):
                return "can't write \(url.lastPathComponent)"
                    + (error.map { ": \($0)" } ?? "")
            }
        }
    }

    /// The rates Apple's AAC encoder accepts, and the only ones an imported
    /// file is written at. A studio recording at 96 or 192 kHz, or a
    /// camera's odd 37.8, used to be handed to the encoder as it came — the
    /// rate was clamped from below only — and failed there.
    private static let aacSampleRates: [Double] = [
        8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000,
    ]

    /// The rate to write a source recorded at `rate`: the lowest AAC rate
    /// that loses nothing of it, and 48 kHz for anything above — far more
    /// than speech recognition uses.
    static func outputSampleRate(for rate: Double) -> Double {
        aacSampleRates.first { $0 >= rate } ?? aacSampleRates.last!
    }

    func probe(_ source: URL) async throws -> Probe {
        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw NormalizationError.unreadable(source, error)
        }
        guard !tracks.isEmpty else { throw NormalizationError.noAudioTrack(source) }

        let duration: TimeInterval
        do {
            duration = try await asset.load(.duration).seconds
        } catch {
            throw NormalizationError.unreadable(source, error)
        }
        guard duration.isFinite, duration > 0 else {
            throw NormalizationError.invalidDuration(source)
        }
        let bytes = ((try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return Probe(duration: duration, sourceBytes: Int64(bytes))
    }

    func normalize(
        _ source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // AVAudioFile is the least surprising path for ordinary audio: it is
        // the same frame-by-frame conversion used by Amanu's mixer and slicer
        // and does not involve the media-library export services. Movie
        // containers cannot be opened this way and fall through to the asset
        // reader below, which extracts their first audio track.
        // Only when the file can be written back at its own rate: anything
        // else needs resampling, which the asset reader below does and this
        // frame-by-frame copy does not.
        if let input = try? AVAudioFile(forReading: source),
           input.length > 0,
           input.processingFormat.channelCount == 1,
           Self.outputSampleRate(for: input.processingFormat.sampleRate)
               == input.processingFormat.sampleRate {
            let worker = Task.detached(priority: .utility) {
                try await Self.writeAudioFile(
                    input, to: destination, progress: progress)
            }
            do {
                try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                return
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: destination)
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw NormalizationError.unwritable(destination, error)
            }
        }

        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw NormalizationError.unreadable(source, error)
        }
        guard let track = tracks.first else { throw NormalizationError.noAudioTrack(source) }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw NormalizationError.invalidDuration(source)
        }

        let descriptions = try await track.load(.formatDescriptions)
        let basic = descriptions.first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sampleRate = Self.outputSampleRate(for: basic?.mSampleRate ?? 48_000)
        // Imported media is one conversation source, not Amanu's paired
        // microphone/system tracks. Keeping ordinary stereo here would make
        // AssemblyAI interpret left and right as separate speakers through
        // its multichannel mode. Downmix at the media boundary instead.
        let channels = 1

        let worker = Task.detached(priority: .utility) {
            try await Self.writeFirstTrack(
                track,
                asset: asset,
                duration: duration,
                sampleRate: sampleRate,
                channels: channels,
                to: destination,
                progress: progress)
        }
        do {
            try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            throw CancellationError()
        } catch let error as NormalizationError {
            try? FileManager.default.removeItem(at: destination)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw NormalizationError.unwritable(destination, error)
        }
    }

    private static func writeAudioFile(
        _ input: AVAudioFile,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let format = input.processingFormat
        let channels = format.channelCount
        guard channels > 0, channels <= 2, format.sampleRate > 0 else {
            throw NormalizationError.unreadable(input.url, nil)
        }
        try? FileManager.default.removeItem(at: destination)
        let output = try AVAudioFile(
            forWriting: destination,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: channels,
            ],
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        let block = AVAudioFrameCount(max(1, format.sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else {
            throw NormalizationError.unreadable(input.url, nil)
        }
        progress(0)
        while input.framePosition < input.length {
            try Task.checkCancellation()
            buffer.frameLength = 0
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            progress(min(1, Double(input.framePosition) / Double(input.length)))
            await Task.yield()
        }
        try Task.checkCancellation()
        progress(1)
    }

    private static func writeFirstTrack(
        _ track: AVAssetTrack,
        asset: AVAsset,
        duration: TimeInterval,
        sampleRate: Double,
        channels: Int,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else {
            throw NormalizationError.unreadable(track.asset?.url ?? destination, nil)
        }
        reader.add(output)

        let writer = try AVAssetWriter(url: destination, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ])
        guard writer.canAdd(input) else {
            throw NormalizationError.unwritable(destination, writer.error)
        }
        writer.add(input)
        guard writer.startWriting(), reader.startReading() else {
            throw NormalizationError.unreadable(track.asset?.url ?? destination, reader.error)
        }
        writer.startSession(atSourceTime: .zero)
        progress(0)

        while reader.status == .reading {
            try Task.checkCancellation()
            guard input.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard input.append(sample) else {
                reader.cancelReading()
                throw NormalizationError.unwritable(destination, writer.error)
            }
            let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if seconds.isFinite { progress(min(1, max(0, seconds / duration))) }
        }

        if reader.status == .failed {
            writer.cancelWriting()
            throw NormalizationError.unreadable(track.asset?.url ?? destination, reader.error)
        }
        try Task.checkCancellation()
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw NormalizationError.unwritable(destination, writer.error)
        }
        progress(1)
    }
}

private extension AVAsset {
    /// Available for the URL-backed assets used here; kept only for useful
    /// error messages when AVFoundation refuses a track after probing it.
    var url: URL? { (self as? AVURLAsset)?.url }
}
