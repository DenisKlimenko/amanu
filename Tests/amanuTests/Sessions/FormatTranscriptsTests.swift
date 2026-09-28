import Foundation
import Testing

@testable import amanu

/// `amanu format-transcripts` walks a recordings folder that may hold years of
/// sessions; one of them being damaged is a reason to say so, not to stop.
struct FormatTranscriptsTests {
    @Test("One corrupt transcript is reported and the sessions after it are still reformatted")
    func aCorruptTranscriptDoesNotStopTheRun() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-format-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Named so the broken one sorts first, which is the order the run
        // walks in and so the case that used to leave everything else alone.
        let broken = root.appendingPathComponent("2026.01.01 a", isDirectory: true)
        let good = root.appendingPathComponent("2026.01.02 b", isDirectory: true)
        for dir in [broken, good] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("{ not json".utf8).write(to: broken.appendingPathComponent("transcript.json"))
        try Transcript(
            engine: "assemblyai", model: "test", created_at: "2026-09-23T00:00:00Z",
            segments: [.init(speaker: "them", start_ms: 0, end_ms: 500, text: "Добрый день.")]
        ).write(to: good)
        try Data("stale".utf8).write(to: good.appendingPathComponent("transcript.md"))

        var failed: [URL] = []
        let changed = try FormatTranscripts.reformat(in: root, onFailure: { dir, _ in
            failed.append(dir)
        })

        #expect(changed.map(\.lastPathComponent) == [good.lastPathComponent])
        #expect(failed.map(\.lastPathComponent) == [broken.lastPathComponent])
        let markdown = try String(
            contentsOf: good.appendingPathComponent("transcript.md"), encoding: .utf8)
        #expect(markdown.contains("Добрый день."))
    }
}
