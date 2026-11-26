import AVFoundation
import Foundation

/// Gemini 3.5 Transcribe on Vertex AI, over the mixed-down session audio.
///
/// It answers the question the other cloud engines answer — timed words, and
/// which voice said them — so it is a `.mixed` engine and everything downstream
/// is shared: track attribution puts me/them back on its labels, and the Meet
/// timeline, when there is one, names the far end.
///
/// Three things about the API leak into the code:
///
/// - **Fifteen minutes a request.** With timestamps or diarization on, Vertex
///   takes no more audio than that, so a meeting is cut into pieces well under
///   it and the timings shifted back onto the session clock. Speaker labels
///   are per request, so they are kept apart per piece, exactly as for OpenAI.
/// - **Timings are per word.** Vertex does not return utterance times for a
///   file, so segments are rebuilt from the words: a new one at every change
///   of speaker, at a pause, and at a sentence end once a monologue has run
///   long. Shorter segments are also what lets the Meet timeline attribute a
///   voice accurately.
/// - **Two ways in.** An AI Studio key in `Config.geminiKeyPath` sends the
///   audio to the Gemini API, billed to the key's own project. Without one,
///   Vertex takes an OAuth token instead — `gcloud auth application-default
///   login` — but only for a project the config names. The token is asked
///   of `gcloud` per request, so an hour-long upload never outlives the one
///   it started with. The key is the sturdier of the two for
///   something that runs unattended — it does not lapse when an organisation
///   makes gcloud sign in again — but only a paid-tier key is fit for
///   meetings: the free tier's data is used to improve Google's products.
///
/// Either way about $0.31 an hour of meeting, billed to the key's project or
/// to `transcription.gemini.project` — never to the one `gcloud` happens to be
/// configured for, which was set for other work and may be one nobody means
/// to spend from.
///
/// Every response is cached next to the audio (see `ProviderCache`), so a
/// retry after a crash re-renders from disk instead of paying again.
actor GeminiTranscriptionEngine: TranscriptionEngine {
    enum EngineError: TranscriptionFailure, CustomStringConvertible {
        case noCredentials
        case noToken(String)
        case unfinished(String)
        case empty
        /// Refused over something amanu never sent — see `reclassified`.
        case serviceFault(String)

        /// Only "there was no speech in this audio" is permanent. HTTP
        /// answers are classified by `CloudHTTP`.
        var isPermanent: Bool {
            if case .empty = self { return true }
            return false
        }

        /// A lapsed login or a missing project is the machine's, fixed by a
        /// person, after which the next sweep should simply work — so it
        /// costs the recording none of its attempts. A fault on Google's side
        /// is the same, fixed by Google.
        var isEnvironmental: Bool {
            switch self {
            case .noCredentials, .noToken, .serviceFault: return true
            case .unfinished, .empty: return false
            }
        }

        var description: String {
            switch self {
            case .noCredentials:
                return "gemini needs an AI Studio key in \(Config.geminiKeyPath.path) (chmod 600), "
                    + "or, for Vertex AI, transcription.gemini.project in \(Config.path.path) "
                    + "and gcloud auth application-default login (brew install --cask gcloud-cli)"
            case .noToken(let detail):
                return "gcloud has no usable credentials — run gcloud auth application-default "
                    + "login (\(detail.prefix(200)))"
            case .unfinished(let reason):
                return "gemini stopped before the end of the audio: \(reason)"
            case .empty:
                return "gemini returned no speech"
            case .serviceFault(let body):
                return "gemini refused the transcription over thinking, which amanu does not ask for — "
                    + "a fault on Google's side, so the recording waits for their fix: "
                    + "HTTP 400 \(body.prefix(400))"
            }
        }
    }

    /// Vertex's own ceiling is fifteen minutes with timestamps on. Fourteen
    /// leaves room for the encoder rounding a piece up by a frame or two, which
    /// would otherwise cost the whole piece.
    static let defaultPieceLength: TimeInterval = 14 * 60

    nonisolated let name = "gemini"
    nonisolated let model: String
    nonisolated let input: TranscriptionInput = .mixed

    /// Present means the Gemini API; absent, Vertex through `gcloud`.
    private let apiKey: String?
    private let gcloud: String?
    private let settings: Config.GeminiSettings
    /// BCP 47 codes for the languages this meeting may be in. Several at once
    /// is how Vertex is told to expect a mix, which a Russian meeting full of
    /// English terms is. The Gemini API gets none: its model reads the same
    /// hint as a filter, and on a ru/en test call it returned the Russian
    /// sentences alone, as one speaker, with the English ones gone. Without
    /// the hint it heard both languages and all three voices, while Vertex
    /// without it dropped words and merged two speakers.
    private let languages: [String]
    private let pieceLength: TimeInterval
    private let http = CloudHTTP(service: .gemini)
    private var endpoint: URL?

    init(pieceLength: TimeInterval = GeminiTranscriptionEngine.defaultPieceLength) throws {
        apiKey = Config.geminiKey()
        gcloud = Tooling.path(for: "gcloud")
        settings = Config.gemini()
        guard Config.geminiRoute(gcloud: gcloud, key: apiKey, project: settings.project) != nil else {
            throw EngineError.noCredentials
        }
        model = settings.model ?? Self.defaultModel(apiKey: apiKey != nil)
        languages = apiKey != nil ? [] : MeetingLanguages.expected(primary: Config.transcriptionLanguage())
            .map(Self.bcp47)
        self.pieceLength = pieceLength
    }

    /// The model each way in calls when the config names none. The two APIs
    /// name the same model differently: the Gemini API answers 404 for
    /// `-preview`, and Vertex has only that.
    static func defaultModel(apiKey: Bool) -> String {
        apiKey ? "gemini-3.5-transcribe" : "gemini-3.5-transcribe-preview"
    }

    static let geminiAPIModels = "https://generativelanguage.googleapis.com/v1beta/models/"

    /// A free check of an AI Studio key: the model it would transcribe with,
    /// looked up by name. Asking after that model rather than listing them
    /// means a good key that cannot reach it is refused now instead of by the
    /// first meeting — and nothing is generated, so nothing is billed.
    static func keyProbe(_ key: String, model: String?) -> URLRequest {
        var request = URLRequest(
            url: URL(string: geminiAPIModels + (model ?? defaultModel(apiKey: true)))!)
        request.timeoutInterval = 15
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    func prepare() async throws {}
    func release() async {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let dir = audio.deletingLastPathComponent()
        let scratch = dir.appendingPathComponent("gemini-slices")
        let slices = try await AudioSlicer.slice(audio, every: pieceLength, into: scratch)
        if slices.count > 1 {
            Self.note("\(slices.count) pieces — Vertex takes at most fifteen minutes a request")
        }

        var segments: [TranscriptSegment] = []
        for (index, slice) in slices.enumerated() {
            guard let length = AudioSlicer.duration(of: slice.url) else {
                throw AudioSlicer.SliceError.unreadable(slice.url, nil)
            }
            let whole = slice.offset..<(slice.offset + length)
            let piece = slices.count > 1 ? "\(index + 1)" : nil
            let count = slices.count
            segments += try await Self.transcribe(whole, label: piece, audible: { range in
                try await AudioSlicer.audibleSeconds(
                    in: audio, from: range.lowerBound, to: range.upperBound)
            }, unfilled: { gap, why in
                // The log, not stderr: this is minutes of the meeting missing
                // from the transcript, and nothing else would say so.
                appendSessionLog(
                    "gemini left \(Self.describe(gap)) untranscribed, though there is sound in it: \(why)",
                    to: Self.session(of: audio))
            }) { range in
                let cache = await self.cacheURL(
                    in: dir, audio: audio, suffix: range == whole ? piece : Self.suffix(for: range),
                    of: count)
                return try await self.response(
                    for: range, file: range == whole ? slice.url : nil, audio: audio,
                    scratch: scratch, cache: cache)
            }
        }
        try? FileManager.default.removeItem(at: scratch)

        guard !segments.isEmpty else { throw EngineError.empty }
        return segments
    }

    /// A piece no shorter than this is halved when the model runs out of
    /// tokens on it; one shorter fails the transcription. Seven-minute and
    /// three-and-a-half-minute halves of pieces that looped have come back
    /// whole, and below a minute a loop is not the length's fault.
    static let shortestHalvedPiece: TimeInterval = 2 * 60

    /// A stretch this long inside a piece with no words in the answer is
    /// asked about again, on its own, if `audibleEnough` of it has sound.
    /// The model sometimes answers STOP with minutes of speech missing —
    /// most often the end of a piece, sometimes its middle — and asking for
    /// the same piece again loses the same minutes, while asking for just
    /// the missing stretch has brought them back. A real silence must not be
    /// asked about: on 2026.10.28's 105-second break, with five seconds of
    /// sound in it, the model answered STOP with one phrase from before the
    /// break repeated 1,310 times.
    static let silentGap: TimeInterval = 90
    /// Seconds of speech-level sound a silent gap needs to be asked about.
    /// The break above had five; the stretches the model dropped had sound
    /// in nearly every second.
    static let audibleEnough = 30

    /// `range` of the session, transcribed by what `ask` returns for it — a
    /// piece the model loops on is asked for again in halves, and a stretch
    /// with sound in it (`audible`, in seconds) that the model went quiet on
    /// is asked for again by itself, once. A stretch that asking again does
    /// not fill is handed to `unfilled` with the reason. Pure but for the
    /// closures, so all of it is testable without a Google account.
    static func transcribe(
        _ range: Range<TimeInterval>,
        label: String?,
        askingAgainForGaps: Bool = true,
        audible: @Sendable (Range<TimeInterval>) async throws -> Int,
        unfilled: @Sendable (Range<TimeInterval>, String) -> Void = { _, _ in },
        ask: @Sendable (Range<TimeInterval>) async throws -> Response
    ) async throws -> [TranscriptSegment] {
        let response = try await ask(range)
        if let reason = response.unfinishedReason {
            guard range.upperBound - range.lowerBound >= shortestHalvedPiece else {
                throw EngineError.unfinished(reason)
            }
            note("\(reason) on \(describe(range)), asking in halves")
            let middle = (range.lowerBound + range.upperBound) / 2
            return try await transcribe(
                range.lowerBound..<middle, label: (label ?? "") + "a",
                askingAgainForGaps: askingAgainForGaps, audible: audible, unfilled: unfilled,
                ask: ask)
                + transcribe(
                    middle..<range.upperBound, label: (label ?? "") + "b",
                    askingAgainForGaps: askingAgainForGaps, audible: audible, unfilled: unfilled,
                    ask: ask)
        }

        var segments = segments(from: response, offset: range.lowerBound, labelPrefix: label)
        guard askingAgainForGaps else { return segments }
        for (index, gap) in gaps(in: segments, of: range).enumerated() {
            guard try await audible(gap) >= audibleEnough else { continue }
            // The whole piece silent is the same audio asked again, and the
            // same answer back.
            guard gap != range else {
                unfilled(gap, "the answer had no words in it")
                continue
            }
            note("nothing heard in \(describe(gap)), asking for it alone")
            // Asking again is a repair: if it fails the way the piece did,
            // the meeting keeps its hole rather than losing everything else.
            do {
                let found = try await transcribe(
                    gap, label: "\(label ?? "")g\(index + 1)", askingAgainForGaps: false,
                    audible: audible, ask: ask)
                guard !found.isEmpty else {
                    unfilled(gap, "asked again, no words again")
                    continue
                }
                guard !repeatsItself(found) else {
                    unfilled(gap, "asked again, the answer repeated one phrase")
                    continue
                }
                segments += found
                // The answer can leave part of the stretch without words the
                // way the piece did; a third ask is not made, but that part
                // is still minutes missing.
                for rest in gaps(in: found, of: gap) {
                    guard try await audible(rest) >= audibleEnough else { continue }
                    unfilled(rest, "asked again, part of it still has no words")
                }
            } catch let EngineError.unfinished(reason) {
                unfilled(gap, "asked again, \(reason) again")
            }
        }
        return segments.sorted { $0.start < $1.start }
    }

    /// The same words at the same moment more than twice: the loop the
    /// model fell into on 2026.10.28's break, 1,310 copies of one phrase at
    /// one timestamp, answered STOP. Nobody says that.
    static func repeatsItself(_ segments: [TranscriptSegment]) -> Bool {
        var seen: [String: Int] = [:]
        for segment in segments {
            let key = "\(segment.start) \(segment.text)"
            seen[key, default: 0] += 1
            if seen[key]! > 2 { return true }
        }
        return false
    }

    /// The stretches of `range` at least `silentGap` long that no segment
    /// covers.
    static func gaps(
        in segments: [TranscriptSegment], of range: Range<TimeInterval>
    ) -> [Range<TimeInterval>] {
        var gaps: [Range<TimeInterval>] = []
        var heard = range.lowerBound
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            if segment.start - heard >= silentGap { gaps.append(heard..<segment.start) }
            heard = max(heard, segment.end)
        }
        if range.upperBound - heard >= silentGap { gaps.append(heard..<range.upperBound) }
        return gaps
    }

    /// One request: from the cache when an earlier run got this far, else
    /// sent — the piece's own slice when `file` is given, else `range` cut
    /// from the mix. Only a finished answer is cached: one cut short by a
    /// loop is halved this run and would only be halved again the next.
    private func response(
        for range: Range<TimeInterval>, file: URL?, audio: URL, scratch: URL, cache: URL
    ) async throws -> Response {
        if let cached = try? Data(contentsOf: cache),
           let decoded = try? JSONDecoder().decode(Response.self, from: cached) {
            Self.note("reusing cached \(cache.lastPathComponent)")
            return decoded
        }
        var upload = file
        if upload == nil {
            let excerpt = scratch.appendingPathComponent("range-\(Self.suffix(for: range)).m4a")
            try await AudioSlicer.excerpt(
                audio, from: range.lowerBound, to: range.upperBound, into: excerpt)
            upload = excerpt
        }
        if endpoint == nil { endpoint = try await resolveEndpoint() }
        let raw = try await send(upload!, to: endpoint!)
        if file == nil { try? FileManager.default.removeItem(at: upload!) }
        let response = try http.decode(Response.self, from: raw, what: "transcription")
        if response.unfinishedReason == nil { try? raw.write(to: cache, options: .atomic) }
        return response
    }

    /// A part of a piece, named by where it lies on the session clock.
    static func suffix(for range: Range<TimeInterval>) -> String {
        "\(Int(range.lowerBound * 1000))-\(Int(range.upperBound * 1000))"
    }

    /// The session folder for `audio`. With offline echo cancellation the
    /// mix is made in a hidden folder of cleaned copies, which is removed
    /// once the transcript is written; the log is the session's own.
    static func session(of audio: URL) -> URL {
        let dir = audio.deletingLastPathComponent()
        return dir.lastPathComponent.hasPrefix(TranscriptionScratch.echoFolderPrefix)
            ? dir.deletingLastPathComponent() : dir
    }

    /// On transcript.md's clock, so the log's times can be looked up there.
    private static func describe(_ range: Range<TimeInterval>) -> String {
        "\(Transcript.clock(Int(range.lowerBound * 1000)))–\(Transcript.clock(Int(range.upperBound * 1000)))"
    }

    // MARK: - API

    private func resolveEndpoint() async throws -> URL {
        if apiKey != nil {
            return URL(string: Self.geminiAPIModels + "\(model):generateContent")!
        }
        guard let project = settings.project else { throw EngineError.noCredentials }
        // The global endpoint has no region in its host name; every other
        // location does.
        let host = settings.location == "global"
            ? "aiplatform.googleapis.com"
            : "\(settings.location)-aiplatform.googleapis.com"
        return URL(string: "https://\(host)/v1beta1/projects/\(project)/locations/"
            + "\(settings.location)/publishers/google/models/\(model):generateContent")!
    }

    private func accessToken() async throws -> String {
        let output = try await gcloudOutput(["auth", "application-default", "print-access-token"])
        guard output.status == 0, !output.text.isEmpty else {
            throw EngineError.noToken(output.error)
        }
        return output.text
    }

    private func gcloudOutput(_ arguments: [String]) async throws
        -> (status: Int32, text: String, error: String) {
        guard let gcloud else { throw EngineError.noCredentials }
        let output = try await Subprocess.run(
            executable: gcloud, arguments: arguments, input: Data(), timeout: 60)
        return (
            output.status,
            String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// One piece of the meeting, inline. Fourteen minutes of the mix is a few
    /// megabytes, well inside what Vertex accepts in a request body, so there
    /// is no bucket to create and nothing left behind in the cloud.
    private func send(_ audio: URL, to endpoint: URL) async throws -> Data {
        let data = try Data(contentsOf: audio)
        var config: [String: Any] = [
            "wordTimestamp": true,
            "diarization": true,
            "mode": "VERBATIM",
        ]
        if !languages.isEmpty { config["languageCodes"] = languages }
        let body = try JSONSerialization.data(withJSONObject: [
            "contents": [[
                "role": "user",
                "parts": [["inlineData": [
                    "mimeType": "audio/m4a",
                    "data": data.base64EncodedString(),
                ]]],
            ]],
            "generationConfig": ["audioTranscriptionConfig": config],
        ])

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Fourteen minutes of audio is transcribed in well under one, but a
        // timeout here costs the whole piece, so leave it generous.
        request.timeoutInterval = 900

        let credential: String
        if let apiKey {
            credential = apiKey
        } else {
            credential = "Bearer \(try await accessToken())"
        }
        do {
            return try await http.send(
                request, body: .data(body), key: credential, what: "transcription",
                retryTransportErrors: false)
        } catch let failure as CloudHTTP.Failure {
            throw Self.reclassified(failure)
        }
    }

    /// The Gemini API answers a key it does not know with 400 rather than
    /// 401, which `CloudHTTP` reads as a request that can never succeed and
    /// the queue as a meeting to give up on. It is still the key, and so the
    /// machine's to fix: the meeting waits for a new one.
    ///
    /// A refusal over thinking waits too, for Google. amanu sends no thinking
    /// config, yet on 2026-10-07 `gemini-3.5-transcribe` answered every
    /// request "Thinking is not enabled for this model" — one with nothing
    /// but the audio in it, and one turning thinking off, included. Nothing
    /// about the request or the recording can change that answer.
    static func reclassified(_ failure: CloudHTTP.Failure) -> any TranscriptionFailure {
        guard case let .rejected(service, what, 400, body) = failure else { return failure }
        if body.contains("API_KEY_INVALID") {
            return CloudHTTP.Failure.unauthorized(service: service, what: what, status: 400, body: body)
        }
        if body.contains("Thinking is not enabled") {
            return EngineError.serviceFault(body)
        }
        return failure
    }

    /// `ru` → `ru-RU`: Vertex wants a region, and the language's likeliest one
    /// is what someone who wrote "ru" in the config means.
    static func bcp47(_ code: String) -> String {
        guard !code.contains("-"),
              let region = Locale.Language(
                identifier: Locale.Language(identifier: code).maximalIdentifier
              ).region?.identifier
        else { return code }
        return "\(code)-\(region)"
    }

    // MARK: - shaping

    /// Where one request's response is cached: named for the model, the way
    /// in, the languages sent, the length that decided the cut, how many
    /// pieces there are, and which piece — or which part of one — it is.
    func cacheURL(in dir: URL, audio: URL, suffix: String?, of count: Int) -> URL {
        ProviderCache.url(
            in: dir, provider: .gemini,
            parts: [
                audio.lastPathComponent, model, apiKey != nil ? "api-key" : "vertex",
                languages.joined(separator: ","), "\(pieceLength)", "\(count)",
            ],
            suffix: suffix)
    }

    /// A pause this long ends a segment even without a change of speaker.
    static let pause: TimeInterval = 1.0
    /// Past this, the next sentence end ends a segment too.
    static let longSegment: TimeInterval = 20

    /// The response as amanu's segments: rebuilt from the words, shifted onto
    /// the session clock, labels kept apart per piece. Pure, so all of it is
    /// testable without a Google account.
    static func segments(
        from response: Response,
        offset: TimeInterval,
        labelPrefix: String?
    ) -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for part in response.candidates?.first?.content?.parts ?? [] {
            guard let transcription = part.audioTranscription else { continue }
            let speaker = transcription.speakerLabel.map { label in
                labelPrefix.map { "\($0)-\(label)" } ?? label
            }
            var words: [(text: String, start: TimeInterval, end: TimeInterval)] = []
            func flush() {
                guard let first = words.first, let last = words.last else { return }
                segments.append(TranscriptSegment(
                    start: first.start + offset,
                    end: max(first.start, last.end) + offset,
                    text: words.map(\.text).joined(separator: " "),
                    speaker: speaker))
                words = []
            }
            for word in transcription.words ?? [] {
                let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = seconds(word.startOffset), end = seconds(word.endOffset)
                if let first = words.first, let last = words.last {
                    let paused = start - last.end >= pause
                    let sentenceDone = last.end - first.start >= longSegment
                        && last.text.last.map { ".?!…".contains($0) } == true
                    if paused || sentenceDone { flush() }
                }
                words.append((text, start, end))
            }
            flush()
        }
        return segments
    }

    /// `"7.300s"`, `"16s"` → seconds.
    private static func seconds(_ offset: String?) -> TimeInterval {
        guard let offset else { return 0 }
        return TimeInterval(offset.hasSuffix("s") ? String(offset.dropLast()) : offset) ?? 0
    }

    /// The slice of the API response amanu uses.
    struct Response: Decodable, Sendable {
        struct Word: Decodable, Sendable {
            let word: String
            let startOffset: String?
            let endOffset: String?
        }

        struct Transcription: Decodable, Sendable {
            let speakerLabel: String?
            let words: [Word]?
        }

        struct Part: Decodable, Sendable {
            let audioTranscription: Transcription?
        }

        struct Content: Decodable, Sendable {
            let parts: [Part]?
        }

        struct Candidate: Decodable, Sendable {
            let content: Content?
            let finishReason: String?
        }

        let candidates: [Candidate]?

        /// Why the model stopped, when it was not because the audio ran out.
        /// A transcript cut short at a token limit reads as complete to
        /// everything downstream, so it is not allowed to become one.
        var unfinishedReason: String? {
            guard let reason = candidates?.first?.finishReason else { return nil }
            return reason == "STOP" ? nil : reason
        }
    }

    /// Progress goes to stderr; only minutes left untranscribed go to the
    /// session's transcribe.log, where the coordinator writes outcomes.
    private static func note(_ message: String) {
        FileHandle.standardError.write(Data("gemini: \(message)\n".utf8))
    }
}
