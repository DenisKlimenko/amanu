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
