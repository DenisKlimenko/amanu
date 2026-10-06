import AVFoundation
import CoreAudio
import Foundation
import Testing
import os

@testable import amanu

/// The raw mic track's capture, read off the device itself. What a call does
/// to a device needs a call; what is covered here is the format a device is
/// read in, the track a capture claims, and — opted into — a proc and a
/// recording against whatever microphone this Mac has.
struct MicIOProcTests {
    /// Opt in with AMANU_RUN_MIC_TEST=1, here and for every other test that
    /// opens the default microphone: its indicator lights, AirPods that are
    /// the default switch to headset mode, and an amanu running alongside
    /// that records any app records the test — on 7 October 2026, twice, each
    /// time all the way to a summary.
    static let liveMic = ProcessInfo.processInfo.environment["AMANU_RUN_MIC_TEST"] == "1"
        && AudioDevices.defaultInput() != nil

    /// What an IO proc gets from the built-in microphone while `avconferenced`
    /// has it: one stream of three interleaved channels. AVAudioFormat will
    /// not describe that without a layout, and the track still has to be
    /// channel 0, ten times louder.
    @Test func threeInterleavedChannelsFromAProcMakeAMonoTrackOfTheFirst() throws {
        let description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 12, mFramesPerPacket: 1, mBytesPerFrame: 12,
            mChannelsPerFrame: 3, mBitsPerChannel: 32, mReserved: 0)
        var plain = description
        #expect(AVAudioFormat(streamDescription: &plain) == nil)
        let three = try #require(MicIOProc.format(description))
        #expect(three.channelCount == 3)
        #expect(MicRecorder.rawGain(for: three) == 10)

        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 480 * 3)
        defer { samples.deallocate() }
        let levels: [Float] = [0.05, 0.2, 0.3]
        for frame in 0..<480 {
            for channel in 0..<3 { samples[frame * 3 + channel] = levels[channel] }
        }
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 3, mDataByteSize: 480 * 12, mData: samples))
        let device = try #require(
            AVAudioPCMBuffer(pcmFormat: three, bufferListNoCopy: &list, deallocator: nil))
        #expect(device.frameLength == 480)

        let mono = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let converter = try #require(MicRecorder.monoConverter(from: three, to: mono))
        let track = try #require(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 480))
        try converter.convert(to: track, from: device)
        MicRecorder.amplify(track, by: MicRecorder.rawGain(for: three))
        #expect(track.frameLength == 480)
        #expect(abs(track.floatChannelData![0][479] - 0.5) < 0.001)
    }

    /// A microphone that has gone — AirPods back in their case — has no
    /// format to open and is not alive, which is how a restart tells it from
    /// one that refused.
    @Test func aDeviceThatIsNotThereHasNoFormatAndIsNotAlive() {
        let missing = AudioObjectID(kAudioObjectUnknown)
        #expect(MicIOProc.format(of: missing) == nil)
        #expect(!MicIOProc.isAlive(missing))
        #expect(throws: (any Error).self) { _ = try MicIOProc(device: missing) }
    }

    /// A capture retired while its device was opening — the session stopped,
    /// or a newer restart overtook it — leaves the track as it was. Deciding
    /// on the file apart from that check, an open found it let go by the stop,
    /// created it again over the meeting in it, and then deleted it.
    @Test func aCaptureRetiredWhileItsDeviceOpenedLeavesTheTrackAlone() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-mic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let track = folder.appendingPathComponent("mic.caf")
        let meeting = Data("the meeting so far".utf8)
        try meeting.write(to: track)
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))

        let recorder = MicRecorder()
        // What a stop does first, while the open still carries generation 0.
        _ = recorder.retireCapture(at: Date())
        #expect(throws: CancellationError.self) {
            _ = try recorder.claimTrack(for: input, at: track, generation: 0)
        }
        #expect(try Data(contentsOf: track) == meeting)

        // The capture that is current gets a file, created once and shared.
        let fresh = folder.appendingPathComponent("fresh.caf")
        let created = try recorder.claimTrack(for: input, at: fresh, generation: 1)
        #expect(!created.reusedFile)
        #expect(try recorder.claimTrack(for: input, at: fresh, generation: 1).reusedFile)
    }

    /// A proc on the default microphone: the frames it delivers, with the
    /// ones it reports missed, cover the time they took, and nothing comes
    /// once it has stopped. A frame count misread from the buffer's bytes, or
    /// a jump on the device's clock misread as missed audio, fails here.
    @Test(.enabled(if: MicIOProcTests.liveMic))
    func aProcDeliversTheDevicesTimeUntilItStops() async throws {
        let proc = try MicIOProc(device: try #require(AudioDevices.defaultInput()))
        let rate = proc.format.sampleRate
        let seen = OSAllocatedUnfairLock(
            initialState: (buffers: 0, frames: 0.0, first: Date?.none, last: Date?.none))
        // What `MicRecorder.checkDevice` does with an alarm: one that turns
        // out false — AirPods settling into headset mode as the proc opens
        // them — lets the proc read again.
        let changed = { [proc] in
            let alarms = proc.alarms
            if MicIOProc.format(of: proc.device)?.isEqual(proc.format) == true {
                proc.trust(asOf: alarms)
            }
        }
        try proc.start(on: DispatchQueue(label: "test-mic-io"), changed: changed) { buffer, missed in
            let now = Date(), frames = Double(buffer.frameLength) + Double(missed)
            seen.withLock {
                $0.buffers += 1
                // The first buffer's audio is from before it arrived.
                if $0.first == nil { $0.first = now } else { $0.frames += frames }
                $0.last = now
            }
        }
        for _ in 0..<300 where seen.withLock({ $0.buffers }) < 50 {
            try await Task.sleep(for: .milliseconds(10))
        }
        proc.stop()
        let atStop = seen.withLock { $0 }
        try await Task.sleep(for: .milliseconds(200))

        #expect(atStop.buffers >= 50)
        let first = try #require(atStop.first), last = try #require(atStop.last)
        let took = last.timeIntervalSince(first)
        #expect(abs(atStop.frames / rate - took) < max(0.05, took * 0.2))
        #expect(seen.withLock { $0.buffers } == atStop.buffers)
    }

    /// The raw path end to end on the default microphone: a stretch of
    /// recording leaves that much track, give or take a buffer.
    @MainActor @Test(.enabled(if: MicIOProcTests.liveMic))
    func aRecordingLastsAsLongAsItTook() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-mic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("mic.caf")

        let recorder = MicRecorder()
        try recorder.start(writingTo: url)
        for _ in 0..<300 where recorder.firstBufferAt == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let first = try #require(recorder.firstBufferAt)
        try await Task.sleep(for: .seconds(1))
        let took = Date().timeIntervalSince(first)
        recorder.stop()

        let file = try AVAudioFile(forReading: url)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - took) < 0.1)
    }
}
