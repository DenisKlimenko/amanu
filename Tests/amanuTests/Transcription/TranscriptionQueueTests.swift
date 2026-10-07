import Foundation
import os
import Testing

@testable import amanu

/// Which folders the transcription queue takes from the recordings root.
struct TranscriptionQueueTests {
    @Test("A hidden staging folder is not a pending session, even with a meta.json in it")
    func stagingFoldersAreNotPending() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-queue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("2026-09-28-meeting", isDirectory: true)
        for dir in [staging, session] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["files": ["source": "source.m4a"]])
                .write(to: dir.appendingPathComponent("meta.json"))
        }

        #expect(TranscriptionCoordinator.pendingSessions(in: root).map(\.lastPathComponent)
            == [session.lastPathComponent])
    }
}

/// One session, transcribed once, however many ways it reaches the queue.
@Suite(.freshHome(config: #"{"offline_echo_cancellation": false}"#))
struct TranscriptionOnceTests {
    /// The importer hands over a path with its symlinks resolved and a rescan
    /// of the root does not; with a recordings folder reached through a
    /// link, one session was two queue entries and was transcribed — and
    /// paid for — twice.
    @Test("A session queued under two spellings of its path is transcribed once")
    func twoSpellingsOneTranscription() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let resolved = try recordings.session("2026-09-28 10-00")
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: recordings.root)
        defer { try? FileManager.default.removeItem(at: link) }
        let dir = link.appendingPathComponent("2026-09-28 10-00", isDirectory: true)
        let engine = FakeEngine("parakeet")
        let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil })
        let done = Gate()
        await coordinator.setStatusHandler { status in
            if case .transcribing = status { return }
            done.open()
        }

        await coordinator.enqueue(resolved)
        await coordinator.enqueue(dir)
        await done.pass()
        await coordinator.resumePending(root: link)
        try await Task.sleep(for: .milliseconds(100))

        #expect(engine.counts.heard.count == 2, "one pass per track, once: \(engine.counts.heard)")
        #expect(SessionState.value(dir, SessionState.Key.transcriptionAttempts) == nil)
    }

    @Test("A session transcribed while it waited is not transcribed again")
    func transcriptWrittenMeanwhileIsKept() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-09-28 10-00")
        let first = Transcript(
            engine: "assemblyai", model: "earlier", created_at: "2026-09-28T09:00:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Привет.")])
        try first.write(to: dir)
        let engine = FakeEngine("parakeet")

        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)

        #expect(engine.counts.heard.isEmpty)
        #expect(PostProcessor.readTranscript(dir)?.model == "earlier")
        #expect(SessionState.value(dir, SessionState.Key.transcriptionAttempts) == nil)
        #expect(!SessionClaim.isHeld(dir))
    }
}

