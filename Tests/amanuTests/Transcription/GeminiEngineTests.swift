import Foundation
import Testing

@testable import amanu

/// Vertex returns words, not utterances. Everything here is about turning the
/// one into the other without losing a word, a speaker, or the session clock.
struct GeminiEngineTests {
    /// The shape of a real response from `gemini-3.5-transcribe-preview`,
    /// trimmed: one part per speaker turn, offsets as duration strings, and
    /// whole seconds written without a decimal point.
    private static let response = """
    {"candidates":[{"content":{"role":"model","parts":[
      {"text":"Всем привет.","audioTranscription":{"speakerLabel":"spk:0","text":"Всем привет.",
        "words":[{"word":"Всем","startOffset":"0.600s","endOffset":"1s"},
                 {"word":"привет.","startOffset":"1s","endOffset":"1.500s"},
                 {"word":"Начнём.","startOffset":"3.100s","endOffset":"3.800s"}]}},
      {"text":"Hi everyone.","audioTranscription":{"speakerLabel":"spk:1","text":"Hi everyone.",
        "words":[{"word":"Hi","startOffset":"7.300s","endOffset":"7.500s"},
                 {"word":"everyone.","startOffset":"7.500s","endOffset":"8.200s"}]}}
    ]},"finishReason":"STOP"}],"modelVersion":"gemini-3.5-transcribe-preview"}
    """

    private static func decoded(_ json: String) throws -> GeminiTranscriptionEngine.Response {
        try JSONDecoder().decode(GeminiTranscriptionEngine.Response.self, from: Data(json.utf8))
    }

    @Test("Words become segments per speaker, split at a pause, on the session clock")
    func segmentsFromWords() throws {
        let segments = GeminiTranscriptionEngine.segments(
            from: try Self.decoded(Self.response), offset: 840, labelPrefix: "2")
        #expect(segments.map(\.text) == ["Всем привет.", "Начнём.", "Hi everyone."])
        #expect(segments.map(\.speaker) == ["2-spk:0", "2-spk:0", "2-spk:1"])
        #expect(segments.map(\.start) == [840.6, 843.1, 847.3])
        #expect(segments.map(\.end) == [841.5, 843.8, 848.2])
    }

