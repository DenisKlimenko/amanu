@preconcurrency import AVFoundation
import Foundation
import os.lock

// The bookkeeping `MicRecorder` does around a capture restart, kept apart from
// the engine so that it can be tested without one. None of it touches a
// device; all of it decides something a device cannot tell you afterwards —
// which restart a gap belongs to, which microphone not to try again, and in
// what order the audio after a gap reaches the file.

extension MicRecorder {
    /// Every restart of a session and the one whose dead span is still open.
    ///
    /// A restart is entered in the log when it begins, not once the new engine
    /// is running. The first buffer of that engine is what measures the gap,
    /// and it can arrive before the restart has been written up; when the
    /// entry was only added afterwards, that buffer put its gap on the
    /// previous restart and left this one without.
    struct RestartLog {
        private(set) var entries: [Restart] = []
        /// The restart whose gap no buffer has closed yet.
        private(set) var openIndex: Int?
        /// Where that gap began: the last buffer of the engine that went away.
        private(set) var gapSince: Date?

        /// Begin a restart, or return the one already under way. Idempotent on
        /// purpose: a restart that fails and retries is still one gap, and
        /// moving its start forward would swallow the time the retries took.
        @discardableResult
        mutating func open(at now: Date, lastBufferAt: Date?) -> Int {
            if let openIndex { return openIndex }
            entries.append(Restart(at: now))
            openIndex = entries.count - 1
            gapSince = lastBufferAt
            return entries.count - 1
        }

        /// Close the open gap for a buffer that arrived at `now` carrying
        /// `carried` seconds of audio. Returns the seconds of silence that
        /// belong in front of it, or nil when no gap was open or nothing had
        /// been recorded before it to measure against.
        mutating func close(now: Date, carried: TimeInterval) -> TimeInterval? {
            guard let index = openIndex else { return nil }
            openIndex = nil
            defer { gapSince = nil }
            guard let since = gapSince else { return nil }
            let gap = now.timeIntervalSince(since) - carried
            entries[index].gapMs = Int((max(gap, 0) * 1000).rounded())
            return gap
        }

        /// Record that less silence was written than the gap measured.
        mutating func notePadded(_ seconds: TimeInterval, forEntry index: Int) {
            guard entries.indices.contains(index) else { return }
            entries[index].paddedMs = Int(seconds * 1000)
        }

        /// Nothing will arrive to close the gap now; the track ends where the
        /// audio ended.
        mutating func abandon() {
            openIndex = nil
            gapSince = nil
        }

        mutating func update(_ index: Int, _ change: (inout Restart) -> Void) {
            guard entries.indices.contains(index) else { return }
            change(&entries[index])
        }

        /// Restarts other than the one under way that began within `window`
        /// of `now` — the storm guard's count.
        func recent(within window: TimeInterval, of now: Date) -> Int {
            entries.indices.filter {
                $0 != openIndex && now.timeIntervalSince(entries[$0].at) < window
            }.count
        }
    }

    /// Microphones that refused to be recorded this session, and until when
    /// they are not asked again.
    ///
    /// Without it a refusal was forgotten as soon as capture fell back to the
    /// default: the next tick of the route check saw the call app on the
    /// refused device, restarted to follow it, was refused again, and fell
    /// back — every fifteen seconds for the rest of the meeting, four seconds
    /// of silence in the track each time, spaced just wide enough that the
    /// storm guard never tripped. The wait doubles with each refusal, so a
    /// device that comes good later is still followed, and one that never
    /// does costs a restart every quarter of an hour at most.
    struct RefusedDevices {
        private var entries: [AudioObjectID: (until: Date, refusals: Int)] = [:]

        static let firstWait: TimeInterval = 60
        static let longestWait: TimeInterval = 15 * 60

        static func wait(afterRefusals refusals: Int) -> TimeInterval {
            let doublings = Double(max(0, min(refusals - 1, 16)))
            return min(firstWait * pow(2, doublings), longestWait)
        }

        mutating func refuse(_ device: AudioObjectID, at now: Date) {
            let refusals = (entries[device]?.refusals ?? 0) + 1
            entries[device] = (now.addingTimeInterval(Self.wait(afterRefusals: refusals)), refusals)
        }

        func isRefused(_ device: AudioObjectID, at now: Date) -> Bool {
            entries[device].map { now < $0.until } ?? false
        }
    }

    /// The microphone to bind: the one the call app is on, unless it is the
    /// default anyway — the engine picks that up by itself — or it has refused
    /// recently, in which case the default, which is where capture would have
    /// ended up after the refusal regardless.
    static func routeTarget(
        wanted: AudioObjectID?,
        fallback: AudioObjectID?,
        refused: RefusedDevices,
        now: Date
    ) -> AudioObjectID? {
        guard let wanted, wanted != fallback, !refused.isRefused(wanted, at: now) else {
            return fallback
        }
        return wanted
    }