/// What an offer does to a recording that has failed — the half-hourly one,
/// the network coming back, a Re-transcribe pressed on another recording —
/// when it arrives while the queue is still busy, or straight after.
@Suite(.freshHome(config: #"{"offline_echo_cancellation": false}"#))
struct TranscriptionRetryTests {
    private struct Flaky: Error, CustomStringConvertible {
        var description: String { "HTTP 503" }
    }

    /// Fails one session, and keeps another in hand until the test lets it
    /// go: a drain that is still running when the next offer comes.
    private final class HeldEngine: TranscriptionEngine, @unchecked Sendable {
        let name = "parakeet"
        let model = "fake"
        let input: TranscriptionInput = .perTrack
        let entered = Gate()
        let release = Gate()
        private let failing: String
        private let held: String
        private let failure: @Sendable () -> Error
        private let calls = OSAllocatedUnfairLock(initialState: [String: Int]())

        init(failing: String, held: String, failure: @escaping @Sendable () -> Error) {
            self.failing = failing
            self.held = held
            self.failure = failure
        }

        func calls(for session: String) -> Int { calls.withLock { $0[session] ?? 0 } }
        func prepare() async throws {}
        func release() async {}

        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            let session = audio.deletingLastPathComponent().lastPathComponent
            calls.withLock { $0[session, default: 0] += 1 }
            if session == failing { throw failure() }
            if session == held {
                entered.open()
                await release.pass()
            }
            return [TranscriptSegment(start: 0, end: 1, text: "\(session) \(audio.lastPathComponent)")]
        }
    }

    private static func attempts(_ dir: URL) -> Int? {
        SessionState.value(dir, SessionState.Key.transcriptionAttempts) as? Int
    }

    private static let waiting: @Sendable () -> Error = {
        GeminiTranscriptionEngine.EngineError.serviceFault(
            #"{"error":{"code":400,"message":"Thinking is not enabled for this model"}}"#)
    }

    /// An offer that landed mid-drain put a session the drain had just failed
    /// back in the same drain, seconds later: a burst of offers could spend
    /// all three attempts on one short outage.
    @Test("A recording that just failed is not tried again by an offer that comes straight after")
    func justFailedIsLeftAlone() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let failing = try recordings.session("2026-10-07-a", state: ["duration_seconds": 1800])
        try recordings.session("2026-10-07-b", state: ["duration_seconds": 1800])
        let engine = HeldEngine(failing: "2026-10-07-a", held: "2026-10-07-b", failure: { Flaky() })
        let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil })

        await coordinator.resumePending(root: recordings.root)
        await engine.entered.pass()
        #expect(Self.attempts(failing) == 1)
        await coordinator.resumePending(root: recordings.root)
        engine.release.open()
        await coordinator.waitUntilIdle()

        #expect(Self.attempts(failing) == 1)
    }

    /// Offered again while it waited, a held-back session was held back twice,
    /// and every drain after tried it — and uploaded it — twice.
    @Test("A recording waiting for the machine is tried once at the next offer, however often it was offered meanwhile")
    func heldBackOnce() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        try recordings.session("2026-10-07-a", state: ["duration_seconds": 1800])
        try recordings.session("2026-10-07-b", state: ["duration_seconds": 1800])
        let engine = HeldEngine(failing: "2026-10-07-a", held: "2026-10-07-b", failure: Self.waiting)
        let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil })

        await coordinator.resumePending(root: recordings.root)
        await engine.entered.pass()
        await coordinator.resumePending(root: recordings.root)
        engine.release.open()
        await coordinator.waitUntilIdle()
        let before = engine.calls(for: "2026-10-07-a")
        await coordinator.resumePending(root: recordings.root)
        await coordinator.waitUntilIdle()

        #expect(before == 1)
        #expect(engine.calls(for: "2026-10-07-a") - before == 1)
    }

    /// The pause is for offers nobody asked for. Re-transcribe or Finish
    /// processing pressed on the recording itself is somebody watching it.
    @Test("A recording somebody asks for is tried at once, however recently it failed")
    func askedForIsTriedAtOnce() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let dir = try recordings.session("2026-10-07-a", state: ["duration_seconds": 1800])
        let engine = FakeEngine("parakeet", answer: { _, _ in throw Flaky() })
        let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil })
        await coordinator.drainPending(in: recordings.root)
        #expect(Self.attempts(dir) == 1)

        await coordinator.resumePending(root: recordings.root, asked: dir)
        await coordinator.waitUntilIdle()

        #expect(Self.attempts(dir) == 2)
    }

    /// Deleting is what the ⚠︎ invites for a recording that was never a
    /// meeting. Held back, it was tried from a folder no longer there, and
    /// reported as failed with a banner opening nothing.
    @Test("A recording deleted while it waited is not reported as failed")
    func deletedWhileWaiting() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let waiting = try recordings.session("2026-10-07-a", state: ["duration_seconds": 1800])
        let engine = FakeEngine("parakeet", answer: { _, _ in throw Self.waiting() })
        let coordinator = TranscriptionCoordinator(engine: engine, onStop: { nil })
        await coordinator.drainPending(in: recordings.root)
        try FileManager.default.removeItem(at: waiting)
        let failed = OSAllocatedUnfairLock<String?>(initialState: nil)
        await coordinator.setStatusHandler { status in
            if case .failed(let name) = status { failed.withLock { $0 = name } }
        }

        await coordinator.resumePending(root: recordings.root)
        await coordinator.waitUntilIdle()

        #expect(failed.withLock { $0 } == nil)
        #expect(!FileManager.default.fileExists(atPath: waiting.path))
    }
}
