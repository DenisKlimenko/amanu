import Foundation

/// URL construction shared by the OpenAI backend and its no-cost key probe.
/// A compatible server may live below a path such as `/openai/v1`; replacing
/// the path with `appendingPathComponent` would silently discard that prefix.
enum OpenAICompatible {
    /// Why a configured Base URL will not be used.
    enum EndpointError: Error, Equatable, CustomStringConvertible {
        /// Not an http(s) URL with a host at all.
        case invalid(String)
        /// Plain http to somewhere other than this Mac.
        case insecure(host: String, baseURL: String)

        var description: String {
            switch self {
            case .invalid(let baseURL):
                return "\"\(baseURL)\" is not an http(s) URL with a host"
            case .insecure(let host, let baseURL):
                return "\(baseURL) is plain http to \(host), which would carry the meeting "
                    + "across the network unencrypted — use https for a server on another "
                    + "machine (a TLS proxy in front of Ollama will do), or an address on this Mac"
            }
        }
    }

    static func endpoint(baseURL: String, path: String) -> URL? {
        try? url(baseURL: baseURL, path: path)
    }

    /// The endpoint, or the reason there isn't one — distinct, because "this
    /// is not a URL" and "this URL would send the transcript in clear text"
    /// are fixed in different ways, and both used to arrive as a bare
    /// `URLError(.badURL)` that the log could say nothing useful about.
    static func url(baseURL: String, path: String) throws -> URL {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let parsed = URL(string: base),
              ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              let host = parsed.host?.lowercased()
        else { throw EndpointError.invalid(baseURL) }
        // Keys and transcripts must not cross a network in clear text. HTTP
        // remains useful for a server on this Mac, including Ollama's default.
        // The rule is deliberate and stays; what changed is that breaking it
        // is now said in words rather than as a malformed URL.
        guard parsed.scheme?.lowercased() == "https" || isLoopback(host) else {
            throw EndpointError.insecure(host: host, baseURL: base)
        }
        let suffix = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base + "/" + suffix) else {
            throw EndpointError.invalid(baseURL)
        }
        return url
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
