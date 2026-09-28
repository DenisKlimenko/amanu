import AppKit
import Foundation
import Testing

@testable import amanu

/// The recordings window keeping up with a folder that other things write
/// into: the transcription queue, a moved recordings folder, a session that
/// is still being worked on.
@Suite(.serialized)
@MainActor
struct RecordingsWindowTests {
    private static func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-recordings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private static func session(_ name: String, in root: URL) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "started": "2026-09-28T09:00:00Z", "duration_seconds": 600, "title": name,
        ]).write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }

    private static func transcribe(_ dir: URL) throws {
        try JSONEncoder().encode(Transcript(
            engine: "parakeet", model: "v3", created_at: "2026-09-28T09:11:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Hello.")]
        )).write(to: dir.appendingPathComponent("transcript.json"))
    }

    /// What the one row's transcript column says: `listLines` is the column
    /// titles, then each row's cells in column order.
    private static func transcriptCell(_ window: RecordingsWindow) -> String? {
        let lines = window.listLines
        return lines.count >= 8 ? lines[7] : nil
    }

    /// It read the folder when it was opened and never again, so a meeting
    /// transcribed while it was open went on showing as waiting, and Finish
    /// processing acted on what the window last saw.
    @Test("A transcript finished while the window is open shows up in it")
    func finishedWorkIsShown() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session("2026-09-28-090000-standup", in: root)

        let window = RecordingsWindow(root: root)
        window.show()
        defer { withExtendedLifetime(window) {} }
        let before = Self.transcriptCell(window)

        try Self.transcribe(dir)
        window.sessionsChanged()
        await window.settled()

        #expect(Self.transcriptCell(window) != before, "the window still shows the transcript as owed")
        #expect(Self.transcriptCell(window)?.hasPrefix(
            SessionInventory.Step.done.described) == true)
    }

    @Test("A closed window does not read the folder until it is opened")
    func closedWindowWaits() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }

        let window = RecordingsWindow(root: root)
        defer { withExtendedLifetime(window) {} }
        try Self.session("2026-09-28-100000-later", in: root)
        window.sessionsChanged()
        await window.settled()
        #expect(!window.listLines.contains("2026-09-28-100000-later"))
    }

    @Test("Moved to another recordings folder, the window lists that folder")
    func anotherFolderIsListed() async throws {
        let first = try Self.folder()
        let second = try Self.folder()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try Self.session("2026-09-28-090000-old-folder", in: first)
        try Self.session("2026-09-28-090000-new-folder", in: second)

        let window = RecordingsWindow(root: first)
        defer { withExtendedLifetime(window) {} }
        #expect(window.listLines.contains { $0.hasPrefix("2026-09-28-090000-old-folder") })

        window.setRoot(second)
        await window.settled()
        #expect(window.listLines.contains { $0.hasPrefix("2026-09-28-090000-new-folder") })
        #expect(!window.listLines.contains { $0.hasPrefix("2026-09-28-090000-old-folder") })
    }

    /// Delete moved a folder to the Trash while the transcription queue was
    /// writing into it.
    @Test("A recording something is working on cannot be deleted, and says why")
    func heldSessionIsNotDeleted() throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.session("2026-09-28-090000-busy", in: root)

        #expect(RecordingsWindow.deleteRefusal(for: dir) == nil)

        try SessionClaim.acquire(dir, stage: .transcribe)
        let why = RecordingsWindow.deleteRefusal(for: dir)
        SessionClaim.release(dir)

        #expect(why?.contains("working on this recording") == true)
        #expect(RecordingsWindow.deleteRefusal(for: dir) == nil)
    }
}
