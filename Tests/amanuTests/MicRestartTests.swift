import AVFoundation
import Foundation
import Testing
import os

@testable import amanu

/// The bookkeeping around a mid-session capture restart. The capture itself
/// needs a real device and a real route change, so what is covered here is the
/// arithmetic that decides where the audio after a restart lands on the wall
/// clock, and the record left behind for the person reading meta.json a day
/// later.
struct MicRestartTests {
    @Test("Capture metadata distinguishes requested processing from what ran")
    func captureMetadataRecordsTheExperiment() throws {
        let capture = MicRecorder.Capture(
            requestedVoiceProcessing: true,
            initialVoiceProcessing: true,
            finalVoiceProcessing: false,
            inputDevice: "MacBook Air Microphone",
            outputDevice: "MacBook Air Speakers",
            sampleRate: 48_000,
            channels: 1,
            sampleFormat: "float32")

        let meta = capture.meta
        #expect(meta["requested_voice_processing"] as? Bool == true)
        #expect(meta["initial_voice_processing"] as? Bool == true)
        #expect(meta["final_voice_processing"] as? Bool == false)
        #expect(meta["fell_back_to_raw"] as? Bool == true)
        #expect(meta["input_device"] as? String == "MacBook Air Microphone")
        #expect(meta["output_device"] as? String == "MacBook Air Speakers")
        #expect(meta["sample_rate_hz"] as? Int == 48_000)
        #expect(meta["channels"] as? Int == 1)
        #expect(meta["sample_format"] as? String == "float32")
        #expect(JSONSerialization.isValidJSONObject(meta))
    }

    @Test func aGapWorthPaddingBecomesFrames() {
        #expect(MicRecorder.silenceFrames(gap: 0.5, sampleRate: 48000) == 24000)
        #expect(MicRecorder.silenceFrames(gap: 1.72, sampleRate: 16000) == 27520)
    }

    /// The threshold is what keeps ordinary buffer jitter from being written
    /// into the track as silence, one restart at a time.
    @Test func aGapTooShortToBeRealIsIgnored() {
        #expect(MicRecorder.silenceFrames(gap: 0.05, sampleRate: 48000) == 0)
        #expect(MicRecorder.silenceFrames(gap: 0, sampleRate: 48000) == 0)
        #expect(MicRecorder.silenceFrames(gap: -0.3, sampleRate: 48000) == 0)
    }

