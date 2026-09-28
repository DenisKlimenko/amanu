import Foundation
import Testing

@testable import amanu

/// Offline echo cancellation failing is a worse transcript, not no transcript.
@Suite(.freshHome)
struct EchoFallbackTests {
    /// Fails partway through the meeting, the way a NaN from the native
    /// library does: after the canceller has already produced some audio.
    private final class BreaksPartway: EchoCancellationBackend {
        let sampleRate = 16_000
        let hopSize = 256
        private var hops = 0

        func process(microphone: [Float], reference: [Float]) throws -> [Float] {
            hops += 1
            if hops > 20 { throw EchoCancellationError.invalidOutput }
            return microphone
        }
    }

    private static func transcribe(
        with factory: @escaping TranscriptionCoordinator.EchoCancellerFactory
    ) async throws -> (URL, FakeEngine) {
        let recordings = try TestRecordings()
        let dir = try recordings.session("2026-09-28-a")
        let engine = FakeEngine("parakeet")
        try await TranscriptionCoordinator(
            engine: engine, onStop: { nil }, echoCanceller: factory
        ).transcribeNow(dir)
        return (dir, engine)
    }

    @Test("A LocalVQE that will not load leaves the raw tracks to be transcribed")
    func missingLibraryFallsBack() async throws {
        let (dir, engine) = try await Self.transcribe {
            throw EchoCancellationError.missingAsset(URL(fileURLWithPath: "/nowhere/liblocalvqe.dylib"))
        }
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        #expect(PostProcessor.readTranscript(dir)?.engine == "parakeet")
        #expect(engine.counts.heard.map(\.lastPathComponent) == ["mic.caf", "system.caf"])
        #expect(engine.counts.heard.allSatisfy { $0.deletingLastPathComponent().lastPathComponent
            == dir.lastPathComponent })
        let echo = try #require(SessionState.value(dir, "audio_echo_cancellation") as? [String: Any])
        #expect((echo["skipped"] as? String)?.contains("liblocalvqe") == true)
        let filter = try #require(SessionState.value(dir, "echo_filter") as? [String: Any])
        #expect(filter["mode"] as? String == "raw_audio")
        let log = try String(contentsOf: dir.appendingPathComponent("transcribe.log"), encoding: .utf8)
        #expect(log.contains("echo cancellation skipped"))
        #expect(SessionState.value(dir, SessionState.Key.transcriptionAttempts) == nil)
    }

    @Test("Echo cancellation failing partway still ends in a transcript of the raw tracks")
    func failurePartwayFallsBack() async throws {
        let (dir, engine) = try await Self.transcribe { try EchoCanceller(backend: BreaksPartway()) }
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }

        #expect(PostProcessor.readTranscript(dir) != nil)
        #expect(engine.counts.heard.count == 2)
        let echo = try #require(SessionState.value(dir, "audio_echo_cancellation") as? [String: Any])
        #expect((echo["skipped"] as? String)?.contains("non-finite") == true)
    }
}
