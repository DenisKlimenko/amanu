import Foundation
import Testing

@testable import amanu

/// The session's diary. It is written from inside a recording, so the one
/// thing it must never do is end the process that is recording.
struct SessionLogTests {
    private static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Lines are appended in order, and the first one creates the file")
    func appendsInOrder() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }

        appendSessionLog("first", to: dir)
        appendSessionLog("second", to: dir)

        let text = try String(
            contentsOf: dir.appendingPathComponent("transcribe.log"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix(" first"))
        #expect(lines[1].hasSuffix(" second"))
    }

    /// A full disk cannot be arranged in a test, but a handle that refuses the
    /// write fails the same call: the legacy `write(_: Data)` raised an
    /// Objective-C exception here, which no Swift code can catch.
    @Test("A write the file refuses is an error to catch, not an exception that ends the process")
    func aRefusedWriteThrows() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("transcribe.log")
        try Data().write(to: url)
        let readOnly = try FileHandle(forReadingFrom: url)
        defer { try? readOnly.close() }

        #expect(throws: (any Error).self) {
            try SessionLog.append(Data("line\n".utf8), to: readOnly)
        }
    }

    @Test("A log that cannot be opened is passed over quietly")
    func anUnopenableLogIsPassedOver() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blocker = dir.appendingPathComponent("transcribe.log", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)

        appendSessionLog("nowhere to go", to: dir)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: blocker.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}
