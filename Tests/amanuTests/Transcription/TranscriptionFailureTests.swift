import Foundation
import Testing

@testable import amanu

/// What a failure costs a session: an attempt, its place in the queue, or —
/// when the fault is the machine's — nothing.
@Suite(.freshHome(config: #"{"offline_echo_cancellation": false}"#))
struct TranscriptionFailureTests {
    private struct Flaky: Error, CustomStringConvertible {
        var description: String { "the recognizer fell over" }
    }

    private struct Refused: TranscriptionFailure {
        var isPermanent: Bool { true }
    }

    private static func attempts(_ dir: URL) -> Int? {
        SessionState.value(dir, SessionState.Key.transcriptionAttempts) as? Int
    }

    @Test("A failing session is counted each time and retired on the third")
    func retiredAfterThreeAttempts() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        let engine = FakeEngine("parakeet", answer: { _, _ in throw Flaky() })

        for expected in 1...2 {
            await #expect(throws: Flaky.self) {
                try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
            }
            #expect(Self.attempts(dir) == expected)
            #expect(!TranscriptionFailurePolicy.hasGivenUp(on: dir))
            #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root)
                .map(\.lastPathComponent) == [dir.lastPathComponent])
        }
        await #expect(throws: Flaky.self) {
            try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
        }
        #expect(Self.attempts(dir) == 3)
        #expect(TranscriptionFailurePolicy.hasGivenUp(on: dir))
        #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root).isEmpty)
    }

    @Test("A permanent failure retires the session on the first attempt")
    func permanentRetiresAtOnce() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        let engine = FakeEngine("parakeet", answer: { _, _ in throw Refused() })

        await #expect(throws: Refused.self) {
            try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
        }
        #expect(Self.attempts(dir) == 1)
        #expect(TranscriptionFailurePolicy.hasGivenUp(on: dir))
    }

    /// The retired session's tracks are compressed after the failed
    /// transcription has let go of its claim — and used to be compressed
    /// without one, under whoever had picked the folder up in the meantime.
    @Test("A retired session is compressed only under its own claim")
    func retirementCompressesUnderTheClaim() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let held = try recordings.session("2026-09-28-a")
        let free = try recordings.session("2026-09-28-b")
        try JSONSerialization.data(withJSONObject: [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "started": "2026-09-28T09:00:00Z", "stage": "transcribe",
        ]).write(to: SessionClaim.url(held))

        #expect(TranscriptionFailurePolicy.record(Refused(), for: held, engine: nil) == .retired)
        #expect(TranscriptionFailurePolicy.record(Refused(), for: free, engine: nil) == .retired)

        #expect(FileManager.default.fileExists(atPath: held.appendingPathComponent("mic.caf").path),
                "the tracks were compressed under somebody else's claim")
        #expect(!FileManager.default.fileExists(atPath: held.appendingPathComponent("audio.m4a").path))
        #expect(FileManager.default.fileExists(atPath: free.appendingPathComponent("audio.m4a").path))
        #expect(!SessionClaim.isHeld(free))
    }

    /// A model that would not download used to fail every meeting in the
    /// queue once each, restart the download from nothing for each of them,
    /// and retire all of them on the third launch.
    @Test("A model that will not prepare is tried once per drain and counted against nobody")
    func preparationFailureIsNotCounted() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "transcription": ["engine": "whisper"],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let sessions = try ["2026-09-28-a", "2026-09-28-b", "2026-09-28-c"].map {
            try recordings.session($0)
        }
        let whisper = FakeEngine("whisper", prepareError: { URLError(.networkConnectionLost) })

        let coordinator = TranscriptionCoordinator(
            engines: EngineResolver(environment: .fake(local: { _ in whisper })), onStop: { nil })
        await coordinator.drainPending(in: recordings.root)

        #expect(whisper.counts.prepared == 1)
        for dir in sessions {
            #expect(Self.attempts(dir) == nil)
            #expect(!TranscriptionFailurePolicy.hasGivenUp(on: dir))
        }
        #expect(TranscriptionCoordinator.pendingSessions(in: recordings.root)
            .map(\.lastPathComponent) == sessions.map(\.lastPathComponent))
    }

    @Test("Sessions held back by the machine are offered again with the next recording")
    func heldBackSessionsReturn() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "transcription": ["engine": "whisper"],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let early = try recordings.session("2026-09-28-a")
        let downloads = Flag()
        let whisper = FakeEngine("whisper", prepareError: {
            if downloads.isRaised { return nil }
            downloads.raise()
            return URLError(.networkConnectionLost)
        })
        let coordinator = TranscriptionCoordinator(
            engines: EngineResolver(environment: .fake(local: { _ in whisper })), onStop: { nil })
        await coordinator.drainPending(in: recordings.root)
        #expect(PostProcessor.readTranscript(early) == nil)

        let later = try recordings.session("2026-09-28-b")
        await coordinator.drainPending(in: recordings.root)

        #expect(PostProcessor.readTranscript(early)?.engine == "whisper")
        #expect(PostProcessor.readTranscript(later)?.engine == "whisper")
    }

    @Test("No network under an explicit cloud engine is not the recording's fault")
    func offlineIsNotCounted() async throws {
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "transcription": ["engine": "assemblyai"],
        ])
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        let cloud = FakeEngine("assemblyai", input: .multichannel, answer: { _, _ in
            throw URLError(.notConnectedToInternet)
        })

        for _ in 1...4 {
            await #expect(throws: URLError.self) {
                try await TranscriptionCoordinator(
                    engines: EngineResolver(environment: .fake(cloud: { _ in cloud })),
                    onStop: { nil }
                ).transcribeNow(dir)
            }
        }
        #expect(Self.attempts(dir) == nil)
        #expect(!TranscriptionFailurePolicy.hasGivenUp(on: dir))
    }

    @Test("A refused key keeps the recording's attempts")
    func refusedKeyIsNotCounted() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a")
        let engine = FakeEngine("assemblyai", input: .multichannel, answer: { _, _ in
            throw CloudHTTP.Failure.unauthorized(
                service: "assemblyai", what: "upload", status: 401, body: "")
        })

        await #expect(throws: CloudHTTP.Failure.self) {
            try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)
        }
        #expect(Self.attempts(dir) == nil)
    }

    /// What the menu bar warns about: the recordings a failure has left with
    /// no transcript, waiting for a retry or given up on. One that has not had
    /// its turn yet is the queue's business, and one shorter than a minute is
    /// the auto-recorder catching a notification sound. A length of nothing is
    /// neither: it is a recovered recording whose start was lost.
    @Test("Only recordings a failure left untranscribed, a minute long or more, are counted")
    func untranscribedAreTheFailedOnes() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let long = ["duration_seconds": 1800]
        let waiting = try recordings.session("2026-10-07-a", state: long)
        let counted = try recordings.session("2026-10-07-b", state: long)
        let retired = try recordings.session("2026-10-07-c", state: long)
        let short = try recordings.session("2026-10-07-d", state: ["duration_seconds": 4])
        try recordings.session("2026-10-07-e", state: long)
        let done = try recordings.session("2026-10-07-f", state: long)
        let recovered = try recordings.session("2026-10-07-g", state: ["duration_seconds": 0])

        TranscriptionFailurePolicy.record(URLError(.notConnectedToInternet), for: waiting, engine: nil)
        TranscriptionFailurePolicy.record(Flaky(), for: counted, engine: nil)
        TranscriptionFailurePolicy.record(Refused(), for: retired, engine: nil)
        TranscriptionFailurePolicy.record(Refused(), for: short, engine: nil)
        TranscriptionFailurePolicy.record(Flaky(), for: done, engine: nil)
        TranscriptionFailurePolicy.record(Refused(), for: recovered, engine: nil)
        try Transcript(
            engine: "gemini", model: "gemini-3.5-transcribe", created_at: "2026-10-07T10:00:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Привет.")]
        ).write(to: done)

        #expect(TranscriptionFailurePolicy.untranscribed(in: recordings.root).map(\.lastPathComponent)
            == ["2026-10-07-a", "2026-10-07-b", "2026-10-07-c", "2026-10-07-g"])
    }

    /// Re-transcribe starts the recording over, its wait included: until the
    /// new attempt fails, nothing has.
    @Test("A recording put back for re-transcription is not counted as untranscribed")
    func retranscriptionEndsTheWait() throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-10-07-a", state: ["duration_seconds": 1800])
        TranscriptionFailurePolicy.record(URLError(.notConnectedToInternet), for: dir, engine: nil)

        #expect(PostProcessor.markForRetranscription(dir))

        #expect(TranscriptionFailurePolicy.untranscribed(in: recordings.root).isEmpty)
    }

    @Test("A mixed engine is handed one mix of both tracks")
    func mixedPathThroughTheCoordinator() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28-a", seconds: 2)
        let engine = FakeEngine("openai", input: .mixed, answer: { _, _ in [
            TranscriptSegment(start: 0, end: 0.9, text: "first voice speaking", speaker: "A"),
            TranscriptSegment(start: 1, end: 1.9, text: "second voice answering", speaker: "B"),
        ] })

        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)

        #expect(engine.counts.heard.map(\.lastPathComponent) == ["mixed.m4a"])
        let transcript = try #require(PostProcessor.readTranscript(dir))
        #expect(transcript.engine == "openai")
        #expect(transcript.segments.map(\.text) == ["first voice speaking", "second voice answering"])
        #expect(SessionState.value(dir, "transcription_input") as? String == "mixed")
    }
}
