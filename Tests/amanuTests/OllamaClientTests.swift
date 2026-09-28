import Foundation
import Testing

@testable import amanu

struct OllamaClientTests {
    @Test("Ollama chat keeps system and user messages separate and disables thinking")
    func chatRequest() throws {
        let request = try OllamaClient.chatRequest(
            baseURL: "https://studio.local:11434/",
            model: "qwen3.5:4b",
            system: "Take meeting notes.",
            prompt: "me: ship it",
            numContext: 16_384)

        #expect(request.url?.absoluteString == "https://studio.local:11434/api/chat")
        #expect(request.httpMethod == "POST")
        let requestBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(
            with: requestBody) as? [String: Any])
        #expect(body["model"] as? String == "qwen3.5:4b")
        #expect(body["stream"] as? Bool == false)
        #expect(body["think"] as? Bool == false)
        #expect((body["options"] as? [String: Any])?["num_ctx"] as? Int == 16_384)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [
            ["role": "system", "content": "Take meeting notes."],
            ["role": "user", "content": "me: ship it"],
        ])
    }

    @Test("Ollama reads only message content and surfaces its JSON error")
    func responseParsing() throws {
        let success = Data(###"{"message":{"role":"assistant","content":"## Decisions\nShip."},"thinking":"private"}"###.utf8)
        #expect(try OllamaClient.response(from: success, statusCode: 200)
            == "## Decisions\nShip.")

        let failure = Data(#"{"error":"model 'missing' not found"}"#.utf8)
        #expect(throws: LLMError.self) {
            _ = try OllamaClient.response(from: failure, statusCode: 404)
        }
    }

    @Test("Ollama model discovery retains size and remote provenance")
    func modelDiscovery() throws {
        let data = Data(#"{"models":[{"name":"qwen3.5:4b","size":3400000000},{"name":"gpt-oss:cloud","size":0,"remote_model":"gpt-oss","remote_host":"https://ollama.com"}]}"#.utf8)
        let models = try OllamaClient.models(from: data)

        #expect(models.map(\.name) == ["qwen3.5:4b", "gpt-oss:cloud"])
        #expect(models[0].bytes == 3_400_000_000)
        #expect(!models[0].isRemote)
        #expect(models[1].isRemote)
    }

    @Test("Only loopback Ollama URLs may promise that content stays on this Mac")
    func localURLClassification() {
        #expect(OllamaClient.isLocal(baseURL: "http://127.0.0.1:11434"))
        #expect(OllamaClient.isLocal(baseURL: "http://localhost:11434"))
        #expect(!OllamaClient.isLocal(baseURL: "http://studio.local:11434"))
        #expect(!OllamaClient.isLocal(baseURL: "https://ollama.example"))
    }

    // MARK: - context

    /// Ollama drops the front of a prompt longer than its context without a
    /// word, and the front is the instructions.
    @Test("The context asked for grows with the prompt, within a cap")
    func contextIsSizedToThePrompt() throws {
        let small = OllamaClient.contextSize(system: "Take notes.", prompt: "me: ship it")
        #expect(small == 8_192)

        let fitting = String(repeating: "обсудили план ", count: OllamaClient.promptLimit / 14)
        let sized = OllamaClient.contextSize(system: "Take notes.", prompt: fitting)
        #expect(sized > 16_384)
        #expect(sized <= OllamaClient.maxContext)
        #expect(sized >= (fitting.utf8.count / 3), "Sized below its own estimate of the prompt.")

        let request = try OllamaClient.chatRequest(
            baseURL: "http://127.0.0.1:11434", model: "qwen3:8b",
            system: "Take notes.", prompt: fitting)
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((body["options"] as? [String: Any])?["num_ctx"] as? Int == sized)

        let huge = String(repeating: "я", count: 200_000)
        #expect(OllamaClient.contextSize(system: "", prompt: huge) == OllamaClient.maxContext)
    }

    @Test("A transcript longer than Ollama can read whole is summarized in parts that fit")
    func summaryIsSplitToOllamasLimit() async throws {
        let dir = try SessionFixture.make()
        defer { try? FileManager.default.removeItem(at: dir) }
        let line = String(repeating: "обсудили план ", count: 20)
        // Longer than Ollama's limit, shorter than the summarizer's own.
        let transcript = Transcript(
            engine: "assemblyai", model: "test", created_at: "2026-09-01T10:00:00Z",
            segments: (0..<180).map {
                .init(speaker: "them", start_ms: $0 * 1000, end_ms: $0 * 1000 + 900, text: line)
            })
        let ollama = FakeModel("ollama") { _, _, prompt in
            prompt.contains("Combine them into one note") ? "MERGED" : "part"
        }
        ollama.promptLimit = OllamaClient.promptLimit
        let home = Home.withModels([ollama])
        defer { try? FileManager.default.removeItem(at: home.url) }
        try home.writeConfig(["summary": ["backend": "ollama"]])

        await Home.$scoped.withValue(home) {
            _ = await Summarizer.summarize(transcript: transcript, context: [], into: dir)
        }

        let prompts = ollama.prompts
        #expect(prompts.count >= 3, "One part and a merge at least; got \(prompts.count) calls")
        #expect(prompts.allSatisfy { $0.count <= OllamaClient.promptLimit + 1_000 })
    }

    @Test("Naming trims the transcript to what the backend can read whole")
    func namingBodyRespectsTheLimit() {
        let line = String(repeating: "обсудили план Фёдор ", count: 10)
        let transcript = Transcript(
            engine: "assemblyai", model: "test", created_at: "2026-09-01T10:00:00Z",
            segments: (0..<600).map {
                .init(speaker: "them A", start_ms: $0 * 1000, end_ms: $0 * 1000 + 900, text: line)
            })
        let body = SpeakerNamer.body(
            of: transcript, attendees: ["Фёдор Иванов"], limit: OllamaClient.promptLimit)
        #expect(body.count <= OllamaClient.promptLimit)
        #expect(body.contains("[… end of the meeting …]"))
    }

    // MARK: - where it may be

    /// Deliberate, and kept: a transcript does not cross a network in clear
    /// text. What changed is that the refusal says so, instead of arriving as
    /// a malformed URL nobody could act on.
    @Test("Plain http to another machine is refused in words that say how to fix it")
    func plainHTTPOffThisMacIsRefusedExplicitly() {
        #expect(throws: OpenAICompatible.EndpointError.insecure(
            host: "studio.local", baseURL: "http://studio.local:11434")) {
            _ = try OllamaClient.chatRequest(
                baseURL: "http://studio.local:11434/", model: "qwen3:8b",
                system: "", prompt: "")
        }
        let error = OpenAICompatible.EndpointError.insecure(
            host: "studio.local", baseURL: "http://studio.local:11434")
        #expect(error.description.contains("https"))
        #expect(!LLMError.isTransient(error))

        #expect(throws: OpenAICompatible.EndpointError.self) {
            _ = try OpenAICompatible.url(baseURL: "ollama", path: "api/chat")
        }
        #expect(throws: Never.self) {
            _ = try OpenAICompatible.url(baseURL: "http://localhost:11434", path: "api/chat")
            _ = try OpenAICompatible.url(baseURL: "https://studio.local", path: "api/chat")
        }
    }
}