    @Test("A long monologue is cut at a sentence end, not mid-sentence")
    func longTurnSplitsAtSentences() throws {
        var words: [String] = []
        for index in 0..<30 {
            let start = Double(index)
            let text = [9, 21, 29].contains(index) ? "end\(index)." : "w\(index)"
            words.append(#"{"word":"\#(text)","startOffset":"\#(start)s","endOffset":"\#(start + 0.9)s"}"#)
        }
        let json = #"{"candidates":[{"content":{"parts":[{"audioTranscription":{"speakerLabel":"spk:0","words":["#
            + words.joined(separator: ",") + #"]}}]},"finishReason":"STOP"}]}"#
        let segments = GeminiTranscriptionEngine.segments(
            from: try Self.decoded(json), offset: 0, labelPrefix: nil)
        // Twenty seconds pass mid-sentence, at w20; the cut waits for end21.
        #expect(segments.count == 2)
        #expect(segments.first?.text.hasSuffix("end21.") == true)
        #expect(segments.last?.text.hasSuffix("end29.") == true)
    }

    @Test("A reply cut short is not a transcript")
    func unfinishedIsReported() throws {
        let cut = #"{"candidates":[{"content":{"parts":[]},"finishReason":"MAX_TOKENS"}]}"#
        #expect(try Self.decoded(cut).unfinishedReason == "MAX_TOKENS")
        #expect(try Self.decoded(Self.response).unfinishedReason == nil)
    }

    @Test("Config language codes gain the region Vertex asks for")
    func languageCodes() {
        #expect(GeminiTranscriptionEngine.bcp47("ru") == "ru-RU")
        #expect(GeminiTranscriptionEngine.bcp47("en") == "en-US")
        #expect(GeminiTranscriptionEngine.bcp47("pt-BR") == "pt-BR")
    }

    /// The key is checked against the model it will be sent to, by that
    /// model's Gemini API name — the `-preview` Vertex uses answers 404 there.
    @Test("A pasted key is checked against the model it will transcribe with")
    func keyProbeAsksAfterTheModel() {
        let probe = GeminiTranscriptionEngine.keyProbe("gemini-secret", model: nil)
        #expect(probe.url?.absoluteString
            == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe")
        #expect(probe.httpMethod == "GET")
        #expect(probe.value(forHTTPHeaderField: "x-goog-api-key") == "gemini-secret")

        let configured = GeminiTranscriptionEngine.keyProbe("gemini-secret", model: "gemini-next")
        #expect(configured.url?.lastPathComponent == "gemini-next")
    }

    /// Vertex's login is looked for where Google's libraries look for it, or
    /// the setup card would call a working login missing, and auto would
    /// transcribe locally a meeting that could have gone to Vertex.
    @Test("Application-default credentials are found where gcloud leaves them")
    func applicationDefaultCredentials() {
        func found(_ environment: [String: String]) -> String {
            Config.applicationDefaultCredentials(home: Home(
                url: URL(fileURLWithPath: "/Users/someone", isDirectory: true),
                environment: environment, discoversTools: false, languageModels: nil)).path
        }
        #expect(found([:]) == "/Users/someone/.config/gcloud/application_default_credentials.json")
        #expect(found(["CLOUDSDK_CONFIG": "~/gcloud-work"])
            == "/Users/someone/gcloud-work/application_default_credentials.json")
        // A file named outright wins over any directory, as it does for them.
        #expect(found([
            "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/service-account.json",
            "CLOUDSDK_CONFIG": "~/gcloud-work",
        ]) == "/tmp/service-account.json")
        #expect(found(["GOOGLE_APPLICATION_CREDENTIALS": "  "])
            == "/Users/someone/.config/gcloud/application_default_credentials.json")
    }

    /// A revoked key must not retire every meeting it meets: the Gemini API
    /// says 400 where the others say 401, and only the reason tells the two
    /// kinds of 400 apart.
    @Test("A key the Gemini API does not know waits for a new key instead of retiring the meeting")
    func unknownKeyIsTheMachines() {
        func rejected(_ body: String) -> CloudHTTP.Failure {
            .rejected(service: "gemini", what: "transcription", status: 400, body: body)
        }
        let unknownKey = rejected(#"{"error":{"code":400,"status":"INVALID_ARGUMENT","#
            + #""details":[{"reason":"API_KEY_INVALID"}]}}"#)
        #expect(GeminiTranscriptionEngine.reclassified(unknownKey).isEnvironmental)
        #expect(GeminiTranscriptionEngine.reclassified(rejected("audio too long")).isPermanent)
    }

    /// A signed-in gcloud always has some project configured — whichever one
    /// the last piece of work needed. Sending meetings to it would bill a
    /// project nobody chose for them, so without a key Vertex is a way in only
    /// for the project amanu's own config names.
    @Test("Vertex is a way in only for a project the config names")
    func vertexNeedsANamedProject() throws {
        let login = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-adc-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: login)
        defer { try? FileManager.default.removeItem(at: login) }
        let noLogin = login.appendingPathExtension("missing")
        let gcloud = "/opt/homebrew/bin/gcloud"

        #expect(Config.geminiRoute(gcloud: gcloud, key: nil, project: nil, credentials: login) == nil)
        #expect(Config.geminiRoute(gcloud: gcloud, key: nil, project: "meetings", credentials: login)
            == .vertex)
        #expect(Config.geminiRoute(gcloud: gcloud, key: nil, project: "meetings", credentials: noLogin)
            == nil)
        #expect(Config.geminiRoute(gcloud: nil, key: nil, project: "meetings", credentials: login) == nil)
        // A key wins, even over a project named outright.
        #expect(Config.geminiRoute(gcloud: gcloud, key: "AQ.key", project: "meetings", credentials: login)
            == .apiKey)
    }
}