    /// While `avconferenced` runs voice processing on the built-in microphone,
    /// a restart finds it as three channels with no positions, and a converter
    /// left to its own map turned them into digital zeros — the whole of our
    /// side of a call handed over from the iPhone, on 30 September 2026.
    @Test(arguments: [
        kAudioChannelLayoutTag_DiscreteInOrder | 3,
        kAudioChannelLayoutTag_Unknown | 3,
    ])
    func threeUnplacedChannelsStillMakeAMonoTrack(_ tag: AudioChannelLayoutTag) throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: tag))
        let three = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false,
            channelLayout: layout)
        let mono = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let converter = try #require(MicRecorder.monoConverter(from: three, to: mono))

        let device = try #require(AVAudioPCMBuffer(pcmFormat: three, frameCapacity: 480))
        device.frameLength = 480
        for channel in 0..<3 {
            for frame in 0..<480 { device.floatChannelData![channel][frame] = 0.1 * Float(channel + 1) }
        }
        let track = try #require(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 480))
        try converter.convert(to: track, from: device)

        #expect(track.frameLength == 480)
        #expect(abs(track.floatChannelData![0][479] - 0.1) < 0.001)
    }

    /// Binding the call's microphone moves the node's hardware side and leaves
    /// its output side at the default device's rate — on 2 October 2026,
    /// AirPods at 24 kHz under a call on the 48 kHz built-in microphone — and
    /// AVFAudio refuses a raw tap in that rate. It ended the app twice in one
    /// call. Here the stale side is made by hand, on whatever microphone
    /// the Mac has. Before macOS 27 the refusal is an exception that would end
    /// the test run too.
    @Test(.enabled(if: AudioDevices.defaultInput() != nil
        && ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))))
    func aRawTapFollowsTheHardwareRatherThanAStaleOutputSide() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        var stale = hardware.streamDescription.pointee
        stale.mSampleRate = hardware.sampleRate == 24_000 ? 48_000 : 24_000
        let status = AudioUnitSetProperty(
            try #require(input.audioUnit), kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1, &stale, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        try #require(status == noErr)
        try #require(input.outputFormat(forBus: 0).sampleRate == stale.mSampleRate)

        #expect(throws: (any Error).self) {
            try MicRecorder.installTap(on: input, format: input.outputFormat(forBus: 0)) { _, _ in }
        }
        try MicRecorder.installTap(
            on: input, format: MicRecorder.tapFormat(of: input, voiceProcessing: false)
        ) { _, _ in }
        input.removeTap(onBus: 0)
    }

    @Test func aRestartRecordsBothSidesOfTheRouteChange() {
        let iso = ISO8601DateFormatter()
        let at = Date(timeIntervalSince1970: 1_755_710_180)
        var restart = MicRecorder.Restart(
            at: at,
            voiceProcessing: true,
            inputWas: "AirPods Pro", inputNow: "MacBook Pro Microphone",
            outputWas: "AirPods Pro", outputNow: "MacBook Pro Speakers"
        )
        restart.gapMs = 470

        let meta = restart.meta(iso: iso)
        #expect(meta["at"] as? String == iso.string(from: at))
        #expect(meta["gap_ms"] as? Int == 470)
        #expect(meta["voice_processing"] as? Bool == true)
        #expect(meta["input_was"] as? String == "AirPods Pro")
        #expect(meta["input_now"] as? String == "MacBook Pro Microphone")
        #expect(meta["output_was"] as? String == "AirPods Pro")
        #expect(meta["output_now"] as? String == "MacBook Pro Speakers")
    }

    /// A restart whose gap is still open, or that happened where no device
    /// would name itself, says less rather than saying nothing — and never
    /// puts nulls in meta.json.
    @Test func unknownFieldsAreLeftOutRatherThanWrittenNull() throws {
        let restart = MicRecorder.Restart(at: Date())
        let meta = restart.meta(iso: ISO8601DateFormatter())
        #expect(meta.count == 1)
        #expect(meta["at"] != nil)
        #expect(JSONSerialization.isValidJSONObject(meta))
    }

    // MARK: - which restart a gap belongs to

    /// The first buffer of a new engine can land before the restart that
    /// built it has been written up. The entry used to be appended only
    /// then, so that buffer's gap went onto the previous restart.
    @Test("A gap closed before its restart is written up still lands on that restart")
    func gapLandsOnItsOwnRestart() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var log = MicRecorder.RestartLog()

        let first = log.open(at: t, lastBufferAt: t)
        _ = log.close(now: t.addingTimeInterval(1.5), carried: 0)
        log.update(first) { $0.inputNow = "AirPods" }

        let second = log.open(at: t.addingTimeInterval(60), lastBufferAt: t.addingTimeInterval(60))
        // The new engine's first buffer, before the restart is written up.
        let gap = log.close(now: t.addingTimeInterval(60.4), carried: 0.1)
        log.update(second) { $0.inputNow = "MacBook Pro Microphone" }

        #expect(abs((gap ?? 0) - 0.3) < 0.001)
        #expect(log.entries.map(\.gapMs) == [1500, 300])
        #expect(log.entries.map(\.inputNow) == ["AirPods", "MacBook Pro Microphone"])
    }

    @Test("A restart that fails and retries is one gap, measured from the first attempt")
    func retriesAreOneGap() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var log = MicRecorder.RestartLog()
        let first = log.open(at: t, lastBufferAt: t)
        let again = log.open(at: t.addingTimeInterval(2), lastBufferAt: t)
        #expect(first == again)
        #expect(log.entries.count == 1)
        #expect(log.close(now: t.addingTimeInterval(4), carried: 0) == 4)
        #expect(log.recent(within: 30, of: t.addingTimeInterval(5)) == 1)
    }

    @Test("The storm guard does not count the restart under way")
    func stormCountExcludesTheOpenRestart() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        var log = MicRecorder.RestartLog()
        log.open(at: t, lastBufferAt: t)
        #expect(log.recent(within: 30, of: t) == 0)
    }

    // MARK: - microphones that refuse

    /// A call app on a microphone that will not let us record it used to be
    /// chased every fifteen seconds: restart, refusal, fall back to the
    /// default, and the next route check found the same device again.
    @Test("A microphone that refused is not followed again until its wait is over")
    func refusedMicrophoneIsNotChased() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let zoomMic: AudioObjectID = 71, builtIn: AudioObjectID = 42
        var refused = MicRecorder.RefusedDevices()

        #expect(MicRecorder.routeTarget(wanted: zoomMic, fallback: builtIn, refused: refused, now: t)
                == zoomMic)
        refused.refuse(zoomMic, at: t)
        for tick in stride(from: 15.0, to: 60, by: 15) {
            #expect(MicRecorder.routeTarget(
                wanted: zoomMic, fallback: builtIn, refused: refused, now: t.addingTimeInterval(tick))
                    == builtIn)
        }
        #expect(MicRecorder.routeTarget(
            wanted: zoomMic, fallback: builtIn, refused: refused, now: t.addingTimeInterval(61))
                == zoomMic)

        // Refused again: twice as long before the next try.
        refused.refuse(zoomMic, at: t.addingTimeInterval(61))
        #expect(refused.isRefused(zoomMic, at: t.addingTimeInterval(61 + 119)))
        #expect(!refused.isRefused(zoomMic, at: t.addingTimeInterval(61 + 121)))
        #expect(MicRecorder.RefusedDevices.wait(afterRefusals: 20) == 15 * 60)
    }

    // MARK: - bringing capture up

    struct Refused: Error {}

    /// At the start of a session a single refusal used to fail the whole
    /// recording, system track included, while the same refusal mid-session
    /// already fell back.
    @Test("A chosen microphone that refuses gives way to the default, voice processing still on")
    func chosenDeviceGivesWayFirst() throws {
        var attempts: [Bool] = []
        var chosen = true
        try MicRecorder.attachWithFallbacks(
            voiceProcessing: true,
            attempt: { voice in
                attempts.append(voice)
                if chosen { chosen = false; throw Refused() }
            },
            failedOnChosenDevice: { attempts.count == 1 })
        #expect(attempts == [true, true])
    }

    @Test("Voice processing that will not start gives way to raw capture")
    func voiceGivesWayToRaw() throws {
        var attempts: [Bool] = []
        try MicRecorder.attachWithFallbacks(
            voiceProcessing: true,
            attempt: { voice in
                attempts.append(voice)
                if voice { throw Refused() }
            },
            failedOnChosenDevice: { false })
        #expect(attempts == [true, false])
    }

    @Test("Capture that will not start any way at all is an error")
    func nothingWorksThrows() {
        var attempts: [Bool] = []
        #expect(throws: Refused.self) {
            try MicRecorder.attachWithFallbacks(
                voiceProcessing: false,
                attempt: { voice in attempts.append(voice); throw Refused() },
                failedOnChosenDevice: { false })
        }
        #expect(attempts == [false])
    }

    // MARK: - writing after a gap

    private func readSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func constant(_ value: Float, frames: Int, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        buffer.floatChannelData![0].update(repeating: value, count: frames)
        return buffer
    }

    /// The silence for a gap is written off the capture callback, and the
    /// audio that follows it must still come after it, in order.
    @Test("Audio after a gap reaches the file after its silence, in order")
    func writerKeepsOrderAcrossAGap() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-writer-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false)!
        do {
            let file = try AVAudioFile(
                forWriting: url,
                settings: AudioFormats.pcmSettings(sampleRate: 8_000, channels: 1),
                commonFormat: .pcmFormatFloat32, interleaved: false)
            let writer = TrackWriter(file: file, label: "test")
            writer.write(constant(0.5, frames: 100, format: format))
            writer.write(constant(0.25, frames: 100, format: format), after: 20_000)
            for _ in 0..<5 { writer.write(constant(0.125, frames: 100, format: format)) }
            writer.drain()
        }

        let samples = try readSamples(url)
        #expect(samples.count == 100 + 20_000 + 100 + 500)
        #expect(samples[0..<100].allSatisfy { abs($0 - 0.5) < 0.001 })
        #expect(samples[100..<20_100].allSatisfy { $0 == 0 })
        #expect(samples[20_100..<20_200].allSatisfy { abs($0 - 0.25) < 0.001 })
        #expect(samples[20_200...].allSatisfy { abs($0 - 0.125) < 0.001 })
    }

    @Test("A restart's meta says how much of a very long gap was padded")
    func paddedShortOfTheGapIsRecorded() {
        var restart = MicRecorder.Restart(at: Date())
        restart.gapMs = 3_600_000
        restart.paddedMs = Int(MicRecorder.longestPad * 1000)
        let meta = restart.meta(iso: ISO8601DateFormatter())
        #expect(meta["gap_ms"] as? Int == 3_600_000)
        #expect(meta["padded_ms"] as? Int == 600_000)
    }

    /// The engine posts a configuration change from a queue of its own, and a
    /// restart on main waits for that queue: `-[AVAudioEngine dealloc]` syncs
    /// onto it. So the post must not wait for main in turn, and with the
    /// observer on `queue: .main` it did — a change arriving mid-restart hung
    /// amanu for good on 29 September 2026. Main is held here the same way.
    @MainActor
    @Test func aConfigurationChangeIsPostedWithoutWaitingForMain() async {
        let ranOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let observer = MicRecorder.observeConfigurationChanges { _ in
            ranOnMain.withLock { $0 = Thread.isMainThread }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        #expect(Self.postHoldingThisThread(for: 2) == .success)

        // The handler still runs on main, where the restart's state lives.
        for _ in 0..<200 where ranOnMain.withLock({ $0 }) == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(ranOnMain.withLock { $0 } == true)
    }

    /// Post a configuration change from another thread and block this one
    /// until the post returns. Synchronous on purpose: blocking is the point,
    /// and an async caller may not wait on a semaphore itself.
    private static func postHoldingThisThread(for seconds: Double) -> DispatchTimeoutResult {
        let posted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
            posted.signal()
        }
        return posted.wait(timeout: .now() + seconds)
    }
}
