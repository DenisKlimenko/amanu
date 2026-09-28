import Foundation
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