    /// Bring capture up, retreating one step at a time: a microphone of our
    /// choosing that refuses is given up for the default, and voice
    /// processing that will not start is given up for raw capture. Raw is
    /// worse than cancelled, and both beat no microphone — at the start of a
    /// session as much as in the middle of one, where these fallbacks already
    /// were; at the start a single refusal used to fail the whole recording,
    /// system track included.
    ///
    /// `attempt` brings capture up once and reports, when it fails, whether
    /// it had bound a microphone other than the default. That device has been
    /// marked refused by then, so the same attempt again lands on the default.
    static func attachWithFallbacks(
        voiceProcessing: Bool,
        attempt: (_ voiceProcessing: Bool) throws -> Void,
        failedOnChosenDevice: () -> Bool
    ) throws {
        var lastError: Error?
        for voice in voiceProcessing ? [true, false] : [false] {
            for _ in 0..<2 {
                do {
                    try attempt(voice)
                    return
                } catch {
                    lastError = error
                    guard failedOnChosenDevice() else { break }
                }
            }
        }
        throw lastError ?? RecorderError.engineStartFailed(CocoaError(.featureUnsupported))
    }

    /// The longest dead span written into the track as silence. A route
    /// change is seconds; anything near this is a machine that stopped
    /// delivering audio for reasons of its own, and writing it all out is
    /// hundreds of megabytes for one alignment. What is left over is in
    /// meta.json, as `gap_ms` beside a smaller `padded_ms`.
    static let longestPad: TimeInterval = 10 * 60
}

/// Writes one track's buffers to its file, in order, without making the
/// capture callback wait for a long run of silence.
///
/// Closing a gap after a restart means writing its whole length as silence
/// ahead of the buffer that closed it. That used to happen inside the tap
/// callback, a second at a time — for an ordinary route change a few
/// kilobytes, for a Mac that slept with the lid shut, as much silence as the
/// sleep was long. Now a buffer that brings a gap with it goes to a serial
/// queue, silence first, and so does every buffer after it until the queue
/// has caught up; then writing returns to the callback. Only the callback
/// adds work, and the queue only removes it after the write, so the file
/// never has two writers at once and never sees audio out of order.
final class TrackWriter: @unchecked Sendable {
    let file: AVAudioFile
    private let label: String
    private let queue: DispatchQueue
    /// Buffers handed to the queue and not yet written.
    private let queued = OSAllocatedUnfairLock(initialState: 0)

    init(file: AVAudioFile, label: String) {
        self.file = file
        self.label = label
        queue = DispatchQueue(label: "me.samat.amanu.\(label)-writer")
    }

    /// Write `buffer`, preceded by `silence` frames of zeros. Called from the
    /// capture callback, and only from there.
    func write(_ buffer: AVAudioPCMBuffer, after silence: AVAudioFrameCount = 0) {
        let deferred = queued.withLock { count -> Bool in
            guard silence > 0 || count > 0 else { return false }
            count += 1
            return true
        }
        guard deferred else {
            append(buffer)
            return
        }
        // The callback's buffer is only lent to it; the queue needs its own.
        guard let copy = Self.copy(buffer) else {
            queued.withLock { $0 -= 1 }
            report("couldn't copy a buffer to write after a gap — dropped")
            return
        }
        queue.async { [self] in
            writeSilence(frames: silence)
            append(copy)
            queued.withLock { $0 -= 1 }
        }
    }

    /// Wait until everything handed to the queue is in the file.
    func drain() {
        queue.sync {}
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        do {
            try file.write(from: buffer)
        } catch {
            report("track write failed: \(error)")
        }
    }

    private func writeSilence(frames: AVAudioFrameCount) {
        let format = file.processingFormat
        let chunk = AVAudioFrameCount(format.sampleRate)
        guard frames > 0, let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)
        else { return }
        block.frameLength = chunk
        for buffer in UnsafeMutableAudioBufferListPointer(block.mutableAudioBufferList) {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        var remaining = frames
        while remaining > 0 {
            let n = min(remaining, chunk)
            block.frameLength = n
            append(block)
            remaining -= n
        }
    }

    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format, frameCapacity: max(buffer.frameLength, 1))
        else { return nil }
        copy.frameLength = buffer.frameLength
        let from = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (source, destination) in zip(from, to) {
            guard let src = source.mData, let dst = destination.mData else { return nil }
            memcpy(dst, src, Int(min(source.mDataByteSize, destination.mDataByteSize)))
        }
        return copy
    }

    private func report(_ message: String) {
        FileHandle.standardError.write(Data("\(label): \(message)\n".utf8))
    }
}
