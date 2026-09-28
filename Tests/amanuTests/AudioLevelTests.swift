import AVFoundation
import Foundation
import Testing

@testable import amanu

/// The level meter runs inside both capture callbacks, so anything it can trap
/// on ends a recording rather than a measurement.
struct AudioLevelTests {
    /// `abs(Int16.min)` does not fit in an `Int16`, and Swift traps on the
    /// overflow — in the real-time thread, mid-meeting. Full-scale negative is
    /// an ordinary sample for a clipped 16-bit source.
    @Test("A full-scale negative 16-bit sample is measured, not trapped on")
    func int16MinimumIsMeasured() throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try #require(buffer.int16ChannelData?[0])
        samples[0] = 0
        samples[1] = 100
        samples[2] = Int16.min
        samples[3] = -5

        let peak = try #require(AudioLevel.peak(of: buffer))
        #expect(peak >= 0.99 && peak <= 1)
    }
}
