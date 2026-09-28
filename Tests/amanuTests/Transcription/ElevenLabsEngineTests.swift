import Foundation
import Testing

@testable import amanu

struct ElevenLabsEngineTests {
    @Test("Each channel is sent as mono so Scribe can diarize within it")
    func requestDiarizesEveryChannel() {
        let fields = Dictionary(uniqueKeysWithValues: ElevenLabsEngine.requestFields())
        #expect(fields["model_id"] == "scribe_v2")
        #expect(fields["diarize"] == "true")
        #expect(fields["use_multi_channel"] == nil)
    }

    @Test("Two voices on the far channel stay distinct from the microphone")
    func channelSpeakersStayDistinct() throws {
        let mic = try JSONDecoder().decode(ElevenLabsEngine.Response.self, from: Data("""
        {"text":"Hi there.","words":[
          {"start":0.1,"end":0.3,"text":"Hi","type":"word","speaker_id":"speaker_0"},
          {"start":0.3,"end":0.3,"text":" ","type":"spacing","speaker_id":"speaker_0"},
          {"start":0.3,"end":0.7,"text":"there.","type":"word","speaker_id":"speaker_0"}
        ]}
        """.utf8))
        let system = try JSONDecoder().decode(ElevenLabsEngine.Response.self, from: Data("""
        {"text":"Hello! Yes.","words":[
          {"start":0.4,"end":0.8,"text":"Hello!","type":"word","speaker_id":"speaker_0"},
          {"start":0.9,"end":1.2,"text":"Yes.","type":"word","speaker_id":"speaker_1"}
        ]}
        """.utf8))

        let turns = ElevenLabsEngine.segments(from: mic, duration: 2, channel: 0)
            + ElevenLabsEngine.segments(from: system, duration: 2, channel: 1)
        #expect(turns.map(\.text) == ["Hi there.", "Hello!", "Yes."])
        #expect(turns.map(\.speaker) == ["1A", "2A", "2B"])
        #expect(MultichannelSpeakerLabels.map(turns).map(\.speaker)
            == ["me A", "them A", "them B"])
    }

    @Test("Mono diarization keeps distinct speakers and clips impossible timestamps")
    func monoSpeakersAndBounds() throws {
        let response = try JSONDecoder().decode(ElevenLabsEngine.Response.self, from: Data("""
        {"text":"Hi. Hello.","words":[
          {"start":0,"end":0.4,"text":"Hi.","type":"word","speaker_id":"speaker_0"},
          {"start":0.5,"end":1.5,"text":"Hello.","type":"word","speaker_id":"speaker_1"},
          {"start":5,"end":6,"text":"phantom","type":"word","speaker_id":"speaker_1"}
        ]}
        """.utf8))

        let turns = ElevenLabsEngine.segments(from: response, duration: 1, channel: nil)
        #expect(turns.map(\.text) == ["Hi.", "Hello."])
        #expect(turns.map(\.speaker) == ["A", "B"])
        #expect(turns.map(\.end) == [0.4, 1])
    }

    /// The canonical transcript says who spoke when. A speaker's turn used to
    /// run straight through somebody else's interjection, as if they had
    /// never been interrupted.
    @Test("A turn ends where another voice begins, and the Markdown joins it up again")
    func turnsDoNotCrossAnotherVoice() throws {
        let response = try JSONDecoder().decode(ElevenLabsEngine.Response.self, from: Data("""
        {"text":"","words":[
          {"start":0.0,"end":0.5,"text":"First","type":"word","speaker_id":"speaker_0"},
          {"start":0.5,"end":0.5,"text":" ","type":"spacing","speaker_id":"speaker_0"},
          {"start":0.5,"end":0.9,"text":"half","type":"word","speaker_id":"speaker_0"},
          {"start":1.0,"end":1.3,"text":"Right.","type":"word","speaker_id":"speaker_1"},
          {"start":1.4,"end":2.0,"text":"second half.","type":"word","speaker_id":"speaker_0"}
        ]}
        """.utf8))

        let turns = ElevenLabsEngine.segments(from: response, duration: 3, channel: 1)
        #expect(turns.map(\.text) == ["First half", "Right.", "second half."])
        #expect(turns.map(\.speaker) == ["2A", "2B", "2A"])

        let transcript = Transcript(
            engine: "elevenlabs", model: "scribe_v2", created_at: "2026-09-28T00:00:00Z",
            segments: MultichannelSpeakerLabels.map(turns))
        let markdown = transcript.rendered(title: "t", names: nil)
        #expect(markdown.contains("them A:** First half second half."))
        #expect(markdown.contains("them B:** Right."))
    }

    @Test("A speaker id Scribe has no number for keeps a single space after the side")
    func unknownSpeakerIdIsNotDoubleSpaced() throws {
        let response = try JSONDecoder().decode(ElevenLabsEngine.Response.self, from: Data("""
        {"text":"","words":[
          {"start":0,"end":0.4,"text":"Hello.","type":"word","speaker_id":"guest"}
        ]}
        """.utf8))

        let mapped = MultichannelSpeakerLabels.map(
            ElevenLabsEngine.segments(from: response, duration: 1, channel: 0))
        #expect(mapped.map(\.speaker) == ["me guest"])
    }

    @Test("A mono import with no word timings has no invented speaker")
    func monoFlatTextHasNoSpeaker() throws {
        let response = try JSONDecoder().decode(ElevenLabsEngine.Response.self, from: Data("""
        {"text":"Just text.","words":[]}
        """.utf8))
        let turns = ElevenLabsEngine.segments(from: response, duration: 5, channel: nil)
        #expect(turns.map(\.speaker) == [nil])
    }

    @Test("Speech is retained when Scribe returns text without word timings")
    func flatTextFallback() throws {
        let response = try JSONDecoder().decode(ElevenLabsEngine.Response.self, from: Data("""
        {"text":"Hello from the far side.","words":[]}
        """.utf8))

        let turns = ElevenLabsEngine.segments(from: response, duration: 5, channel: 1)
        #expect(turns.count == 1)
        #expect(turns.first?.text == "Hello from the far side.")
        #expect(turns.first?.speaker == "2")
        #expect(turns.first?.start == 0)
        #expect(turns.first?.end == 5)
    }

    @Test("A silent response cannot be retried for a different answer")
    func silenceIsPermanent() {
        #expect(ElevenLabsEngine.EngineError.empty.isPermanent)
    }

    @Test("Each channel has a separate response cache")
    func channelCachesAreDistinct() async throws {
        let engine = try ElevenLabsEngine(apiKey: "test-key")
        let folder = URL(fileURLWithPath: "/tmp/meeting")
        let multichannel = folder.appendingPathComponent("multichannel.m4a")
        let names = [
            await engine.cacheURL(for: multichannel, channel: 0),
            await engine.cacheURL(for: multichannel, channel: 1),
            await engine.cacheURL(for: multichannel, channel: nil),
            await engine.cacheURL(for: folder.appendingPathComponent("mixed.m4a"), channel: nil),
        ]
        #expect(Set(names).count == names.count, "two requests would share a cache: \(names)")
    }

    @Test("The upload is multipart audio with Scribe's fields")
    func uploadBodyContainsAudioAndFields() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-multipart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("meeting.m4a")
        let body = dir.appendingPathComponent("request.multipart")
        try Data([0, 1, 2, 255]).write(to: audio)

        try CloudHTTP.writeMultipart(
            fields: ElevenLabsEngine.requestFields(),
            file: audio, boundary: "test-boundary", to: body)

        let contents = try Data(contentsOf: body)
        let suffix = Data("\r\n--test-boundary--\r\n".utf8)
        let prefix = try #require(String(
            data: contents.prefix(contents.count - 4 - suffix.count), encoding: .utf8))
        #expect(prefix.contains("name=\"model_id\"\r\n\r\nscribe_v2\r\n"))
        #expect(prefix.contains("name=\"diarize\"\r\n\r\ntrue\r\n"))
        #expect(prefix.contains("name=\"file\"; filename=\"meeting.m4a\""))
        #expect(contents.suffix(suffix.count) == suffix)
        #expect(contents.range(of: Data([0, 1, 2, 255])) != nil)
    }

    @Test("Imported WAV audio keeps its own MIME type")
    func wavUploadHasWavType() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-wav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("import.wav")
        let body = dir.appendingPathComponent("request.multipart")
        try Data([0, 1]).write(to: audio)

        try CloudHTTP.writeMultipart(
            fields: ElevenLabsEngine.requestFields(),
            file: audio, boundary: "test-boundary", to: body)

        let contents = try String(decoding: Data(contentsOf: body), as: UTF8.self)
        #expect(contents.contains("filename=\"import.wav\"\r\nContent-Type: audio/wav\r\n"))
    }
}
