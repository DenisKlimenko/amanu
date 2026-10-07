import Foundation
import Testing

@testable import amanu

/// The Meet timeline is evidence about *who*, and like every other source of
/// names here it has to be refused when it is ambiguous. These tests are the
/// cases a real call produces: an indicator that lags the voice, a tile that
/// flickers during someone else's sentence, a reply too short for Meet to
/// notice, and a far end the timeline never saw.
struct MeetSpeakersTests {
    private static let origin = 1_790_000_000_000

    private static func seg(_ speaker: String, _ start: Double, _ end: Double) -> Transcript.Segment {
        Transcript.Segment(
            speaker: speaker, start_ms: Int(start * 1000), end_ms: Int(end * 1000), text: speaker)
    }

    private static func turn(_ id: String, _ name: String?, _ start: Double, _ end: Double)
        -> MeetSpeakers.Turn {
        MeetSpeakers.Turn(
            id: id, name: name,
            startMs: origin + Int(start * 1000), endMs: origin + Int(end * 1000))
    }

    private static func events(_ json: String) -> [MeetSpeakers.Event] {
        json.split(separator: "\n").map {
            try! JSONDecoder().decode(MeetSpeakers.Event.self, from: Data($0.utf8))
        }
    }

    @Test("A state lasts until the next one, and never past the heartbeat")
    func turnsFromEvents() {
        let turns = MeetSpeakers.turns(from: Self.events("""
        {"t":1000,"speaking":[{"id":"a","name":"Ann"}]}
        {"t":3000,"speaking":[]}
        {"t":4000,"speaking":[{"id":"b","name":"Bob"}]}
        """))
        #expect(turns == [
            .init(id: "a", name: "Ann", startMs: 1000, endMs: 3000),
            .init(id: "b", name: "Bob", startMs: 4000, endMs: 4000 + MeetSpeakers.stale),
        ])
    }

    @Test("A state lasts until the next of its own call, however often another tab reports")
    func anotherTabDoesNotCutAState() {
        // One connection relays every Meet tab the browser has open, and a tab
        // waiting in its lobby keeps reporting nobody speaking: here between
        // every two reports of the call.
        let turns = MeetSpeakers.turns(from: Self.events("""
        {"t":1000,"meeting":"aaa-bbbb-ccc","speaking":[{"id":"a","name":"Ann"}]}
        {"t":2000,"meeting":"ddd-eeee-fff","speaking":[]}
        {"t":5000,"meeting":"aaa-bbbb-ccc","speaking":[{"id":"a","name":"Ann"}]}
        {"t":6000,"meeting":"ddd-eeee-fff","speaking":[]}
        {"t":9000,"meeting":"aaa-bbbb-ccc","speaking":[{"id":"b","name":"Bob"}]}
        {"t":10000,"meeting":"ddd-eeee-fff","speaking":[]}
        {"t":14000,"meeting":"ddd-eeee-fff","speaking":[]}
        """))
        // Ann's tile is lit from 1000 to 9000, whatever the other tab says in
        // between. Bob's last report is not made longer by the other tab's
        // later ones: it runs out at the heartbeat's limit.
        #expect(turns == [
            .init(id: "a", name: "Ann", startMs: 1000, endMs: 5000),
            .init(id: "a", name: "Ann", startMs: 5000, endMs: 9000),
            .init(id: "b", name: "Bob", startMs: 9000, endMs: 9000 + MeetSpeakers.stale),
        ])
    }

    @Test("A state lasts until the next of its own tab, even when another is on the same call")
    func aSecondTabOnTheSameCallDoesNotCutAState() {
        // The pre-join page of a meeting can stay open beside the joined call,
        // reporting the same meeting code with nobody speaking between every
        // two reports of the call.
        let turns = MeetSpeakers.turns(from: Self.events("""
        {"t":1000,"meeting":"aaa-bbbb-ccc","tab":"call","speaking":[{"id":"a","name":"Ann"}]}
        {"t":2000,"meeting":"aaa-bbbb-ccc","tab":"lobby","speaking":[]}
        {"t":5000,"meeting":"aaa-bbbb-ccc","tab":"call","speaking":[{"id":"a","name":"Ann"}]}
        {"t":6000,"meeting":"aaa-bbbb-ccc","tab":"lobby","speaking":[]}
        {"t":9000,"meeting":"aaa-bbbb-ccc","tab":"call","speaking":[]}
        """))
        #expect(turns == [
            .init(id: "a", name: "Ann", startMs: 1000, endMs: 5000),
            .init(id: "a", name: "Ann", startMs: 5000, endMs: 9000),
        ])
    }

    @Test("Two far-end voices get a letter each and their Meet names; ours are left alone")
    func namesTheFarEnd() throws {
        let segments = [
            Self.seg("me", 0, 5),
            Self.seg("them A", 6, 12),
            Self.seg("them B", 13, 18),
            Self.seg("them A", 19, 22),
        ]
        let turns = [
            Self.turn("d", "Daniel Craig", 6.3, 12.4),
            Self.turn("s", "Samantha Lee", 13.3, 18.5),
            // A stray flicker of Daniel's tile in the middle of Samantha.
            Self.turn("d", "Daniel Craig", 15.0, 15.3),
            Self.turn("d", "Daniel Craig", 19.3, 22.4),
        ]
        let result = try #require(MeetSpeakers.attribute(segments, turns: turns, originMs: Self.origin))
        #expect(result.segments.map(\.speaker) == ["me", "them A", "them B", "them A"])
        #expect(result.names == ["them A": "Daniel Craig", "them B": "Samantha Lee"])
    }

    @Test("Meet's letters replace the engine's, which can split one person in two")
    func mergesWhatDiarizationSplit() throws {
        let segments = [Self.seg("them A", 0, 4), Self.seg("them B", 5, 9)]
        let turns = [Self.turn("d", "Daniel", 0.2, 9.3)]
        let result = try #require(MeetSpeakers.attribute(segments, turns: turns, originMs: Self.origin))
        // One participant and nobody unplaced: plain "them", as a one-voice
        // far end has always been labelled.
        #expect(result.segments.map(\.speaker) == ["them", "them"])
        #expect(result.names == ["them": "Daniel"])
    }

    @Test("A reply too short for the indicator follows its voice")
    func shortReplyFollowsItsVoice() throws {
        let segments = [
            Self.seg("them A", 0, 6),
            Self.seg("them B", 7, 12),
            Self.seg("them A", 13, 13.4),
        ]
        let turns = [Self.turn("d", "Daniel", 0.3, 6.5), Self.turn("s", "Sam", 7.3, 12.5)]
        let result = try #require(MeetSpeakers.attribute(segments, turns: turns, originMs: Self.origin))
        #expect(result.segments.map(\.speaker) == ["them A", "them B", "them A"])
    }

    @Test("Two tiles lit at once settle nothing, and the unplaced stay a plain them")
    func crosstalkIsRefused() throws {
        // Different voices, so the second utterance lends the first nothing.
        let segments = [Self.seg("them A", 0, 4), Self.seg("them B", 5, 9)]
        let turns = [
            Self.turn("d", "Daniel", 0, 4),
            Self.turn("s", "Sam", 0, 4),
            Self.turn("s", "Sam", 5, 9),
        ]
        let result = try #require(MeetSpeakers.attribute(segments, turns: turns, originMs: Self.origin))
        #expect(result.segments.map(\.speaker) == ["them", "them A"])
        #expect(result.names == ["them A": "Sam"])
    }

    @Test("A timeline from another call changes nothing")
    func unrelatedTimeline() {
        let segments = [Self.seg("me", 0, 3), Self.seg("them", 4, 8)]
        let turns = [Self.turn("d", "Daniel", 600, 620)]
        #expect(MeetSpeakers.attribute(segments, turns: turns, originMs: Self.origin) == nil)
        #expect(MeetSpeakers.attribute(segments, turns: [], originMs: Self.origin) == nil)
    }

    @Test("Names land in speakers.json as Meet's, around a name somebody typed")
    func applyWritesSpeakers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-meet-\(UUID().uuidString)", isDirectory: true)
        let session = root.appendingPathComponent("session", isDirectory: true)
        let timeline = root.appendingPathComponent("meet", isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: timeline, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try JSONSerialization.data(withJSONObject: ["origin_ms": Self.origin])
            .write(to: session.appendingPathComponent("meta.json"))
        try SpeakerNames(speakers: [
            "them B": .init(name: "Саша", source: .manual),
        ]).write(to: session)
        try """
        {"t":\(Self.origin + 300),"speaking":[{"id":"d","name":"Daniel"}]}
        {"t":\(Self.origin + 5000),"speaking":[{"id":"s","name":"Sam"}]}
        {"t":\(Self.origin + 9000),"speaking":[]}
        """.write(to: timeline.appendingPathComponent("\(Self.origin).jsonl"),
                  atomically: true, encoding: .utf8)

        let segments = MeetSpeakers.apply(
            to: [Self.seg("them", 0, 4.5), Self.seg("them", 5, 8.5)],
            session: session, timeline: timeline, log: { _ in })

        #expect(segments.map(\.speaker) == ["them A", "them B"])
        let names = try #require(SpeakerNames.read(from: session))
        #expect(names.speakers["them A"]?.name == "Daniel")
        #expect(names.speakers["them A"]?.source == .meet)
        #expect(names.speakers["them B"]?.name == "Саша")
        #expect(names.speakers["them B"]?.source == .manual)
    }

    @Test("A call is in progress while the extension keeps reporting it, in any tab")
    func callsInProgress() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-calls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // One connection relays every Meet tab the browser has, so a single
        // file can hold two calls.
        try """
        {"t":\(Self.origin),"meeting":"aaa-bbbb-ccc","speaking":[]}
        {"t":\(Self.origin + 1000),"meeting":"pgo-onxr-iue","speaking":[{"id":"d","name":"Daniel"}]}
        {"t":\(Self.origin + 20_000),"meeting":"pgo-onxr-iue","speaking":[]}
        """.write(to: dir.appendingPathComponent("\(Self.origin).jsonl"),
                  atomically: true, encoding: .utf8)
        func at(_ ms: Int) -> Date {
            Date(timeIntervalSince1970: Double(Self.origin + ms) / 1000)
        }

        func codes(at ms: Int) -> Set<String> {
            Set(MeetSpeakers.callsInProgress(in: dir, at: at(ms)).map(\.code))
        }
        #expect(codes(at: 3000) == ["aaa-bbbb-ccc", "pgo-onxr-iue"])
        #expect(codes(at: 22_000) == ["pgo-onxr-iue"])
        #expect(codes(at: 20_000 + MeetSpeakers.stale + 1) == [])
    }

    @Test("A call's title is Meet's, read from the tab, and never just its code")
    func callTitles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-titles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
        {"t":\(Self.origin),"meeting":"aaa-bbbb-ccc","title":"Meet - aaa-bbbb-ccc","speaking":[]}
        {"t":\(Self.origin + 1000),"meeting":"pgo-onxr-iue","title":"Meet - Sprint demo","speaking":[]}
        {"t":\(Self.origin + 2000),"meeting":"aaa-bbbb-ccc","title":"Meet - Team sync","speaking":[]}
        """.write(to: dir.appendingPathComponent("\(Self.origin).jsonl"),
                  atomically: true, encoding: .utf8)

        // The most recent report first, and its title for the call.
        #expect(MeetSpeakers.callsInProgress(
            in: dir, at: Date(timeIntervalSince1970: Double(Self.origin + 3000) / 1000)) == [
            .init(code: "aaa-bbbb-ccc", title: "Team sync"),
            .init(code: "pgo-onxr-iue", title: "Sprint demo"),
        ])
        #expect(MeetSpeakers.title(fromTab: "Meet - Office hours", code: "pgo-onxr-iue")
            == "Office hours")
        #expect(MeetSpeakers.title(fromTab: "Meet - pgo-onxr-iue", code: "pgo-onxr-iue") == nil)
        #expect(MeetSpeakers.title(fromTab: "Meet", code: "pgo-onxr-iue") == nil)
        #expect(MeetSpeakers.title(fromTab: "Google Meet", code: "pgo-onxr-iue") == nil)
        #expect(MeetSpeakers.title(fromTab: nil, code: "pgo-onxr-iue") == nil)
    }

    @Test("The host writes each framed message as one line, and skips what isn't JSON")
    func hostFraming() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pipe = Pipe()
        func frame(_ text: String) -> Data {
            var length = UInt32(text.utf8.count).littleEndian
            return Data(bytes: &length, count: 4) + Data(text.utf8)
        }
        pipe.fileHandleForWriting.write(
            frame(#"{"t":1,"speaking":[{"id":"a","name":"Ann\nLee"}]}"#)
                + frame("not json")
                + frame(#"{"t":2,"speaking":[]}"#))
        try pipe.fileHandleForWriting.close()

        try MeetHost.serve(
            input: pipe.fileHandleForReading, directory: dir,
            now: Date(timeIntervalSince1970: 1_790_000_000))

        let file = dir.appendingPathComponent("1790000000000.jsonl")
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        let events = lines.compactMap {
            try? JSONDecoder().decode(MeetSpeakers.Event.self, from: Data($0.utf8))
        }
        #expect(events.map(\.t) == [1, 2])
        #expect(events.first?.speaking.first?.name == "Ann\nLee")
    }

    @Test("A new connection leaves earlier timelines alone, however old")
    func hostKeepsOldTimelines() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-host-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("1690000000000.jsonl")
        try Data(#"{"t":1690000000000,"speaking":[]}"#.utf8).write(to: old)

        let pipe = Pipe()
        try pipe.fileHandleForWriting.close()
        try MeetHost.serve(
            input: pipe.fileHandleForReading, directory: dir,
            now: Date(timeIntervalSince1970: 1_790_000_000))

        #expect(FileManager.default.fileExists(atPath: old.path))
    }
}
