import Foundation
import Testing

@testable import amanu

/// Naming and summarizing must be able to give up.
///
/// `auto` ends every chain with Ollama, and an Ollama nobody installed
/// refuses the connection — which counted as a failure that passes, and made
/// every other failure in the chain pass with it. A billed API answering
/// nonsense was deferred for ever, and the whole transcript went back to every
/// backend at every launch and every change of network.
struct ChainGiveUpTests {
    private static func home(
        config: [String: Any] = [:], _ backends: [LLMBackend]
    ) throws -> Home {
        let home = Home.sandbox(languageModels: { LLMBackend.chain(preference: $0, from: backends) })
        try home.writeConfig(config)
        return home
    }

    private static func backend(
        _ name: String, unchosen: Bool = false, failing error: any Error
    ) -> (LLMBackend, Calls) {
        let calls = Calls()
        var backend = LLMBackend(name: name, model: nil) { _, _ in
            calls.note()
            throw error
        }
        backend.isUnchosenFallback = unchosen
        return (backend, calls)
    }

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func note() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    private static func summarize(_ dir: URL) async {
        await Summarizer.summarize(
            transcript: SessionFixture.transcript, context: [], into: dir)
    }

    // MARK: - the Ollama nobody chose

    @Test("The Ollama at the end of auto is a fallback nobody chose until somebody does")
    func ollamaIsUnchosenUntilConfigured() throws {
        let home = Home(
            url: Home.sandbox().url, environment: [:], discoversTools: false, languageModels: nil)
        defer { try? FileManager.default.removeItem(at: home.url) }
        try Home.$scoped.withValue(home) {
            let auto = LLMBackend.available(preference: "auto")
            #expect(auto.map(\.name) == ["ollama"])
            #expect(auto.first?.isUnchosenFallback == true)
            #expect(LLMBackend.available(preference: "ollama").first?.isUnchosenFallback == false)

            try home.writeConfig(["summary": ["ollama_model": "qwen3:8b"]])
            #expect(LLMBackend.available(preference: "auto").first?.isUnchosenFallback == false)
        }
    }

    @Test("A bad answer is given up on even though the Ollama nobody chose refused the connection")
    func refusedFallbackDoesNotDeferABadAnswer() async throws {
        let (api, _) = Self.backend("anthropic-api", failing: LLMError.malformedResponse("anthropic-api"))
        let (ollama, _) = Self.backend(
            "ollama", unchosen: true, failing: URLError(.cannotConnectToHost))
        let home = try Self.home([api, ollama])
        defer { try? FileManager.default.removeItem(at: home.url) }
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        await Home.$scoped.withValue(home) { await Self.summarize(dir) }

        #expect(SessionState.value(dir, SessionState.Key.summaryStatus) as? String
            == SessionState.failed)
        #expect(SessionState.value(dir, SessionState.Key.summaryFailedFor) != nil)
        #expect(Home.$scoped.withValue(home) {
            !PostProcessor.outstanding(dir, policy: .init(names: false, summary: true)).summary
        })
    }

    @Test("An Ollama somebody chose that is not running yet is still worth waiting for")
    func chosenOllamaStillDefers() async throws {
        let (ollama, _) = Self.backend("ollama", failing: URLError(.cannotConnectToHost))
        let home = try Self.home(config: ["summary": ["backend": "ollama"]], [ollama])
        defer { try? FileManager.default.removeItem(at: home.url) }
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        await Home.$scoped.withValue(home) { await Self.summarize(dir) }

        #expect(SessionState.value(dir, SessionState.Key.summaryStatus) as? String
            == SessionState.deferred)
        #expect(SessionState.value(dir, SessionState.Key.summaryDeferrals) == nil,
                "a server that was never reached was not sent the meeting")
    }

    // MARK: - the cap

    @Test("A summary deferred after reaching a backend is given up on after a few tries")
    func reachedDeferralsRunOut() async throws {
        let (api, calls) = Self.backend("openai-api", failing: LLMError.http(503, "overloaded"))
        let home = try Self.home([api])
        defer { try? FileManager.default.removeItem(at: home.url) }
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let policy = PostProcessor.Policy(names: false, summary: true)

        var runs = 0
        while runs < 20, Home.$scoped.withValue(home, operation: {
            PostProcessor.outstanding(dir, policy: policy).summary
        }) {
            await Home.$scoped.withValue(home) { await Self.summarize(dir) }
            runs += 1
        }

        #expect(runs == ChainAttempt.maxDeferrals)
        #expect(calls.count == ChainAttempt.maxDeferrals)
        #expect(SessionState.value(dir, SessionState.Key.summaryStatus) as? String
            == SessionState.failed)
        #expect(SessionState.value(dir, SessionState.Key.summaryDeferrals) == nil)
    }

    @Test("Deferrals that reached nobody are not counted: that is the plane")
    func unreachedDeferralsAreFree() async throws {
        let (api, _) = Self.backend("claude-cli", failing: LLMError.exit(1, "API Error: Connection error."))
        let home = try Self.home([api])
        defer { try? FileManager.default.removeItem(at: home.url) }
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        for _ in 0..<(ChainAttempt.maxDeferrals * 2) {
            await Home.$scoped.withValue(home) { await Self.summarize(dir) }
        }

        #expect(SessionState.value(dir, SessionState.Key.summaryStatus) as? String
            == SessionState.deferred)
        #expect(SessionState.value(dir, SessionState.Key.summaryDeferrals) == nil)
    }

    @Test("Naming runs out of tries the same way")
    func namingDeferralsRunOut() async throws {
        let (api, calls) = Self.backend("anthropic-api", failing: LLMError.http(529, "overloaded"))
        let home = try Self.home([api])
        defer { try? FileManager.default.removeItem(at: home.url) }
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        for _ in 0..<(ChainAttempt.maxDeferrals + 3) {
            let status = SessionState.value(dir, SessionState.Key.speakersStatus) as? String
            guard status != SessionState.failed else { break }
            await Home.$scoped.withValue(home) {
                await SpeakerNamer.name(
                    transcript: SessionFixture.transcript, title: nil, attendees: [], app: nil,
                    into: dir)
            }
        }

        #expect(calls.count == ChainAttempt.maxDeferrals)
        #expect(SessionState.value(dir, SessionState.Key.speakersStatus) as? String
            == SessionState.failed)
    }

    @Test("A summary that is written clears the count")
    func successClearsTheCount() async throws {
        let flaky = Calls()
        let api = LLMBackend(name: "openai-api", model: nil) { _, _ in
            flaky.note()
            if flaky.count < 3 { throw LLMError.http(503, "overloaded") }
            return "## Summary\nDone."
        }
        let home = try Self.home([api])
        defer { try? FileManager.default.removeItem(at: home.url) }
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }

        for _ in 0..<3 { await Home.$scoped.withValue(home) { await Self.summarize(dir) } }

        #expect(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("summary.md").path))
        #expect(SessionState.value(dir, SessionState.Key.summaryDeferrals) == nil)
        #expect(SessionState.value(dir, SessionState.Key.summaryStatus) == nil)
    }
}
