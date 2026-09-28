import Foundation
import Testing

@testable import amanu

/// When `on_stop` runs, and with what.
@Suite(.freshHome(config: #"{"offline_echo_cancellation": false}"#))
struct StopHookTests {
    /// A hook that appends the folder it was given to a file of its own.
    private struct Hook {
        let command: String
        let log: URL

        init(in dir: URL) throws {
            let script = dir.appendingPathComponent("hook script.sh")
            log = dir.appendingPathComponent("fired.txt")
            try Data("#!/bin/sh\nprintf '%s\\n' \"$1\" >> '\(log.path)'\n".utf8).write(to: script)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: script.path)
            command = "'\(script.path)'"
        }

        /// The folders it has been run for, once a run has had time to land.
        func fired(expecting count: Int) async throws -> [String] {
            for _ in 0..<200 {
                if lines.count >= count { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            return lines
        }

        var lines: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
    }

    /// The sweep reaches a folder through the recordings root as the file
    /// system lists it, which under /var is /private/var: compare names.
    private static func name(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private static func transcribed(_ recordings: TestRecordings, _ name: String) throws -> URL {
        let dir = try recordings.session(name)
        try Transcript(
            engine: "parakeet", model: "v3", created_at: "2026-09-28T09:00:00Z",
            segments: [.init(speaker: "me", start_ms: 0, end_ms: 1000, text: "Привет.")]
        ).write(to: dir)
        return dir
    }

    @Test("It runs once, after the transcript, with a folder whose name has spaces and quotes")
    func firesOnceWithAnAwkwardPath() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let hook = try Hook(in: recordings.root)
        let dir = try recordings.session(#"2026-09-28 it's a "meeting""#)

        try await TranscriptionCoordinator(
            engine: FakeEngine("parakeet"), onStop: { hook.command }
        ).transcribeNow(dir)
        try Home.current.writeConfig([
            "offline_echo_cancellation": false, "on_stop": hook.command,
        ])
        await PostProcessor.sweep(root: recordings.root)

        #expect(try await hook.fired(expecting: 1) == [dir.path])
        try await Task.sleep(for: .milliseconds(200))
        #expect(hook.lines.count == 1)
        #expect(SessionState.value(dir, StopHook.key) as? String == StopHook.fired)
    }

    /// The claim is another amanu naming and summarizing the session right
    /// now. The hook used to fire anyway, into a folder with no names or
    /// summary in it yet.
    @Test("It waits while someone else is finishing the session, and the sweep fires it after")
    func waitsForWhoeverHasTheSession() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let hook = try Hook(in: recordings.root)
        try Home.current.writeConfig(["offline_echo_cancellation": false, "on_stop": hook.command])
        let dir = try Self.transcribed(recordings, "2026-09-28-a")
        StopHook.owe(dir)
        try SessionClaim.acquire(dir, stage: .finish)

        #expect(!StopHook.fireIfOwed(dir))
        #expect(SessionState.value(dir, StopHook.key) as? String == StopHook.owed)

        SessionClaim.release(dir)
        await PostProcessor.sweep(root: recordings.root)

        #expect(try await hook.fired(expecting: 1).map(Self.name) == [dir.lastPathComponent])
    }

    /// A crash between the transcript and the hook leaves the debt on disk;
    /// the sweep at the next launch is what pays it.
    @Test("A session left owing the hook has it fired by the sweep, once")
    func sweepPaysWhatIsOwed() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let hook = try Hook(in: recordings.root)
        try Home.current.writeConfig(["offline_echo_cancellation": false, "on_stop": hook.command])
        let owing = try Self.transcribed(recordings, "2026-09-28-a")
        StopHook.owe(owing)
        let old = try Self.transcribed(recordings, "2026-09-28-b")

        await PostProcessor.sweep(root: recordings.root)
        await PostProcessor.sweep(root: recordings.root)

        #expect(try await hook.fired(expecting: 1).map(Self.name) == [owing.lastPathComponent])
        try await Task.sleep(for: .milliseconds(200))
        #expect(hook.lines.count == 1)
        #expect(SessionState.value(old, StopHook.key) == nil)
    }

    @Test("With transcription off it runs once the recording is archived")
    func recordingOnlyFires() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let hook = try Hook(in: recordings.root)
        let dir = try recordings.session("2026-09-28-a")

        try await TranscriptionCoordinator(onStop: { hook.command }).archiveRecordingOnly(dir)

        #expect(try await hook.fired(expecting: 1) == [dir.path])
    }

    @Test("A retired session never runs it")
    func retiredSessionDoesNotFire() async throws {
        let recordings = try TestRecordings()
        defer { recordings.remove() }
        let hook = try Hook(in: recordings.root)
        let dir = try recordings.session("2026-09-28-a")
        struct Refused: TranscriptionFailure { var isPermanent: Bool { true } }

        await #expect(throws: Refused.self) {
            try await TranscriptionCoordinator(
                engine: FakeEngine("parakeet", answer: { _, _ in throw Refused() }),
                onStop: { hook.command }
            ).transcribeNow(dir)
        }

        #expect(SessionState.value(dir, StopHook.key) == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(hook.lines.isEmpty)
    }
}
