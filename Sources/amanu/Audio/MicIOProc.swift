@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import os.lock

/// The raw microphone track's capture: an IO proc on the microphone itself,
/// the way `SystemAudioRecorder` reads its tap.
///
/// Not `AVAudioEngine`, because an engine's input node joins the default
/// device's aggregate before it can be pointed anywhere else. AirPods are two
/// devices, an input and an output, so while they were the default every
/// attach waited for them to change mode — `SetBluetoothAudioFormatAndWait`,
/// on a three-second timeout — even to record the built-in microphone, which
/// AirPods have nothing to do with. Those waits were the seconds missing from
/// the mic track at every AirPods change, and one of them held main for
/// eleven minutes (`.issues/011`). Measured on 7 October 2026 with AirPods the
/// default: an IO proc on the built-in microphone had its first buffer in
/// 94 ms, 100 at worst, fourteen times in fourteen; an engine bound to the
/// same microphone took 3.4 s, and four times in fourteen never delivered.
///
/// Everything here can wait on the device — creating the proc, starting and
/// stopping it — so none of it is called on main.
final class MicIOProc {
    let device: AudioObjectID
    /// What the proc delivers: the device's first input stream, in the format
    /// Core Audio hands IO procs. The first stream holds the first channel,
    /// and the first channel is all the track takes.
    let format: AVAudioFormat
    private var proc: AudioDeviceIOProcID?
    private var queue: DispatchQueue?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// Raised the moment the device reports another rate or another input
    /// layout, and lowered by `trust(asOf:)` once the caller has found its
    /// format the same after all. Buffers in between are not read: they may
    /// already be in the new format, and a new rate with the same channels
    /// would be read at the old one — the wrong speed, and the wrong length —
    /// until the restart the change brings. What they carried is counted as
    /// missed. `alarms` counts the raisings, so that a look at the device
    /// taken before the latest one cannot lower it.
    private let suspect = OSAllocatedUnfairLock(initialState: (raised: false, alarms: 0))

