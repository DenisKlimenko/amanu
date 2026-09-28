import Foundation

/// The small part of Ollama's native API Amanu needs. Keeping request
/// construction here makes the privacy boundary explicit and lets Setup use
/// the same configured server as the summarizer.
enum OllamaClient {
    struct Model: Equatable, Sendable {
        let name: String
        let bytes: Int
        let remoteModel: String?
        let remoteHost: String?

        var isRemote: Bool { remoteModel != nil || remoteHost != nil }
    }

    /// The largest context Amanu asks Ollama for. A context is memory: for
    /// the 8B default, 32k tokens of it is several gigabytes on top of the
    /// weights, which is what a laptop can spare while it records the next
    /// meeting. Prompts that would need more are cut to fit by the caller —
    /// see `promptLimit`.
    static let maxContext = 32_768

    /// The prompt, in characters, that `contextSize` keeps inside
    /// `maxContext`. Meetings here are mostly Russian, which costs about a
    /// token per two characters; English is cheaper, so this errs short.
    static let promptLimit = 36_000

    /// Room for the answer on top of the prompt.
    private static let replyTokens = 4_096

    /// The context to ask for, sized to what is being sent.
    ///
    /// Ollama does not refuse a prompt longer than `num_ctx`; it quietly drops
    /// the front of it. The front is the system prompt and the instructions,
    /// so a fixed 16k context against a 60k-character transcript produced an
    /// answer to no question at all. The estimate is a third of the UTF-8
    /// bytes — generous for English, about right for Cyrillic — plus room to
    /// answer, rounded up to 4k and kept between 8k and `maxContext`.
    static func contextSize(system: String, prompt: String) -> Int {
        let estimate = (system.utf8.count + prompt.utf8.count) / 3 + replyTokens
        let rounded = (estimate + 4_095) / 4_096 * 4_096
        return min(maxContext, max(8_192, rounded))
    }

    static func chatRequest(
        baseURL: String,
        model: String,
        system: String,
        prompt: String,
        numContext: Int? = nil
    ) throws -> URLRequest {
        let url = try OpenAICompatible.url(baseURL: baseURL, path: "api/chat")
        let numContext = numContext ?? contextSize(system: system, prompt: prompt)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 1_800
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": prompt],
            ],
            "stream": false,
            "think": false,
            "options": ["temperature": 0.2, "num_ctx": numContext],
        ])
        return request
    }

    static func response(from data: Data, statusCode: Int) throws -> String {
        guard (200..<300).contains(statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = json?["error"] as? String
                ?? String(decoding: data.prefix(400), as: UTF8.self)
            throw LLMError.http(statusCode, message)
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw LLMError.malformedResponse("ollama") }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMError.emptyResponse("ollama")
        }
        return content
    }

    static func models(from data: Data) throws -> [Model] {
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = json["models"] as? [[String: Any]]
        else { throw LLMError.malformedResponse("ollama") }
        return rows.compactMap { row in
            guard let name = row["name"] as? String else { return nil }
            return Model(
                name: name,
                bytes: (row["size"] as? NSNumber)?.intValue ?? 0,
                remoteModel: row["remote_model"] as? String,
                remoteHost: row["remote_host"] as? String)
        }
    }

    static func chat(
        baseURL: String,
        model: String,
        system: String,
        prompt: String,
        session: URLSession = .shared
    ) async throws -> String {
        let request = try chatRequest(
            baseURL: baseURL, model: model, system: system, prompt: prompt)
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try self.response(from: data, statusCode: statusCode)
    }

    static func listModels(
        baseURL: String,
        timeout: TimeInterval = 2,
        session: URLSession = .shared
    ) async throws -> [Model] {
        let url = try OpenAICompatible.url(baseURL: baseURL, path: "api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            throw LLMError.http(statusCode, String(decoding: data.prefix(400), as: UTF8.self))
        }
        return try models(from: data)
    }

    static func isLocal(baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return OpenAICompatible.isLoopback(host)
    }
}
