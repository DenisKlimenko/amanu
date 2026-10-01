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

    /// Read as ten in the morning: the tests below are a day's meetings, and
    /// only the minutes between them matter.
    private static let morning = Date(timeIntervalSince1970: 1_790_000_000)

    private static func time(_ minutes: Double) -> Date {
        morning.addingTimeInterval(minutes * 60)
    }

    private static func event(
        _ title: String, at start: Double = 0, minutes: Double = 30,
        meet: Set<String> = [], call: Bool = true, declined: Bool = false
    ) -> CalendarWatcher.Meeting {
        var event = CalendarWatcher.Meeting(
            id: title, title: title, start: time(start), end: time(start + minutes),
            attendees: call ? ["Denis", "Anna"] : [], link: nil, looksLikeCall: call,
            meetCodes: meet)
        event.declined = declined
        return event
    }

    private static func pick(
        _ events: [CalendarWatcher.Meeting], at minutes: Double, meet codes: Set<String> = []
    ) -> CalendarWatcher.Meeting? {
        match(events, at: minutes, meet: codes.map { MeetSpeakers.Call(code: $0, title: nil) })?.event
    }

    private static func match(
        _ events: [CalendarWatcher.Meeting], at minutes: Double, meet calls: [MeetSpeakers.Call]
    ) -> CalendarWatcher.Match? {
        CalendarWatcher.pick(from: events, duringMeet: calls, at: time(minutes))
    }

    /// An out-of-office block covers the working day and has nobody else in
    /// it. It named four recordings in two days; it should have named none.
    @Test("A block with nobody else in it names nothing, however much of the day it covers")
    func soloBlockNamesNothing() {
        let away = Self.event("Out of office", at: -60, minutes: 8 * 60, call: false)
        // Two minutes into the block, which is inside the window, so that
        // nothing but there being nobody else in it can keep it from naming
        // this recording. A recording made later is refused by the window
        // alone, and the test could not tell the two reasons apart.
        #expect(Self.pick([away], at: -58) == nil)
    }

    @Test("A meeting the user declined is never chosen by its time")
    func declinedIsNotGuessed() {
        #expect(Self.pick([Self.event("Sprint demo", declined: true)], at: 1) == nil)
    }

    /// Granola's fifteen minutes after the start, and five before it for
    /// opening the call early.
    @Test("Five minutes early and fifteen late are inside the window, six and sixteen are not")
    func theWindowsEdges() {
        let demo = Self.event("Sprint demo", minutes: 60)
        #expect(Self.pick([demo], at: -5)?.title == "Sprint demo")
        #expect(Self.pick([demo], at: 15)?.title == "Sprint demo")
        #expect(Self.pick([demo], at: -6) == nil)
        #expect(Self.pick([demo], at: 16) == nil)
    }

    @Test("A meeting that has ended is never chosen by its time")
    func endedIsNotGuessed() {
        #expect(Self.pick([Self.event("Stand-up", minutes: 10)], at: 12) == nil)
    }

    /// Sorting by start and taking the first handed a recording to whatever
    /// began earliest, which is the long block.
    @Test("The nearest start wins, not the earliest")
    func nearestStartWins() {
        let picked = Self.pick(
            [Self.event("Planning", at: -10, minutes: 60), Self.event("Sprint demo", at: 2)], at: 1)
        #expect(picked?.title == "Sprint demo")
        #expect(picked?.matchedBy == .time)
    }

    @Test("In a Meet call, the event that links to that call wins, whichever comes first")
    func meetCallPicksItsOwnEvent() {
        let picked = Self.pick(
            [Self.event("Team sync", meet: ["aaa-bbbb-ccc"]),
             Self.event("Interview", meet: ["pgo-onxr-iue"])],
            at: 1, meet: ["pgo-onxr-iue"])
        #expect(picked?.title == "Interview")
        #expect(picked?.matchedBy == .meet)
    }

    /// A meeting that runs over is still that meeting.
    @Test("A Meet call finds its event after the event's end")
    func meetCodeOutlastsTheSlot() {
        let picked = Self.pick(
            [Self.event("Sprint demo", minutes: 30, meet: ["pgo-onxr-iue"])],
            at: 40, meet: ["pgo-onxr-iue"])
        #expect(picked?.matchedBy == .meet)
    }

    /// A weekly one-to-one's room, used midweek for a call agreed in chat, is
    /// still the one-to-one.
    @Test("A Meet call finds its room's event days away when none around the start links to it")
    func meetCodeFindsTheRoomsMeeting() {
        let picked = Self.pick(
            [Self.event("One-to-one", at: -2 * 24 * 60, meet: ["abc-defg-hij"])],
            at: 0, meet: ["abc-defg-hij"])
        #expect(picked?.title == "One-to-one")
        #expect(picked?.matchedBy == .meet)
    }

    /// The nearest start alone would hand an all-day workshop's call to the
    /// next meeting booked into the same room.
    @Test("An event around the start beats one in the same room on another day")
    func theCallsOwnSlotBeatsTheRoom() {
        let picked = Self.pick(
            [Self.event("Workshop", at: -6 * 60, minutes: 8 * 60, meet: ["abc-defg-hij"]),
             Self.event("Retro", at: 2 * 60, meet: ["abc-defg-hij"])],
            at: 0, meet: ["abc-defg-hij"])
        #expect(picked?.title == "Workshop")
    }

    /// The call is proof, so the rules for a guess do not apply to it.
    @Test("A declined meeting still names the Meet call that links to it")
    func declinedButJoined() {
        let picked = Self.pick(
            [Self.event("Sprint demo", meet: ["pgo-onxr-iue"], declined: true)],
            at: 1, meet: ["pgo-onxr-iue"])
        #expect(picked?.matchedBy == .meet)
    }

    /// A Meet call nobody put in a calendar still overlaps other people's
    /// meetings. One that links to a different call is certainly not this one.
    @Test("An event linking to another Meet call is never the one being recorded")
    func otherMeetCallIsNotThisOne() {
        let colleagues = Self.event("Colleague's 1:1", meet: ["aaa-bbbb-ccc"])
        #expect(Self.pick([colleagues], at: 1, meet: ["pgo-onxr-iue"]) == nil)
        let picked = Self.pick([colleagues, Self.event("Interview")], at: 1, meet: ["pgo-onxr-iue"])
        #expect(picked?.title == "Interview")
        #expect(picked?.matchedBy == .time)
    }

    @Test("Without a Meet call to go by, an event with a Meet link is chosen by its time")
    func meetLinkWithoutTheExtension() {
        #expect(Self.pick([Self.event("Sync", meet: ["aaa-bbbb-ccc"])], at: 1)?.title == "Sync")
    }

    @Test("Only a meeting starts a recording from the calendar")
    func onlyMeetingsStartRecordings() {
        let started = CalendarWatcher.justStarted(
            [Self.event("Sprint demo"), Self.event("Focus time", call: false),
             Self.event("Planning", declined: true)],
            now: Self.time(0.5), window: 120)
        #expect(started.map(\.title) == ["Sprint demo"])
    }

    /// The recordings of 30 September and 1 October 2026 this rule was written
    /// against, with the titles changed: six of the seven were named after
    /// something that was not a meeting.
    @Test("The seven recordings get the names the spec gives them")
    func sevenRecordings() {
        let thirtieth = [
            Self.event("Out of office", at: -2 * 60, minutes: 9 * 60 + 20, call: false),
            Self.event("Sprint demo", at: 6 * 60, minutes: 60, meet: ["pgo-onxr-iue"]),
        ]
        let first = [
            Self.event("Focus time", at: 60, minutes: 60, call: false),
            Self.event("Focus time", at: 4 * 60, minutes: 60, call: false),
        ]
        func name(
            _ day: [CalendarWatcher.Meeting], at minutes: Double,
            app: String? = nil, meet calls: [MeetSpeakers.Call] = []
        ) -> String? {
            MeetingContext(match: Self.match(day, at: minutes, meet: calls), app: app).folderSuffix
        }
        // Inside the out-of-office block, and a minute after it ended.
        #expect(name(thirtieth, at: -10) == nil)
        #expect(name(thirtieth, at: 4 * 60 + 2, app: "FaceTime") == "FaceTime")
        #expect(name(thirtieth, at: 5 * 60 + 26) == nil)
        #expect(name(thirtieth, at: 7 * 60 + 21, app: "FaceTime") == "FaceTime")
        // The one that was named right, by its Meet call.
        #expect(name(thirtieth, at: 6 * 60 + 2, app: "Dia",
                     meet: [.init(code: "pgo-onxr-iue", title: "Sprint demo")])
            == "Sprint demo (Dia)")
        // Meet calls no event links to: one whose tab showed only its code,
        // inside a focus block, and one whose tab showed its title, eight
        // minutes before another.
        #expect(name(first, at: 63, app: "Dia", meet: [.init(code: "aaa-bbbb-ccc", title: nil)])
            == "Dia")
        #expect(name(first, at: 3 * 60 + 52, app: "Dia",
                     meet: [.init(code: "ddd-eeee-fff", title: "Office hours")])
            == "Office hours (Dia)")
    }

    /// Google appears not to hand declined events to the Mac at all, so a
    /// declined meeting joined after all has no event to be found by.
    @Test("A Meet call no event links to takes the title Meet shows for it")
    func meetTitleNamesWhatTheCalendarLacks() {
        let match = Self.match(
            [], at: 0, meet: [.init(code: "abc-defg-hij", title: "Office hours")])
        guard case .meetTitle(let title)? = match else {
            Issue.record("Meet's title was not used")
            return
        }
        #expect(title == "Office hours")
    }

    @Test("Meet's title beats an event that time alone would choose")
    func meetTitleBeatsTime() {
        let match = Self.match(
            [Self.event("Sprint demo")], at: 1,
            meet: [.init(code: "abc-defg-hij", title: "Office hours")])
        guard case .meetTitle? = match else {
            Issue.record("a guess from the time beat what Meet says")
            return
        }
    }

    @Test("The event a Meet call links to beats Meet's own title for it")
    func linkedEventBeatsMeetTitle() {
        let match = Self.match(
            [Self.event("Sprint demo", meet: ["pgo-onxr-iue"])], at: 1,
            meet: [.init(code: "pgo-onxr-iue", title: "Sprint demo, renamed")])
        #expect(match?.event?.title == "Sprint demo")
        #expect(match?.event?.matchedBy == .meet)
    }

    @Test("A Meet call whose tab shows only its code leaves the choice to time")
    func codeOnlyTitleLeavesTime() {
        let match = Self.match(
            [Self.event("Sprint demo")], at: 1, meet: [.init(code: "abc-defg-hij", title: nil)])
        #expect(match?.event?.title == "Sprint demo")
    }

    @Test("A title from Meet names the folder, and meta.json says where it came from")
    func meetTitleInFolderAndMeta() throws {
        let context = MeetingContext(match: .meetTitle("Office hours"), app: "Dia")
        #expect(context.folderSuffix == "Office hours (Dia)")
        let calendar = try #require(context.metaFields["calendar"] as? [String: Any])
        #expect(calendar["title"] as? String == "Office hours")
        #expect(calendar["title_from"] as? String == "meet")
        #expect(calendar["matched_by"] == nil)
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
