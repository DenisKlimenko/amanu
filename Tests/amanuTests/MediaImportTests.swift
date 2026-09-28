import AVFoundation
import Foundation
import Testing

@testable import amanu

struct MediaImportTests {
    @Test("A real audio file is normalized to a readable M4A")
    func normalizesAudio() async throws {
        let root = try Self.temporaryDirectory("normalize")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("meeting.wav")
        let destination = root.appendingPathComponent("source.m4a")
        try Self.tone(source, seconds: 0.25)

        let normalizer = MediaNormalizer()
        let probe = try await normalizer.probe(source)
        try await normalizer.normalize(source, to: destination) { _ in }

        let normalized = try AVAudioFile(forReading: destination)
        #expect(probe.duration > 0.2 && probe.duration < 0.3)
        #expect(normalized.length > 0)
        #expect(normalized.processingFormat.channelCount == 1)
    }

    @Test("A stereo audio file is downmixed before it can select multichannel semantics")
    func normalizesStereoAudioToMono() async throws {
        let root = try Self.temporaryDirectory("normalize-stereo")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("stereo-meeting.wav")
        let destination = root.appendingPathComponent("source.m4a")
        try Self.tone(source, seconds: 0.25, channels: 2)
        #expect(try AVAudioFile(forReading: source).processingFormat.channelCount == 2)

        try await MediaNormalizer().normalize(source, to: destination) { _ in }

        let normalized = try AVAudioFile(forReading: destination)
        #expect(normalized.length > 0)
        #expect(normalized.processingFormat.channelCount == 1)
    }

    @Test("A movie contributes its first audio track without copying video")
    func normalizesVideo() async throws {
        let root = try Self.temporaryDirectory("video")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("meeting.mp4")
        let destination = root.appendingPathComponent("source.m4a")
        try Self.tinyMovie.write(to: source)

        let normalizer = MediaNormalizer()
        let probe = try await normalizer.probe(source)
        try await normalizer.normalize(source, to: destination) { _ in }

        #expect(probe.duration > 0.15)
        let normalized = try AVAudioFile(forReading: destination)
        #expect(normalized.length > 0)
        #expect(normalized.processingFormat.channelCount == 1)
    }

    @Test("A bad file does not block later files in a sequential import")
    func failureDoesNotBlockTheBatch() async throws {
        let root = try Self.temporaryDirectory("batch")
        defer { try? FileManager.default.removeItem(at: root) }
        let sources = ["first.wav", "bad.wav", "last.wav"].map {
            root.appendingPathComponent($0)
        }
        for (index, source) in sources.enumerated() {
            try Data("source-\(index)".utf8).write(to: source)
        }
        let normalizer = StubNormalizer(failing: ["bad.wav"])
        let coordinator = MediaImportCoordinator(
            root: root,
            normalizer: normalizer,
            now: { Date(timeIntervalSince1970: 1_800_000_000) })

        let result = await coordinator.importFiles(sources)

        #expect(result.imported.map(\.source.lastPathComponent) == ["first.wav", "last.wav"])
        #expect(result.failures.map(\.source.lastPathComponent) == ["bad.wav"])
        #expect(await normalizer.normalized == ["first.wav", "last.wav"])
    }

    @Test("Files added during an import keep their order in the pending queue")
    func pendingFilesAreQueued() {
        let first = URL(fileURLWithPath: "/tmp/first.wav")
        let second = URL(fileURLWithPath: "/tmp/second.mov")
        let third = URL(fileURLWithPath: "/tmp/third.mp3")
        var queue = ImportQueue()

        let started = queue.add([first, second])
        let startedAgain = queue.add([third])
        let batch = queue.nextBatch()
        let another = queue.nextBatch()
        let restarted = queue.runEnded()

        #expect(started)
        #expect(!startedAgain, "a second run was started beside the first")
        #expect(batch == [first, second, third])
        #expect(another == nil)
        #expect(!restarted)
    }

    /// The race: a cancelled run takes a moment to wind down, files dropped
    /// in that moment joined it, and it threw them away on its way out.
    @Test("Files dropped while a cancelled import winds down are imported afterwards")
    func filesDuringACancelAreKept() {
        let cancelled = URL(fileURLWithPath: "/tmp/cancelled.wav")
        let waiting = URL(fileURLWithPath: "/tmp/waiting.wav")
        let late = URL(fileURLWithPath: "/tmp/late.wav")
        var queue = ImportQueue()

        _ = queue.add([cancelled])
        let first = queue.nextBatch()
        _ = queue.add([waiting])
        queue.cancel()
        let lateStarted = queue.add([late])
        let afterCancel = queue.nextBatch()
        let restarted = queue.runEnded()
        let next = queue.nextBatch()
        let restartedAgain = queue.runEnded()

        #expect(first == [cancelled])
        #expect(!lateStarted, "the run winding down is still the only run")
        #expect(afterCancel == nil, "a cancelled run went on to the next batch")
        #expect(restarted, "the files dropped during the cancel were thrown away")
        #expect(next == [late], "what was waiting at the cancel is cancelled with it")
        #expect(!restartedAgain)
    }

