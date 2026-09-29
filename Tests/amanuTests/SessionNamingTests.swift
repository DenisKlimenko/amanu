import Foundation
import Testing

@testable import amanu

/// Folder names are the index of the whole archive: three weeks later the
/// question is never "what happened at 20:39", it's "where's that call with
/// the client". These tests pin down what ends up in the name.
@MainActor
struct SessionNamingTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("amanu-naming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The timestamp prefix is load-bearing, not decoration: the transcription
    /// queue orders pending sessions by folder name and expects that to be
    /// chronological.
    private func timestamp(_ name: String) -> String {
        String(name.prefix(15))
    }

    @Test("Title and app both land in the folder name")
    func titleAndApp() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try RecordingSession(
            root: root,
            context: MeetingContext(title: "Integration sync", app: "zoom.us"))
        #expect(session.dir.lastPathComponent.hasSuffix("Integration sync (zoom.us)"))
        #expect(timestamp(session.dir.lastPathComponent).contains("."))
    }

    @Test("With no calendar entry, the app alone names the folder")
    func appOnly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try RecordingSession(root: root, context: MeetingContext(app: "Telegram"))
        #expect(session.dir.lastPathComponent.hasSuffix(" Telegram"))
    }

    @Test("Knowing nothing still gives a valid, timestamped folder")
    func nothingKnown() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try RecordingSession(root: root)
        #expect(session.dir.lastPathComponent.count == 15, "expected a bare timestamp")
        #expect(FileManager.default.fileExists(atPath: session.dir.path))
    }

    /// Slashes would silently create nested directories and colons show up as
    /// slashes in Finder — a meeting called "Q3: plans / budget" must not
    /// scatter the recording across three folders.
    @Test("Path separators in a meeting title can't escape the folder")
    func titleCannotEscape() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try RecordingSession(
            root: root,
            context: MeetingContext(title: "Q3: plans / budget\nsecond line", app: "Google Chrome"))
        let name = session.dir.lastPathComponent
        #expect(!name.contains("/") && !name.contains(":") && !name.contains("\n"))
        #expect(session.dir.deletingLastPathComponent().lastPathComponent
            == root.lastPathComponent, "the session must be a direct child of the root")
        #expect(name.contains("Q3 plans budget"))
    }

    @Test("A very long title is cut rather than left unreadable")
    func longTitleIsTrimmed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let session = try RecordingSession(
            root: root,
            context: MeetingContext(title: String(repeating: "very long meeting ", count: 20),
                                    app: "zoom.us"))
        // Timestamp + 60 chars of title + " (zoom.us)", give or take a space.
        #expect(session.dir.lastPathComponent.count < 100)
        #expect(session.dir.lastPathComponent.hasSuffix("(zoom.us)"))
    }

    @Test("Two meetings in the same minute get separate folders")
    func collisionsAreSuffixed() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let context = MeetingContext(title: "Standup", app: "zoom.us")
        let first = try RecordingSession(root: root, context: context)
        let second = try RecordingSession(root: root, context: context)
        #expect(first.dir != second.dir)
        #expect(second.dir.lastPathComponent.hasSuffix("-2"))
    }

    @Test("meta.json carries the attendees and the link, not just the name")
    func metaCarriesTheDetails() throws {
        let context = MeetingContext(
            title: "Integration sync",
            app: "zoom.us",
            attendees: ["Anna", "Boris"],
            link: "https://zoom.us/j/123")
        let fields = context.metaFields

        #expect(fields["app"] as? String == "zoom.us")
        let calendar = try #require(fields["calendar"] as? [String: Any])
        #expect(calendar["attendees"] as? [String] == ["Anna", "Boris"])
        #expect(calendar["link"] as? String == "https://zoom.us/j/123")
        #expect(calendar["title"] as? String == "Integration sync")
    }

    @Test("meta.json says which calendar the event came from, and how it was picked")
    func metaCarriesTheEventsCalendar() throws {
        var event = Self.event("Interview", meet: ["pgo-onxr-iue"])
        event.calendarName = "Personal"
        event.account = "iCloud"
        event.matchedBy = .meet
        let fields = MeetingContext(meeting: event, app: "Dia").metaFields

        let calendar = try #require(fields["calendar"] as? [String: Any])
        #expect(calendar["calendar_name"] as? String == "Personal")
        #expect(calendar["account"] as? String == "iCloud")
        #expect(calendar["matched_by"] as? String == "meet")
    }

    // MARK: - which event a recording belongs to

    private static func event(
        _ title: String, meet: Set<String> = [], call: Bool = true
    ) -> CalendarWatcher.Meeting {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        return CalendarWatcher.Meeting(
            id: title, title: title, start: start, end: start.addingTimeInterval(1800),
            attendees: call ? ["Denis", "Anna"] : [], link: nil, looksLikeCall: call,
            meetCodes: meet)
    }

    @Test("In a Meet call, the event that links to that call wins, whichever comes first")
    func meetCallPicksItsOwnEvent() throws {
        let picked = try #require(CalendarWatcher.pick(
            from: [
                Self.event("Team sync", meet: ["aaa-bbbb-ccc"]),
                Self.event("Interview", meet: ["pgo-onxr-iue"]),
            ],
            duringMeet: ["pgo-onxr-iue"]))
        #expect(picked.title == "Interview")
        #expect(picked.matchedBy == .meet)
    }

    /// A Meet call nobody put in a calendar still overlaps other people's
    /// meetings. One that links to a different call is certainly not this one.
    @Test("An event linking to another Meet call is never the one being recorded")
    func otherMeetCallIsNotThisOne() throws {
        let picked = try #require(CalendarWatcher.pick(
            from: [
                Self.event("Colleague's 1:1", meet: ["aaa-bbbb-ccc"]),
                Self.event("Interview"),
            ],
            duringMeet: ["pgo-onxr-iue"]))
        #expect(picked.title == "Interview")
        #expect(picked.matchedBy == .time)

        #expect(CalendarWatcher.pick(
            from: [Self.event("Colleague's 1:1", meet: ["aaa-bbbb-ccc"])],
            duringMeet: ["pgo-onxr-iue"]) == nil)
    }

    @Test("Without a Meet call to go by, a call still beats a solo block")
    func noMeetCallKeepsTheCalendarsChoice() throws {
        let picked = try #require(CalendarWatcher.pick(
            from: [Self.event("Focus", call: false), Self.event("Sync", meet: ["aaa-bbbb-ccc"])],
            duringMeet: []))
        #expect(picked.title == "Sync")
        #expect(picked.matchedBy == .time)
    }

    @Test("A Meet code is read out of Google's invitation text or a bare link")
    func meetCodesFromEventText() {
        let invitation = """
        -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
        Join with Google Meet: https://meet.google.com/pgo-onxr-iue
        Or dial: (US) +1 402-555-0133 PIN: 123456789#
        Learn more about Meet at: https://support.google.com/a/users/answer/9282720
        """
        #expect(CalendarWatcher.meetCodes(in: invitation) == ["pgo-onxr-iue"])
        #expect(CalendarWatcher.meetCodes(in: "https://meet.google.com/ABC-defg-hij?authuser=1")
            == ["abc-defg-hij"])
        #expect(CalendarWatcher.meetCodes(in: "https://zoom.us/j/123, room 4") == [])
    }
}
