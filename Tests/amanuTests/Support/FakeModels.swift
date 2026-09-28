import Foundation

@testable import amanu

/// A language model that answers from a script and remembers what it was
/// asked — the stand-in for `claude`, `codex`, the APIs and Ollama in every
/// test that exercises the naming and summary passes.
final class FakeModel: @unchecked Sendable {
    typealias Script = @Sendable (_ call: Int, _ system: String, _ prompt: String) throws -> String

    let name: String
    private let script: Script
    private let lock = NSLock()
    private var asked: [String] = []

    init(_ name: String, script: @escaping Script) {
        self.name = name
        self.script = script
    }

    /// Always the same answer.
    convenience init(_ name: String, answer: String) {
        self.init(name) { _, _, _ in answer }
    }

    /// A model that does both jobs the way a real one would: a speaker
    /// mapping when it is asked who spoke, a note when it is asked for one.
    static func working(_ name: String) -> FakeModel {
        FakeModel(name) { _, system, _ in
            system.contains("identifying who spoke")
                ? SessionFixture.namesThemA
                : "## Summary\nWritten by \(name)."
        }
    }

    /// Always the same failure.
    convenience init(_ name: String, failing error: any Error) {
        self.init(name) { _, _, _ in throw error }
    }

    /// Every user prompt it has been handed, in order.
    var prompts: [String] { lock.withLock { asked } }
    var callCount: Int { prompts.count }

    var backend: LLMBackend {
        LLMBackend(name: name, model: "\(name)-model") { [self] system, prompt in
            let call = lock.withLock { () -> Int in
                asked.append(prompt)
                return asked.count - 1
            }
            return try script(call, system, prompt)
        }
    }
}

extension Home {
    /// A sandbox whose language models are these fakes, handed out the way
    /// the real chain hands out real ones: all of them in order for `auto`,
    /// only the one named for anything else.
    static func withModels(_ models: [FakeModel]) -> Home {
        let backends = models.map(\.backend)
        return .sandbox(languageModels: { preference in
            LLMBackend.chain(preference: preference, from: backends)
        })
    }
}

/// A session folder with a transcript in it, ready to be named and summarized.
enum SessionFixture {
    static let meeting: [Transcript.Segment] = [
        .init(speaker: "me", start_ms: 0, end_ms: 2000, text: "Привет! Фёдор, слышно меня?"),
        .init(speaker: "them A", start_ms: 3000, end_ms: 5000, text: "Да, слышно отлично."),
        .init(speaker: "them B", start_ms: 6000, end_ms: 8000, text: "И меня тоже, привет."),
    ]

    static func make(
        segments: [Transcript.Segment] = meeting,
        meta: [String: Any] = ["stop_reason": "manual", "title": "Planning"]
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
            .write(to: dir.appendingPathComponent("meta.json"))
        try Transcript(
            engine: "assemblyai", model: "test", created_at: "2026-09-01T10:00:00Z",
            segments: segments
        ).write(to: dir)
        return dir
    }

    static var transcript: Transcript {
        Transcript(
            engine: "assemblyai", model: "test", created_at: "2026-09-01T10:00:00Z",
            segments: meeting)
    }

    /// A naming answer that clears both gates for `them A`.
    static let namesThemA = """
    {"speakers": [{"label": "them A", "name": "Фёдор", "confidence": "high",
      "quote": "Фёдор, слышно меня?", "at_ms": 0}]}
    """
}
