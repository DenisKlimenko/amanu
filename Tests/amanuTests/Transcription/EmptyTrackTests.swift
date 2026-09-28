import AVFoundation
import Foundation
import Testing

@testable import amanu

/// A side that recorded nothing is a silent side, not a broken recording.
@Suite(.freshHome(config: #"{"offline_echo_cancellation": false}"#))
struct EmptyTrackTests {
    /// Refuses a file with no frames the way Whisper and GigaAM do: as
    /// unreadable audio, which is permanent.
    private static func strictLocalEngine() -> FakeEngine {
        FakeEngine("whisper", answer: { audio, call in
            let file = try AVAudioFile(forReading: audio)
            guard file.length > 0 else { throw WhisperEngine.EngineError.unreadableAudio(audio, nil) }
            return try FakeEngine.speech(audio, call)
        })
    }

    private static func emptyTrack(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        _ = try AVAudioFile(
            forWriting: url, settings: AudioFormats.pcmSettings(sampleRate: 48_000, channels: 1))
    }

    @Test("A track created but never written is transcribed as silence")
    func headerOnlyTrackIsSilent() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        try Self.emptyTrack(dir.appendingPathComponent("system.caf"))
        let engine = Self.strictLocalEngine()

        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)

        let transcript = try #require(PostProcessor.readTranscript(dir))
        #expect(transcript.segments.map(\.speaker) == ["me"])
        #expect(engine.counts.heard.map(\.lastPathComponent) == ["mic.caf"])
        #expect(!TranscriptionFailurePolicy.hasGivenUp(on: dir))
    }

    @Test("A zero-byte track is silence too")
    func zeroByteTrackIsSilent() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        try Data().write(to: dir.appendingPathComponent("mic.caf"))

        try await TranscriptionCoordinator(engine: Self.strictLocalEngine(), onStop: { nil })
            .transcribeNow(dir)

        #expect(PostProcessor.readTranscript(dir)?.segments.map(\.speaker) == ["them"])
    }

    @Test("Unreadable audio is permanent in every local engine")
    func unreadableIsPermanentEverywhere() {
        let url = URL(fileURLWithPath: "/tmp/broken.caf")
        #expect(ParakeetEngine.EngineError.unreadableAudio(url, nil).isPermanent)
        #expect(WhisperEngine.EngineError.unreadableAudio(url, nil).isPermanent)
        #expect(GigaAMEngine.EngineError.unreadableAudio(url, nil).isPermanent)
        #expect(!ParakeetEngine.EngineError.notPrepared.isPermanent)
    }
}
