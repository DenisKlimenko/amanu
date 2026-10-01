import AppKit
import Foundation
import Testing

@testable import amanu

/// Which calendars a recording may be named after by its time: the
/// `calendars` setting, read, applied and shown.
@MainActor
struct MeetingCalendarsTests {
    private static let start = Date(timeIntervalSince1970: 1_790_000_000)

    private static func demo(chosen: Bool, meet: Set<String> = []) -> CalendarWatcher.Meeting {
        var event = CalendarWatcher.Meeting(
            id: "demo", title: "Sprint demo", start: start, end: start.addingTimeInterval(1800),
            attendees: ["Denis", "Anna"], link: nil, looksLikeCall: true, meetCodes: meet)
        event.chosen = chosen
        return event
    }

    @Test("A calendar is written as its account and its name, and compared whole")
    func keys() {
        #expect(MeetingCalendars.key(account: "Work", calendar: "me@example.com")
            == "Work/me@example.com")
        // A slash inside a name is never mistaken for the one between them.
        #expect(MeetingCalendars.counts("Work/Team/Berlin", chosen: ["Work/Team/Berlin"]))
        #expect(!MeetingCalendars.counts("Work/Team", chosen: ["Work/Team/Berlin"]))
    }

    @Test("Absent, every calendar counts; listed, only those; empty, none")
    func whatCounts() {
        #expect(MeetingCalendars.counts("Work/Colleague", chosen: nil))
        #expect(MeetingCalendars.counts("Work/me@example.com", chosen: ["Work/me@example.com"]))
        #expect(!MeetingCalendars.counts("Work/Colleague", chosen: ["Work/me@example.com"]))
        #expect(!MeetingCalendars.counts("Work/me@example.com", chosen: []))
    }

    @Test("No setting is no list", .freshHome)
    func absentIsNil() {
        #expect(Config.meetingCalendars() == nil)
    }

    @Test("A list is read as written", .freshHome(config: #"{"calendars": ["Work/me@example.com"]}"#))
    func listIsRead() {
        #expect(Config.meetingCalendars() == ["Work/me@example.com"])
    }

    @Test("An empty list is a list", .freshHome(config: #"{"calendars": []}"#))
    func emptyIsRead() {
        #expect(Config.meetingCalendars() == [])
    }

    @Test("A calendar nobody ticked neither names a recording by its time nor starts one")
    func unchosenIsNotGuessed() {
        let unticked = Self.demo(chosen: false)
        #expect(CalendarWatcher.pick(from: [unticked], duringMeet: [], at: Self.start) == nil)
        #expect(CalendarWatcher.justStarted([unticked], now: Self.start, window: 60).isEmpty)
        #expect(CalendarWatcher.pick(from: [Self.demo(chosen: true)], duringMeet: [], at: Self.start) != nil)
    }

    @Test("A Meet call still finds its event in a calendar nobody ticked")
    func meetLooksPastTheChoice() {
        let picked = CalendarWatcher.pick(
            from: [Self.demo(chosen: false, meet: ["pgo-onxr-iue"])],
            duringMeet: ["pgo-onxr-iue"], at: Self.start)
        #expect(picked?.matchedBy == .meet)
    }

    @Test("Every box is ticked while the setting is absent, and only the listed ones after")
    func checklistShowsTheSetting() {
        _ = NSApplication.shared
        let list = CalendarChecklist(listing: {
            [MeetingCalendars.Account(name: "Work", calendars: ["Team", "me@example.com"])]
        })
        list.show(nil)
        #expect(list.ticked == ["Work/Team", "Work/me@example.com"])
        list.show(["Work/me@example.com"])
        #expect(list.ticked == ["Work/me@example.com"])
        list.show([])
        #expect(list.ticked.isEmpty)
    }

    @Test("Without calendars to show, the checklist says where access is given")
    func checklistWithoutAccess() {
        _ = NSApplication.shared
        let list = CalendarChecklist(listing: { nil })
        list.show(nil)
        #expect(list.ticked.isEmpty)
        let words = list.allDescendants.compactMap { ($0 as? NSTextField)?.stringValue }.joined()
        #expect(words.contains("Setup"))
    }

    /// A list of every calendar today is not the same answer as whatever
    /// calendars there will be, so ticking the last box writes the list too.
    @Test("Ticking writes the whole list, even with every box or none ticked")
    func tickingWritesTheList() throws {
        let entry = try #require(SettingsSchema.everyEntry.first { $0.path == ["calendars"] })
        guard case .set(let some) = SettingsSchema.resolve(
                  .calendars(["Work/Team", "Work/me@example.com"]), for: entry),
              case .set(let none) = SettingsSchema.resolve(.calendars([]), for: entry)
        else {
            Issue.record("a checklist always writes its list")
            return
        }
        #expect(some as? [String] == ["Work/Team", "Work/me@example.com"])
        #expect(none as? [String] == [])
    }

    @Test("The doctor counts the chosen calendars and names any this Mac no longer has")
    func doctorCounts() {
        let onMac = ["Work/Team", "Work/me@example.com", "iCloud/Home"]
        guard case .warn(let fine) = DoctorReport.checkCalendars(
            chosen: ["Work/me@example.com"], onMac: onMac).status
        else {
            Issue.record("a choice of calendars goes unsaid")
            return
        }
        #expect(fine == "1 of 3 count")

        let renamed = DoctorReport.checkCalendars(
            chosen: ["Work/me@example.com", "Work/Old team"], onMac: onMac)
        guard case .warn(let line) = renamed.status else {
            Issue.record("a calendar gone from the Mac goes unsaid")
            return
        }
        #expect(line.contains("Work/Old team"))
        #expect(renamed.remediation?.contains("Meeting calendars") == true)
    }
}