    /// What a running proc listens for: the device going away, and the two
    /// ways its input changes shape underneath — another rate (AirPods
    /// between their modes) and another channel count (the built-in
    /// microphone while `avconferenced` has it; see `MicRecorder.rawGain`).
    private static let watched: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
        (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
        (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
    ]

    init(device: AudioObjectID) throws {
        guard let format = Self.format(of: device) else {
            throw MicRecorder.RecorderError.deviceUnreadable(device)
        }
        self.device = device
        self.format = format
    }

    /// Start handing the device's buffers to `body`, on `queue`, one at a
    /// time. Each buffer is Core Audio's memory, lent for the length of the
    /// call, and comes with the frames of the device's that went by unread
    /// since the one before it, for the caller to write as silence: cycles
    /// Core Audio skipped when an IO thread overran ("skipping cycle due to
    /// overload"), and buffers dropped here. `changed` is called — on a Core
    /// Audio thread, on `queue`, or on this one when the device changed
    /// while it started — whenever the device may have gone away or changed
    /// shape; whether it has is the caller's question to ask.
    func start(
        on queue: DispatchQueue,
        changed: @escaping () -> Void,
        body: @escaping (AVAudioPCMBuffer, _ missed: AVAudioFrameCount) -> Void
    ) throws {
        let suspect = suspect
        for (selector, scope) in Self.watched {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            let reshaped = selector != kAudioDevicePropertyDeviceIsAlive
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                if reshaped { suspect.withLock { $0 = (true, $0.alarms + 1) } }
                changed()
            }
            // No queue: the block runs on Core Audio's own thread, and all it
            // does is pass the news on.
            if AudioObjectAddPropertyListenerBlock(device, &address, nil, listener) == noErr {
                listeners.append((address, listener))
            }
        }

        let format = format
        let channels = format.channelCount
        let frameBytes = format.streamDescription.pointee.mBytesPerFrame
        let rate = format.sampleRate
        // Held to the longest silence a restart pads, and kept a frame count
        // that converts: a clock that leapt would otherwise trap.
        let mostMissed = MicRecorder.longestPad * rate
        // The last buffer read, on the device's clock and on the host's: the
        // next one ought to start where it ended. A jump past that is audio
        // that never reached this proc — but never more than the host's clock
        // says went by, so a device that restarts its timeline somewhere ahead
        // gets no silence written that never was. Only the IO block touches
        // it, and Core Audio calls that one cycle at a time.
        var last: (sample: Float64, host: UInt64?, frames: Float64)?
        var status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, inputTime, _, _ in
            guard !suspect.withLock({ $0.raised }) else { return }
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard let first = buffers.first, first.mNumberChannels == channels,
                  frameBytes > 0, first.mDataByteSize % frameBytes == 0
            else {
                // Read in the format the proc was opened with, a buffer of
                // another shape is noise — and a sign the device has changed.
                changed()
                return
            }
            var missed: AVAudioFrameCount = 0
            let time = inputTime.pointee
            let frames = Float64(first.mDataByteSize / frameBytes)
            if time.mFlags.contains(.sampleTimeValid) {
                let host = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : nil
                if let last {
                    var jump = time.mSampleTime - last.sample - last.frames
                    if let host, let before = last.host, host > before {
                        let went = Double(AudioConvertHostTimeToNanos(host - before)) / 1e9 * rate
                        jump = min(jump, went - last.frames)
                    }
                    if jump >= 1 { missed = AVAudioFrameCount(min(jump, mostMissed)) }
                }
                last = (time.mSampleTime, host, frames)
            } else {
                last = nil
            }
            var one = AudioBufferList(mNumberBuffers: 1, mBuffers: first)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, bufferListNoCopy: &one, deallocator: nil
            ) else { return }
            body(buffer, missed)
        }
        guard status == noErr, let proc else {
            stop()
            throw MicRecorder.RecorderError.ioProcCreationFailed(status)
        }
        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            stop()
            throw MicRecorder.RecorderError.deviceStartFailed(status)
        }
        self.queue = queue
        // A change between reading the format and listening for one would
        // otherwise go unheard until the next.
        if Self.format(of: device)?.isEqual(format) != true {
            suspect.withLock { $0 = (true, $0.alarms + 1) }
            changed()
        }
    }

    /// How many times the device has said its format may have changed: what
    /// a look at the device is taken as of, for `trust(asOf:)`.
    var alarms: Int { suspect.withLock { $0.alarms } }

    /// The device was found in the format this proc reads, by a look taken
    /// when `alarms` was `asOf`: its buffers are read again, and the ones
    /// dropped meanwhile are missed — unless the device has raised the alarm
    /// since, when the look is out of date and the alarm stands.
    func trust(asOf alarms: Int) {
        suspect.withLock { if $0.alarms == alarms { $0.raised = false } }
    }

    /// Stop the proc and stop listening. When this returns, no buffer of this
    /// proc is being handled, and none will be.
    func stop() {
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
            self.proc = nil
        }
        for (address, listener) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, nil, listener)
        }
        listeners = []
        queue?.sync {}
        queue = nil
    }

    /// The format an IO proc on `device` receives its first input stream in,
    /// or nil when the device has no input or will not say.
    static func format(of device: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioStreamID>.size)
        else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr,
              let first = streams.first
        else { return nil }

        address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var description = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(first, &address, 0, nil, &size, &description) == noErr
        else { return nil }
        return format(description)
    }

    /// `description` as an `AVAudioFormat`. Past two channels AVAudioFormat
    /// insists on a layout and Core Audio gives none — the three channels of
    /// the built-in microphone under `avconferenced` come back nil without
    /// one — so they are taken as discrete, in order.
    static func format(_ description: AudioStreamBasicDescription) -> AVAudioFormat? {
        var description = description
        guard description.mChannelsPerFrame > 2 else {
            return AVAudioFormat(streamDescription: &description)
        }
        guard let layout = AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | description.mChannelsPerFrame)
        else { return nil }
        return AVAudioFormat(streamDescription: &description, channelLayout: layout)
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }
}
