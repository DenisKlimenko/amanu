import AVFoundation
import Foundation

/// Reads one recorded track as mono Float32 at a chosen rate, a block at a
/// time, placed on the session's shared clock.
///
/// The compressor and the mixer used to carry a reader each, and both had the
/// same two faults, which is how they survived: a stereo file went through an
/// `AVAudioConverter` to mono with neither `downmix` nor a channel map, which
/// keeps the *left* channel and drops the right — the system track is always
/// stereo, so a source panned right was archived as silence — and a read that
/// failed halfway was taken for the end of the file, after which the
/// compressor padded the rest with zeros to the length in the header and
/// deleted the original. This reader mixes every channel down and throws on
/// any failure to read; the only end it accepts is the file's own length.
final class AudioTrackReader: @unchecked Sendable {
    enum ReadError: Error, CustomStringConvertible {
        case unreadable(URL, Error?)
        case empty(URL)
        case unsupported(URL)
        case failed(URL, Error)

        var description: String {
            switch self {
            case .unreadable(let url, let error):
                return "can't read \(url.lastPathComponent)" + (error.map { ": \($0)" } ?? "")
            case .empty(let url): return "\(url.lastPathComponent) is empty"
            case .unsupported(let url): return "can't convert \(url.lastPathComponent)"
            case .failed(let url, let error):
                return "reading \(url.lastPathComponent) failed partway: \(error)"
            }
        }
    }

    let url: URL
    /// The file's own rate, which callers use to choose the output rate.
    let sourceRate: Double
    /// First frame of the output this track contributes to.
    let start: AVAudioFramePosition
    /// Frames of output the whole track will come to, counted from `start`.
    let length: AVAudioFramePosition
    /// Nothing left to read. Set only by reaching the file's length.
    private(set) var spent = false

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let staging: AVAudioPCMBuffer
    private let format: AVAudioFormat
    /// A read error raised inside the converter's input block, which has no
    /// way to throw, carried out to `next` which does.
    private var pendingError: Error?

    /// Open `url` for reading at `rate`, starting `offset` seconds into the
    /// output. `rate` nil means the file's own rate — useful for asking a
    /// source its rate before choosing one for several.
    init(url: URL, rate: Double? = nil, offset: TimeInterval = 0) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReadError.unreadable(url, nil)
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ReadError.unreadable(url, error)
        }
        guard file.length > 0 else { throw ReadError.empty(url) }
        let input = file.processingFormat
        let rate = rate ?? input.sampleRate
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: input, to: format),
            let staging = AVAudioPCMBuffer(
                pcmFormat: input, frameCapacity: AVAudioFrameCount(input.sampleRate))
        else { throw ReadError.unsupported(url) }
        // Mix every channel into the one, rather than keep the first: the
        // converter's default for fewer output channels is to drop the rest.
        converter.downmix = true

        self.url = url
        self.file = file
        self.converter = converter
        self.staging = staging
        self.format = format
        sourceRate = input.sampleRate
        start = AVAudioFramePosition((max(0, offset) * rate).rounded())
        length = AVAudioFramePosition((Double(file.length) * rate / input.sampleRate).rounded(.up))
    }

    /// Up to `frames` of mono audio, or nil once the file has been read to
    /// its length. Throws if the file cannot be read that far — the caller
    /// must then give up rather than stand silence in for what it could not
    /// read.
    func next(_ frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard !spent, frames > 0 else { return nil }
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw ReadError.unsupported(url)
        }

        var error: NSError?
        let status = converter.convert(to: out, error: &error) { [self] _, status in
            // Bounded by framePosition: reading at the end throws rather than
            // returning nothing, so this is the one place the end is decided.
            guard file.framePosition < file.length else {
                status.pointee = .endOfStream
                return nil
            }
            staging.frameLength = 0
            do {
                try file.read(into: staging)
            } catch {
                pendingError = error
                status.pointee = .endOfStream
                return nil
            }
            guard staging.frameLength > 0 else {
                pendingError = ReadError.failed(url, CocoaError(.fileReadCorruptFile))
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return staging
        }

        if let pendingError {
            spent = true
            throw ReadError.failed(url, pendingError)
        }
        if status == .error {
            spent = true
            throw ReadError.failed(url, error ?? CocoaError(.fileReadUnknown))
        }
        if status == .endOfStream { spent = true }
        return out.frameLength > 0 ? out : nil
    }

    /// Put this track's part of the output block `[position, position +
    /// frames)` into `destination`, reading as many times as it takes: a
    /// resampling converter can hand back less than it was asked for, and a
    /// block left short would slide everything after it earlier on the clock.
    /// Blocks must be asked for in order. With `adding`, samples are summed
    /// into what is there rather than replacing it.
    ///
    /// Returns one past the last frame of the block this track wrote, or 0
    /// when it wrote nothing.
    func read(
        into destination: UnsafeMutablePointer<Float>,
        frames: AVAudioFrameCount,
        at position: AVAudioFramePosition,
        adding: Bool = false
    ) throws -> Int {
        let count = Int(frames)
        let lead = Int(max(0, start - position))
        guard lead < count else { return 0 }
        var filled = lead
        while filled < count, let chunk = try next(AVAudioFrameCount(count - filled)) {
            let samples = chunk.floatChannelData![0]
            let n = Int(chunk.frameLength)
            if adding {
                for i in 0..<n { destination[filled + i] += samples[i] }
            } else {
                destination.advanced(by: filled).update(from: samples, count: n)
            }
            filled += n
        }
        return filled > lead ? filled : 0
    }
}
