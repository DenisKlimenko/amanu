import Foundation
import os

@testable import amanu

/// An engine that does whatever a test tells it to, and remembers what it was
/// asked. `answer` gets the file it was handed and how many times this engine
/// has been asked so far, and either returns segments or throws.
final class FakeEngine: TranscriptionEngine, @unchecked Sendable {
    typealias Answer = @Sendable (_ audio: URL, _ call: Int) throws -> [TranscriptSegment]

    let name: String
    let model: String
    let input: TranscriptionInput
    private let answer: Answer
    private let prepareError: (@Sendable () -> Error?)?
    private let state = OSAllocatedUnfairLock(initialState: Counts())

    struct Counts {
        var prepared = 0
        var released = 0
        var heard: [URL] = []
    }

    init(
        _ name: String,
        model: String = "fake",
        input: TranscriptionInput = .perTrack,
        prepareError: (@Sendable () -> Error?)? = nil,
        answer: @escaping Answer = FakeEngine.speech
    ) {
        self.name = name
        self.model = model
        self.input = input
        self.prepareError = prepareError
        self.answer = answer
    }

    var counts: Counts { state.withLock { $0 } }

    func prepare() async throws {
        state.withLock { $0.prepared += 1 }
        if let error = prepareError?() { throw error }
    }

    func release() async { state.withLock { $0.released += 1 } }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let call = state.withLock { counts -> Int in
            counts.heard.append(audio)
            return counts.heard.count
        }
        return try answer(audio, call)
    }

    /// One line per file, sharing no words with any other file's line so the
    /// echo filter has nothing to drop.
    static let speech: Answer = { audio, call in
        [TranscriptSegment(start: 0, end: 1, text: "line \(call) from \(audio.lastPathComponent)")]
    }

    /// What a multichannel engine says: one voice per channel.
    static let bothSides: Answer = { _, call in
        [
            TranscriptSegment(start: 0, end: 1, text: "near side number \(call)", speaker: "1A"),
            TranscriptSegment(start: 1, end: 2, text: "far side reply \(call)", speaker: "2A"),
        ]
    }
}

extension TranscriptionCoordinator {
    /// Queue every session under `root` and wait until the queue has drained.
    func drainPending(in root: URL) async {
        guard !Self.pendingSessions(in: root).isEmpty else { return }
        let done = Gate()
        setStatusHandler { status in
            switch status {
            case .idle, .failed: done.open()
            case .transcribing: break
            }
        }
        resumePending(root: root)
        await done.pass()
    }
}

extension EngineResolver.Environment {
    /// A machine with local models, a key for every cloud service and a
    /// network, whose engines are the ones a test hands it.
    static func fake(
        localModels: Bool = true,
        hasKey: Bool = true,
        reachable: Bool = true,
        cloud: @escaping @Sendable (String) throws -> TranscriptionEngine = { _ in
            FakeEngine("assemblyai", input: .multichannel, answer: FakeEngine.bothSides)
        },
        local: @escaping @Sendable (String) -> TranscriptionEngine = { FakeEngine($0) }
    ) -> Self {
        Self(
            localModels: { localModels },
            hasKey: { _ in hasKey },
            reachable: { _ in reachable },
            cloudEngine: cloud,
            localEngine: local)
    }
}

/// A recordings root of a test's own, with finished recordings in it.
struct TestRecordings {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-recordings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// A finished two-track recording, named so that folders sort in the
    /// order they were made, with whatever extra state the test gives it.
    /// Naming and summarizing are marked as given up on, so finishing the
    /// session reaches for no language model.
    @discardableResult
    func session(_ name: String, seconds: Double = 1, state: [String: Any] = [:]) throws -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try TestAudio.writeTone(
            to: dir.appendingPathComponent("mic.caf"), seconds: seconds, frequency: 220)
        try TestAudio.writeTone(
            to: dir.appendingPathComponent("system.caf"), seconds: seconds, frequency: 660)
        var meta: [String: Any] = [
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": ["mic": 0, "system": 0],
            "duration_seconds": Int(seconds),
            SessionState.Key.speakersStatus: "failed",
            SessionState.Key.summaryStatus: "failed",
        ]
        meta.merge(state) { _, new in new }
        try JSONSerialization.data(withJSONObject: meta)
            .write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }
}
