import AVFoundation
import Foundation

/// Scribe v2 over the session's aligned stereo archive. Each channel is
/// extracted and transcribed with diarization, so several people sharing the
/// far channel stay separate. A mono import is sent as-is.
actor ElevenLabsEngine: TranscriptionEngine {
    enum EngineError: TranscriptionFailure, CustomStringConvertible {
        case noAPIKey
        case empty

        var isPermanent: Bool {
            if case .empty = self { return true }
            return false
        }

        var isEnvironmental: Bool {
            if case .noAPIKey = self { return true }
            return false
        }

        var description: String {
            switch self {
            case .noAPIKey:
                return "no ElevenLabs API key — put one in \(Config.elevenLabsKeyPath.path)"
                    + " (chmod 600), set ELEVENLABS_API_KEY, or configure"
                    + " transcription.elevenlabs.api_key_path"
            case .empty:
                return "elevenlabs returned no speech"
            }
        }
    }

    private static let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!

    nonisolated let name = "elevenlabs"
    nonisolated let model = "scribe_v2"
    nonisolated let input: TranscriptionInput = .multichannel

    private let apiKey: String
    private let http: CloudHTTP

    init(
        apiKey: String? = nil,
        session: URLSession = .shared,
        retry: CloudHTTP.RetryPolicy = .standard,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        guard let key = apiKey ?? Config.elevenLabsKey() else { throw EngineError.noAPIKey }
        self.apiKey = key
        http = CloudHTTP(service: .elevenLabs, session: session, retry: retry, sleep: sleep)
    }

    func prepare() async throws {}
    func release() async {}

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        let duration = try await AVURLAsset(url: audio).load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: audio.path])
        }
        let channels = Int((try AVAudioFile(forReading: audio)).processingFormat.channelCount)

        var all: [TranscriptSegment] = []
        for index in 0..<channels {
            let channel: Int? = channels > 1 ? index : nil
            let cache = ProviderCache.url(
                in: audio.deletingLastPathComponent(), provider: .elevenLabs,
                parts: [audio.lastPathComponent, model]
                    + Self.requestFields().map { "\($0.0)=\($0.1)" },
                suffix: channel.map { "channel\($0 + 1)" })
            let response: Response
            if let cached = try? Data(contentsOf: cache),
               let decoded = try? JSONDecoder().decode(Response.self, from: cached) {
                response = decoded
            } else {
                let upload: URL
                if let channel {
                    upload = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "amanu-elevenlabs-\(UUID().uuidString)-channel\(channel + 1).m4a")
                    do {
                        try await Task.detached(priority: .utility) {
                            try AudioChannelExtractor.extract(
                                channel: channel, from: audio, to: upload)
                        }.value
                    } catch {
                        try? FileManager.default.removeItem(at: upload)
                        throw error
                    }
                } else {
                    upload = audio
                }
                defer {
                    if channel != nil { try? FileManager.default.removeItem(at: upload) }
                }
                let data = try await http.sendMultipart(
                    to: Self.endpoint, fields: Self.requestFields(), file: upload,
                    key: apiKey, what: "transcription", timeout: 1800)
                response = try http.decode(Response.self, from: data, what: "transcription")
                try? data.write(to: cache, options: .atomic)
            }
            all += Self.segments(from: response, duration: duration, channel: channel)
        }
        guard !all.isEmpty else { throw EngineError.empty }
        return all.sorted { $0.start < $1.start }
    }

    static func requestFields() -> [(String, String)] {
        [
            ("model_id", "scribe_v2"),
            ("timestamps_granularity", "word"),
            ("tag_audio_events", "false"),
            ("diarize", "true"),
        ]
    }

    struct Response: Decodable, Sendable {
        struct Word: Decodable, Sendable {
            let start: TimeInterval
            let end: TimeInterval
            let text: String
            let type: String
            let speaker_id: String?
        }

        let text: String?
        let words: [Word]
    }

    /// Assemble word timestamps into short turns. Prefix speaker labels from
    /// stereo tracks with their one-based channel number for the coordinator.
    static func segments(
        from response: Response, duration: TimeInterval, channel: Int?
    ) -> [TranscriptSegment] {
        struct Turn {
            var start: TimeInterval
            var end: TimeInterval
            var text: String
            let speaker: String
        }

        guard duration.isFinite, duration > 0 else { return [] }
        var active: [String: Turn] = [:]
        var completed: [Turn] = []
        var lastSpeaker: String?
        for word in response.words {
            guard word.start.isFinite, word.end.isFinite else { continue }
            let rawSpeaker = word.speaker_id ?? lastSpeaker ?? "speaker"
            let speaker = channel.map {
                String($0 + 1) + speakerSuffix(rawSpeaker)
            } ?? rawSpeaker
            if word.type == "spacing" {
                if var turn = active[speaker] {
                    turn.text += word.text
                    active[speaker] = turn
                }
                continue
            }
            guard word.type == "word" else { continue }
            let start = max(0, word.start)
            let end = min(duration, word.end)
            guard start < duration, end > start else { continue }
            lastSpeaker = rawSpeaker
            if var turn = active[speaker], start - turn.end <= 1.5 {
                turn.text += word.text
                turn.end = max(turn.end, end)
                active[speaker] = turn
            } else {
                if let previous = active.removeValue(forKey: speaker) {
                    completed.append(previous)
                }
                active[speaker] = Turn(start: start, end: end, text: word.text, speaker: speaker)
            }
        }
        completed += active.values
        let segments: [TranscriptSegment] = completed.sorted { $0.start < $1.start }.compactMap { turn in
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                start: turn.start, end: turn.end, text: text, speaker: turn.speaker)
        }
        if !segments.isEmpty { return segments }
        let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [TranscriptSegment(
            start: 0, end: duration, text: text,
            speaker: channel.map { String($0 + 1) } ?? "speaker")]
    }

    private static func speakerSuffix(_ speaker: String) -> String {
        guard speaker.hasPrefix("speaker_"),
              let index = Int(speaker.dropFirst("speaker_".count)),
              (0..<32).contains(index)
        else { return speaker == "speaker" ? "" : " \(speaker)" }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return index < 26 ? String(letters[index]) : "A\(letters[index - 26])"
    }
}
