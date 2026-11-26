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

    /// A finished answer for a stretch of the session: one word at each of
    /// `at`, in seconds from the start of whatever was sent.
    private static func heard(_ at: [Double], speaker: String = "spk:0") -> GeminiTranscriptionEngine.Response {
        let words = at.map { #"{"word":"w.","startOffset":"\#($0)s","endOffset":"\#($0 + 0.5)s"}"# }
        return try! decoded(#"{"candidates":[{"content":{"parts":[{"audioTranscription":{"speakerLabel":""#
            + speaker + #"","words":["# + words.joined(separator: ",") + #"]}}]},"finishReason":"STOP"}]}"#)
    }

    /// Sound in every second asked about.
    private static let loud: @Sendable (Range<Double>) async throws -> Int = {
        Int($0.upperBound - $0.lowerBound)
    }

    private static let looped = try! decoded(
        #"{"candidates":[{"content":{"parts":[]},"finishReason":"MAX_TOKENS"}]}"#)

    /// What was asked for, in order, so a test can say which requests were made.
    private actor Asked {
        var ranges: [Range<Double>] = []
        func add(_ range: Range<Double>) { ranges.append(range) }
    }

    /// The 2026.10.28 lesson looped on every fourteen-minute piece, and half
    /// of one that looped came back whole.
    @Test("A piece the model loops on is asked for again in halves, each on the session clock")
    func loopedPieceIsHalved() async throws {
        let asked = Asked()
        let segments = try await GeminiTranscriptionEngine.transcribe(840..<1680, label: "2", audible: Self.loud) { range in
            await asked.add(range)
            if range.upperBound - range.lowerBound > 500 { return Self.looped }
            // Words every 60 s, so neither half has a gap to ask about.
            return Self.heard(Array(stride(from: 1.0, to: range.upperBound - range.lowerBound, by: 60)))
        }
        #expect(await asked.ranges == [840..<1680, 840..<1260, 1260..<1680])
        #expect(segments.first?.start == 841)
        #expect(segments.contains { $0.start == 1261 && $0.speaker == "2b-spk:0" })
        #expect(segments.contains { $0.speaker == "2a-spk:0" })
        #expect(segments.map(\.start) == segments.map(\.start).sorted())
    }

    @Test("A loop that survives halving down to the shortest piece fails the transcription")
    func loopBelowTheFloorFails() async {
        let asked = Asked()
        await #expect(throws: GeminiTranscriptionEngine.EngineError.self) {
            _ = try await GeminiTranscriptionEngine.transcribe(0..<840, label: nil, audible: Self.loud) { range in
                await asked.add(range)
                return Self.looped
            }
        }
        // 14 → 7 → 3.5 → 1.75 minutes, and the first quarter-of-a-quarter fails.
        #expect(await asked.ranges.count == 4)
        #expect(await asked.ranges.last == 0..<105)
    }

    /// 2026.11.03 came back STOP with 1:00–14:00 empty; asked again for
    /// that stretch alone, the model heard it.
    @Test("Minutes the model went quiet on are asked for alone and fitted in on the session clock")
    func quietStretchIsAskedAgain() async throws {
        let asked = Asked()
        let segments = try await GeminiTranscriptionEngine.transcribe(840..<1680, label: "2", audible: Self.loud) { range in
            await asked.add(range)
            if range == 840..<1680 { return Self.heard([5, 30, 400]) }
            return Self.heard([2, 100], speaker: "spk:1")
        }
        // Words end at 845.5, 870.5 and 1240.5: the gap 870.5–1240 and the
        // tail 1240.5–1680 are asked again; nothing shorter than 90 s is.
        #expect(await asked.ranges == [840..<1680, 870.5..<1240, 1240.5..<1680])
        #expect(segments.map(\.start) == [845, 870, 872.5, 970.5, 1240, 1242.5, 1340.5])
        #expect(segments.filter { $0.speaker == "2g1-spk:1" }.map(\.start) == [872.5, 970.5])
        #expect(segments.filter { $0.speaker == "2g2-spk:1" }.map(\.start) == [1242.5, 1340.5])
    }

    /// 2026.10.28 had a 105-second break with five seconds of sound in it;
    /// asked about alone, the model repeated one phrase 1,310 times.
    @Test("A silent stretch is not asked about again")
    func silenceIsNotAskedAgain() async throws {
        let asked = Asked()
        let segments = try await GeminiTranscriptionEngine.transcribe(
            0..<840, label: nil,
            audible: { $0.lowerBound > 600 ? 5 : Int($0.upperBound - $0.lowerBound) }
        ) { range in
            await asked.add(range)
            return range == 0..<840 ? Self.heard([1, 700]) : Self.heard([1])
        }
        // 1.5–700 has sound and is asked again; 700.5–840 has five seconds
        // and is not.
        #expect(await asked.ranges == [0..<840, 1.5..<700])
        #expect(segments.count == 3)
    }

    /// What `unfilled` was told, from a closure that cannot await.
    private final class Left: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Range<Double>] = []
        func add(_ range: Range<Double>) { lock.withLock { stored.append(range) } }
        var ranges: [Range<Double>] { lock.withLock { stored } }
    }

    /// Asked again, a stretch can loop as the piece did; the rest of the
    /// meeting must not be lost for it.
    @Test("A stretch that loops when asked again stays a hole instead of failing the meeting")
    func loopedGapKeepsTheRest() async throws {
        let left = Left()
        let segments = try await GeminiTranscriptionEngine.transcribe(
            0..<840, label: "1", audible: Self.loud,
            unfilled: { gap, _ in left.add(gap) }
        ) { range in
            range == 0..<840 ? Self.heard(Array(stride(from: 1.0, through: 740, by: 30))) : Self.looped
        }
        #expect(segments.count == 25)
        #expect(segments.last?.start == 721)
        // The hole is reported, so the session log can say so.
        #expect(left.ranges == [721.5..<840])
    }

    /// Asked again, the model can hear the start of a stretch and drop the
    /// rest the way it did the first time.
    @Test("What a stretch asked again still leaves silent is reported, not asked a third time")
    func partlyFilledGapReportsTheRest() async throws {
        let asked = Asked()
        let left = Left()
        let segments = try await GeminiTranscriptionEngine.transcribe(
            0..<840, label: nil, audible: Self.loud, unfilled: { gap, _ in left.add(gap) }
        ) { range in
            await asked.add(range)
            return range == 0..<840 ? Self.heard([1]) : Self.heard([5])
        }
        #expect(await asked.ranges == [0..<840, 1.5..<840])
        #expect(segments.map(\.start) == [1, 6.5])
        #expect(left.ranges == [7..<840])

        // A rest that is silence is not minutes missing.
        let quiet = Left()
        _ = try await GeminiTranscriptionEngine.transcribe(
            0..<840, label: nil,
            audible: { $0.lowerBound >= 7 ? 5 : Int($0.upperBound - $0.lowerBound) },
            unfilled: { gap, _ in quiet.add(gap) }
        ) { range in range == 0..<840 ? Self.heard([1]) : Self.heard([5]) }
        #expect(quiet.ranges.isEmpty)
    }

    @Test("A hole inside a half of a looped piece is reported on the session clock")
    func holeInHalfIsReported() async throws {
        let left = Left()
        _ = try await GeminiTranscriptionEngine.transcribe(
            840..<1680, label: "2", audible: Self.loud,
            unfilled: { gap, _ in left.add(gap) }
        ) { range in
            switch range {
            case 840..<1680: return Self.looped
            case 840..<1260: return Self.heard(Array(stride(from: 1.0, to: 420, by: 60)))
            case 1260..<1680: return Self.heard([1])
            default: return Self.looped
            }
        }
        #expect(left.ranges == [1261.5..<1680])
    }

    @Test("An answer for a stretch that repeats one phrase at one moment is left out")
    func repeatingGapIsLeftOut() async throws {
        let left = Left()
        let segments = try await GeminiTranscriptionEngine.transcribe(
            0..<840, label: nil, audible: Self.loud,
            unfilled: { gap, _ in left.add(gap) }
        ) { range in
            if range == 0..<840 { return Self.heard([1, 700]) }
            // Words at one timestamp, a pause apart from nothing: each its
            // own part, as the loop's 1,310 speaker labels were.
            let parts = (0..<5).map { index in
                #"{"audioTranscription":{"speakerLabel":"spk:\#(index)","words":"#
                    + #"[{"word":"dzisiaj.","startOffset":"1s","endOffset":"1.4s"}]}}"#
            }
            return try Self.decoded(#"{"candidates":[{"content":{"parts":["#
                + parts.joined(separator: ",") + #"]},"finishReason":"STOP"}]}"#)
        }
        #expect(segments.map(\.start) == [1, 700])
        // The tail 700.5–840 is asked again too, and loops the same way.
        #expect(left.ranges == [1.5..<700, 700.5..<840])
    }

    @Test("A stretch asked again is not asked a third time, and a silent piece not a second")
    func askingAgainStops() async throws {
        let asked = Asked()
        let left = Left()
        let quiet = try await GeminiTranscriptionEngine.transcribe(
            0..<600, label: nil, audible: Self.loud, unfilled: { gap, _ in left.add(gap) }
        ) { range in
            await asked.add(range)
            return range == 0..<600 ? Self.heard([1]) : Self.heard([])
        }
        #expect(await asked.ranges == [0..<600, 1.5..<600])
        #expect(quiet.count == 1)
        #expect(left.ranges == [1.5..<600])

        let silent = Asked()
        let unheard = Left()
        let none = try await GeminiTranscriptionEngine.transcribe(
            0..<600, label: nil, audible: Self.loud, unfilled: { gap, _ in unheard.add(gap) }
        ) { range in
            await silent.add(range)
            return Self.heard([])
        }
        #expect(await silent.ranges == [0..<600])
        #expect(none.isEmpty)
        #expect(unheard.ranges == [0..<600])
    }

    @Test("The log line goes to the session folder, not echo cancellation's hidden one")
    func logIsTheSessions() {
        let session = URL(fileURLWithPath: "/r/2026.11.03-1530")
        #expect(GeminiTranscriptionEngine.session(of: session.appendingPathComponent("mixed.m4a")).path
            == session.path)
        #expect(GeminiTranscriptionEngine.session(
            of: session.appendingPathComponent(".transcription-aec-v3-0123/mixed.m4a")).path == session.path)
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

    /// The answer `gemini-3.5-transcribe` gave every request on 2026-10-07,
    /// one with nothing but the audio in it included, though amanu asks for no
    /// thinking. Retired, the meeting would not come back once Google fixed it.
    @Test("A refusal over thinking amanu never asked for waits for Google instead of retiring the meeting")
    func thinkingRefusalIsGooglesToFix() {
        let refusal = CloudHTTP.Failure.rejected(
            service: "gemini", what: "transcription", status: 400,
            body: #"{"error":{"code":400,"message":"Thinking is not enabled for this model","#
                + #""status":"INVALID_ARGUMENT"}}"#)
        let reclassified = GeminiTranscriptionEngine.reclassified(refusal)
        #expect(reclassified.isEnvironmental)
        #expect(!reclassified.isPermanent)
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