    @Test("A queue closed for quitting starts nothing again")
    func closedQueueStartsNothing() {
        var queue = ImportQueue()
        _ = queue.add([URL(fileURLWithPath: "/tmp/a.wav")])
        queue.close()
        let started = queue.add([URL(fileURLWithPath: "/tmp/b.wav")])
        let batch = queue.nextBatch()
        let restarted = queue.runEnded()

        #expect(!started)
        #expect(batch == nil)
        #expect(!restarted)
    }

    @Test("An exact duplicate reuses the existing imported session")
    func exactDuplicateIsSkipped() async throws {
        let base = try Self.temporaryDirectory("duplicate")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("recordings", isDirectory: true)
        let first = base.appendingPathComponent("first.wav")
        let copy = base.appendingPathComponent("renamed-copy.wav")
        try Data("the same source bytes".utf8).write(to: first)
        try Data("the same source bytes".utf8).write(to: copy)
        let normalizer = StubNormalizer()
        let coordinator = MediaImportCoordinator(root: root, normalizer: normalizer)

        let result = await coordinator.importFiles([first, copy])

        #expect(result.imported.count == 1)
        #expect(result.duplicates.count == 1)
        #expect(result.duplicates.first?.existingSession.lastPathComponent
            == result.imported.first?.session.lastPathComponent)
        #expect(await normalizer.normalized == ["first.wav"])
    }

    @Test("Cancelling import removes its staging folder and leaves the source untouched")
    func cancellationCleansStaging() async throws {
        let base = try Self.temporaryDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("recordings", isDirectory: true)
        let source = base.appendingPathComponent("long.mov")
        let original = Data("irreplaceable original".utf8)
        try original.write(to: source)
        let normalizer = BlockingNormalizer()
        let coordinator = MediaImportCoordinator(root: root, normalizer: normalizer)

        let running = Task { await coordinator.importFiles([source]) }
        while !(await normalizer.started) { await Task.yield() }
        await coordinator.cancel()
        let result = await running.value

        #expect(result.cancelled)
        #expect(try Data(contentsOf: source) == original)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!leftovers.contains { $0.hasPrefix(".import-") })
        #expect(SessionInventory.scan(root: root).isEmpty)
    }

    @Test("Constructing the importer removes staging folders left by an interrupted launch")
    func startupCleansStaleStaging() throws {
        let root = try Self.temporaryDirectory("stale-staging")
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = root.appendingPathComponent(".import-abandoned", isDirectory: true)
        let session = root.appendingPathComponent("2026.09.15-1200 Kept", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: false)
        try Data("partial".utf8).write(to: stale.appendingPathComponent("source.m4a"))

        _ = MediaImportCoordinator(root: root)

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: session.path))
    }

    @Test("A single imported source reaches a per-track engine once as speaker")
    func singleSourcePerTrack() async throws {
        let dir = try Self.importedSession("per-track")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = SourceEngine(input: .perTrack)

        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)

        #expect(await engine.heardChannels == [1])
        let transcript = try #require(PostProcessor.readTranscript(dir))
        #expect(transcript.segments.map(\.speaker) == ["speaker"])
        let echo = try #require(SessionState.read(dir)?["echo_filter"] as? [String: Any])
        #expect(echo["ran"] as? Bool == false)
    }

    @Test("A single imported source reaches a mixed engine without a derived mix")
    func singleSourceMixed() async throws {
        let dir = try Self.importedSession("mixed")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = SourceEngine(input: .mixed)

        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)

        #expect(await engine.heardNames == ["source.m4a"])
        let transcript = try #require(PostProcessor.readTranscript(dir))
        #expect(transcript.segments.map(\.speaker) == ["A"])
    }

    @Test("A mono imported source keeps ordinary diarization in a multichannel engine")
    func singleSourceMultichannel() async throws {
        let dir = try Self.importedSession("multichannel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = SourceEngine(input: .multichannel)

        try await TranscriptionCoordinator(engine: engine, onStop: { nil }).transcribeNow(dir)

        #expect(await engine.heardChannels == [1])
        let transcript = try #require(PostProcessor.readTranscript(dir))
        #expect(transcript.segments.map(\.speaker) == ["A"])
    }

    @Test("AssemblyAI asks for ordinary diarization when imported audio is mono")
    func assemblyAIMonoRequest() {
        let body = AssemblyAIEngine.requestBody(
            audioURL: "https://example.test/source.m4a",
            expectedLanguages: ["en"],
            speechModel: nil,
            multichannel: false)

        #expect(body["multichannel"] == nil)
        #expect(body["speaker_labels"] as? Bool == true)
    }

    @Test("Recording-only mode keeps normalized imported audio without a compression failure")
    func importedRecordingOnlyStaysSettled() async throws {
        let dir = try Self.importedSession("recording-only")
        defer { try? FileManager.default.removeItem(at: dir) }

        try await TranscriptionCoordinator(onStop: { nil }).archiveRecordingOnly(dir)

        #expect(try AVAudioFile(
            forReading: dir.appendingPathComponent("source.m4a")).length > 0)
        let log = try String(
            contentsOf: dir.appendingPathComponent("transcribe.log"), encoding: .utf8)
        #expect(!log.contains("compression failed"))
    }

    private static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-import-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func tone(
        _ url: URL,
        seconds: Double,
        channels: AVAudioChannelCount = 1
    ) throws {
        let rate = 16_000.0
        try TestAudio.write(
            to: url, seconds: seconds, sampleRate: rate, channels: channels
        ) { channel, frame in
            let frequency = channel == 0 ? 440.0 : 660.0
            return 0.3 * Float(sin(2 * .pi * frequency * Double(frame) / rate))
        }
    }

    /// 200 ms of a generated black H.264 frame plus an AAC sine tone. Keeping
    /// the tiny fixture inline makes the video path hermetic: CI needs no
    /// ffmpeg, media library, camera, or microphone.
    private static let tinyMovie = Data(base64Encoded: """
    AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAAIZnJlZQAABjptZGF03gIATGF2YzYyLjI4LjEwMgACYKVUkNpyMvPH
    p541XnLlquskR5SSL8wkG3cD8F6r2LvuGy2paR/j0vN73q/J4G1MVWNs1prz6yUmmqpiuYqjJpSyUslppSaMlClGSjJRJrQ2htDA
    xs2DAyJEDGzZs2iRIpTZs3FFFFFFFFFFFFFFFEiKKKKKKJERERIRFFERRRIiiiKKKKLgAAACVAYF//9Q3EXpvebZSLeWLNgg2SPu
    73gyNjQgLSBjb3JlIDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAy
    NSAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6
    MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2
    IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3Fw
    X29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGlu
    dGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0y
    NTAga2V5aW50X21pbj0yNSBzY2VuZWN1dD0wIGludHJhX3JlZnJlc2g9MCByYz1jcmYgbWJ0cmVlPTAgY3JmPTQwLjAgcWNvbXA9
    MC42MCBxcG1pbj0wIHFwbWF4PTY5IHFwc3RlcD00IGlwX3JhdGlvPTEuNDAgYXE9MACAAAAADGWIhDomKAAIGMnXXgE4lNrJXZRT
    qynVkunP8+3Gmzxq//rX79ca41ev/7Xj+fPGuNXr/+L3/nzxrrWrDf62NH0UGAugTLCFn6nWbymNucBnOAwM7hMwMDO4SEgwM7hI
    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
    """.filter { !$0.isWhitespace })!

    private static func importedSession(_ name: String) throws -> URL {
        let dir = try temporaryDirectory("session-\(name)")
        try tone(dir.appendingPathComponent("source.m4a"), seconds: 0.25)
        try JSONSerialization.data(withJSONObject: [
            "files": ["source": "source.m4a"],
            "start_offset_ms": ["source": 0],
            "trigger": "import",
            "duration_seconds": 1,
            SessionState.Key.speakersStatus: "failed",
            SessionState.Key.summaryStatus: "failed",
        ]).write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }

    private actor StubNormalizer: MediaNormalizing {
        struct Failure: Error {}

        let failing: Set<String>
        private(set) var normalized: [String] = []

        init(failing: Set<String> = []) { self.failing = failing }

        func probe(_ source: URL) async throws -> MediaNormalizer.Probe {
            if failing.contains(source.lastPathComponent) { throw Failure() }
            let bytes = (try Data(contentsOf: source)).count
            return .init(duration: 12, sourceBytes: Int64(bytes))
        }

        func normalize(
            _ source: URL,
            to destination: URL,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws {
            normalized.append(source.lastPathComponent)
            progress(0.5)
            try Data("normalized \(source.lastPathComponent)".utf8).write(to: destination)
            progress(1)
        }
    }

    private actor BlockingNormalizer: MediaNormalizing {
        private(set) var started = false

        func probe(_ source: URL) async throws -> MediaNormalizer.Probe {
            .init(duration: 60, sourceBytes: Int64(try Data(contentsOf: source).count))
        }

        func normalize(
            _ source: URL,
            to destination: URL,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws {
            started = true
            while true { try await Task.sleep(for: .seconds(1)) }
        }
    }

    private actor SourceEngine: TranscriptionEngine {
        nonisolated let name = "import-test"
        nonisolated let model = "test"
        nonisolated let input: TranscriptionInput
        private(set) var heardChannels: [AVAudioChannelCount] = []
        private(set) var heardNames: [String] = []

        init(input: TranscriptionInput) { self.input = input }

        func prepare() async throws {}
        func release() async {}

        func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
            heardNames.append(audio.lastPathComponent)
            heardChannels.append(try AVAudioFile(forReading: audio).processingFormat.channelCount)
            return [.init(start: 0, end: 0.2, text: "Imported words", speaker: "A")]
        }
    }
}
