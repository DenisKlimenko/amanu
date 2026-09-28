import Foundation

/// The keys amanu holds for other services: where each one lives, whether it
/// is there, and how to ask the service whether it still works.
///
/// Kept out of the setup form because none of it is about a window. The form
/// asks and draws; what it asks is answered here, where it can be checked
/// without building one.
enum Credentials {
    /// Whether the cloud transcription provider has a key to work with.
    static func hasTranscriptionKey(for provider: String) -> Bool {
        switch provider {
        case "openai": return Config.openAIKey() != nil
        case "elevenlabs": return Config.elevenLabsKey() != nil
        default: return Config.assemblyAIKey() != nil
        }
    }

    /// A key is a secret: it goes to a file only its owner can read, never
    /// into the config file — which the settings window shows on screen. The
    /// directory is amanu's own and mode 0700, so a key pasted here can't be
    /// overwritten by some other tool that keeps its secrets in the same place.
    static func writeSecret(_ value: String, to path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(value.utf8).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    /// Ask AssemblyAI whether it knows this key, now, rather than finding out
    /// after a meeting. The cheapest authenticated call it has.
    static func assemblyAIKeyWorks(_ key: String) async -> Bool {
        var request = URLRequest(
            url: URL(string: "https://api.assemblyai.com/v2/transcript?limit=1")!)
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    static func elevenLabsKeyWorks(_ key: String) async -> Bool {
        // Restricted keys can transcribe without permission to read /v1/user.
        // Submit no file to the STT endpoint: a permitted key gets validation
        // error 422, an invalid key gets 401, and nothing is transcribed.
        let boundary = "amanu-key-check"
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        request.httpBody = Data(("--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"model_id\"\r\n\r\n"
            + "scribe_v2\r\n--\(boundary)--\r\n").utf8)
        guard let (_, response) = try? await URLSession.shared.data(for: request) else {
            return false
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return status == 422
    }
}

/// A no-cost authentication check for the two summary API providers. Both
/// official APIs expose an authenticated model-list endpoint, so setup can
/// verify a key without generating (and billing for) any text.
enum SummaryKeyProbe {
    enum Provider {
        case anthropic
        case openAI
    }

    static func request(
        provider: Provider,
        key: String,
        openAIBaseURL: String = "https://api.openai.com/v1"
    ) -> URLRequest {
        let url: URL
        switch provider {
        case .anthropic:
            url = URL(string: "https://api.anthropic.com/v1/models?limit=1")!
        case .openAI:
            url = OpenAICompatible.endpoint(baseURL: openAIBaseURL, path: "models")
                ?? URL(string: "about:blank")!
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        switch provider {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        }
        return request
    }

    static func works(
        provider: Provider,
        key: String,
        openAIBaseURL: String = "https://api.openai.com/v1"
    ) async -> Bool {
        guard let (_, response) = try? await URLSession.shared.data(
            for: request(provider: provider, key: key, openAIBaseURL: openAIBaseURL)
        ) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
}
