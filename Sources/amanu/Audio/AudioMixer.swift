import AVFoundation
import Foundation

/// Mixes a session's tracks down to one file on the shared clock — each track
/// laid in at its own start offset, so the mix has the same timeline the
/// two-track transcript would.
///
/// This exists for diarizing engines: they need a single stream with everybody
/// on it, and there's no way to diarize across two files. The output is m4a
/// (AAC in MP4) rather than CAF because it goes to an API — m4a is what
/// everything accepts. Unlike the source tracks, the mix isn't crash-safe, but
/// it doesn't need to be: it's derived, and regenerating it costs seconds.
///
/// The samples are summed by hand rather than by `AVAssetExportSession`, and
/// that is not a stylistic preference. The export path drags in AVFoundation's
/// whole media-library machinery, and macOS answers that by asking the user for
/// Photos, Media & Apple Music and Documents-folder access — three scary
/// dialogs, mid-meeting, from a program that has no business near any of them.
/// (Confirmed by the clock: "mixing tracks" at 12:28:31, three prompts at
/// 12:28:45–50.) Reading frames through `AVAudioFile`, adding them, and writing
/// them back asks for nothing.
enum AudioMixer {
    struct Track: Sendable {
        let url: URL
        let offset: TimeInterval
    }

    enum MixError: Error, CustomStringConvertible {
        case noUsableTracks
        case outputUnavailable(Error)

        var description: String {
            switch self {
            case .noUsableTracks: return "no readable audio tracks to mix"
            case .outputUnavailable(let error): return "couldn't open the mix for writing: \(error)"
            }
        }
    }

    /// Write `tracks` mixed down into `output`, replacing whatever was there.
    ///
    /// A track that is missing or holds no frames is left out — one track that
    /// never recorded should not cost the other its transcript. A track that
    /// is there and cannot be read is another matter, and throws: mixing
    /// without it produced a one-sided transcript that reported success, and
    /// after it the audio was settled like any other — the recoverable track
    /// deleted along with the rest.
    ///
    /// The mix is written beside `output` and renamed onto it only when
    /// complete. The transcription coordinator reuses a `mixed.m4a` it finds,
    /// so a mix interrupted halfway used to be transcribed as the meeting.
    static func mix(_ tracks: [Track], to output: URL) async throws {
        // Off the cooperative pool: this is a few seconds of solid arithmetic
        // and encoding per hour of meeting, and the pool has a recording to run.
        try await Task.detached(priority: .utility) { try mixNow(tracks, to: output) }.value
    }

    // MARK: -

    /// Where a mix is written before it is complete. Still `.m4a`, because
    /// `AVAudioFile` chooses the container by extension.
    static func temporary(for output: URL) -> URL {
        output.deletingPathExtension().appendingPathExtension("tmp.m4a")
    }

    /// One second of output at a time. Big enough that the per-block bookkeeping
    /// disappears next to the arithmetic, small enough that an hour-long meeting
    /// never holds more than a few hundred kilobytes of audio in memory — the
    /// mistake the predecessor made was keeping whole meetings resident.
    private static func mixNow(_ tracks: [Track], to output: URL) throws {
        let present = try tracks.compactMap { track -> (Track, Double)? in
            guard FileManager.default.fileExists(atPath: track.url.path) else { return nil }
            do {
                return (track, try AudioTrackReader(url: track.url).sourceRate)
            } catch AudioTrackReader.ReadError.empty {
                return nil
            }
        }
        // Mono, at the fastest rate any source runs at: the mix is speech
        // headed for a transcriber, so a second channel would only carry the
        // same words twice, and downsampling is a decision better left to
        // whoever consumes it.
        guard let rate = present.map(\.1).max(),
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        else { throw MixError.noUsableTracks }
        let readers = try present.map {
            try AudioTrackReader(url: $0.0.url, rate: rate, offset: $0.0.offset)
        }
        let blockFrames = AVAudioFrameCount(rate)

        let temporary = temporary(for: output)
        try? FileManager.default.removeItem(at: temporary)
        do {
            try write(readers, format: format, blockFrames: blockFrames, to: temporary)
            // AVAudioFile won't overwrite, and a leftover from a failed run
            // would otherwise wedge every retry.
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: temporary, to: output)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// The mixing itself. A function of its own so the output file is closed
    /// — it is, when it goes out of scope — before anything renames it.
    private static func write(
        _ readers: [AudioTrackReader],
        format: AVAudioFormat,
        blockFrames: AVAudioFrameCount,
        to url: URL
    ) throws {
        // Two blocks in rotation plus a silent one. Two, because the last block
        // of the mix is the only one allowed to be short and there is no way to
        // know a block is the last until the next one comes back empty — so one
        // block is always held back, written in full once something follows it
        // and trimmed to its real length if nothing does. Getting this wrong
        // rounds the mix up to the next whole second and slides nothing else,
        // which is exactly the kind of bug a duration assertion catches and an
        // ear doesn't.
        guard
            let first = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames),
            let second = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames),
            let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames)
        else { throw MixError.noUsableTracks }
        silence.frameLength = blockFrames
        silence.floatChannelData![0].update(repeating: 0, count: Int(blockFrames))

        let file: AVAudioFile
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: format.sampleRate,
                    AVNumberOfChannelsKey: 1,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false)
        } catch {
            throw MixError.outputUnavailable(error)
        }

        var work = first
        var pending: AVAudioPCMBuffer?
        var pendingFrames = 0
        /// Blocks that came out entirely silent since `pending`. Held rather
        /// than written, because a run of them at the very end is just the tail
        /// of the shorter track and belongs nowhere; anywhere else they're a
        /// real gap on the shared clock and get written out in full.
        var gap = 0
        var position: AVAudioFramePosition = 0

        while readers.contains(where: { !$0.spent }) {
            let mixed = work.floatChannelData![0]
            mixed.update(repeating: 0, count: Int(blockFrames))
            var filled = 0

            for reader in readers where !reader.spent {
                filled = max(filled, try reader.read(
                    into: mixed, frames: blockFrames, at: position, adding: true))
            }
            position += AVAudioFramePosition(blockFrames)

            guard filled > 0 else {
                gap += 1
                continue
            }
            // Two people talking at once can sum past full scale. Clamping
            // costs a moment of flattened peak; letting the encoder deal with
            // it costs a burst of noise over the loudest words.
            for i in 0..<filled { mixed[i] = min(1, max(-1, mixed[i])) }

            var free = work === first ? second : first
            if let held = pending {
                held.frameLength = blockFrames
                try file.write(from: held)
                free = held
            }
            for _ in 0..<gap { try file.write(from: silence) }
            gap = 0

            pending = work
            pendingFrames = filled
            work = free
        }

        if let held = pending, pendingFrames > 0 {
            held.frameLength = AVAudioFrameCount(pendingFrames)
            try file.write(from: held)
        }
    }
}
