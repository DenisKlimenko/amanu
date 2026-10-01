import EventKit
import Foundation

/// Reads the local calendars for two things: a real name for the session
/// folder instead of a bare timestamp, and a second, independent trigger for
/// automatic recording.
///
/// Opt-in (`auto_record.calendar`), because it costs a permission prompt and
/// because a calendar is only a good meeting signal if yours is accurate. The
/// mic-activity trigger needs no permission and no accurate calendar, so it
/// stays the default of the two.
@MainActor
final class CalendarWatcher {
    struct Meeting {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let attendees: [String]
        /// Conference link or location, whichever the event carries — kept so
        /// the recording folder can say where the call actually happened.
        let link: String?
        /// True when the event has other people or a conference link — the
        /// difference between a meeting and "dentist, 15:00".
        let looksLikeCall: Bool
        /// The Meet calls the event links to, by meeting code. Google puts an
        /// invitation's Meet link in the event's notes, so they are read too.
        var meetCodes: Set<String> = []
        /// The calendar the event is in and the account that calendar belongs
        /// to, which is what tells a work meeting from a personal one.
        var calendarName: String?
        var account: String?
        /// How the event was chosen for a recording.
        var matchedBy: MatchedBy = .time
        /// Whether the user has declined the invitation.
        var declined = false
        /// Whether the event's calendar is one meetings come from — the
        /// `calendars` setting. Only a guess heeds it: a Meet call finds its
        /// event in any calendar.
        var chosen = true

        /// Whether a recording may be named after the event, or started by
        /// it, on its time alone. The event has to be in a calendar that
        /// counts and be a meeting the user has not declined, with someone
        /// else in it or a call link.
        /// Out-of-office, focus-time and working-location blocks have no type
        /// in EventKit, but they are the user alone with no link, which is
        /// what keeps them out. An invitation not yet answered still counts,
        /// as it does in Granola.
        var guessable: Bool { chosen && !declined && looksLikeCall }
    }

    enum MatchedBy: String {
        /// The event links to the Meet call the browser extension says we are in.
        case meet
        /// The event is on at the time, and nothing more specific was known.
        case time
    }

    /// What a recording is named after.
    enum Match {
        /// An event in the calendar.
        case event(Meeting)
        /// The title Meet shows for a call that no event on the Mac links to.
        case meetTitle(String)

        var event: Meeting? {
            if case .event(let event) = self { return event }
            return nil
        }
    }

    private let store = EKEventStore()
    private(set) var authorized = false

    /// Ask once, at startup, and only when the calendar trigger is enabled.
    /// Denial is not an error: the mic trigger carries on alone.
    func requestAccess() async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            authorized = true
        case .notDetermined:
            authorized = (try? await store.requestFullAccessToEvents()) ?? false
            if !authorized {
                FileHandle.standardError.write(Data(
                    "calendar access denied — auto-record falls back to mic activity only\n".utf8
                ))
            }
        default:
            authorized = false
            FileHandle.standardError.write(Data(
                "calendar access not granted — sessions will be named by time\n".utf8
            ))
        }
    }

    /// Meetings that started within the last `window` seconds (or are about to,
    /// by up to 30s — calendar clocks and wall clocks disagree slightly) and
    /// may be guessed at. The auto-record trigger.
    func justStarted(now: Date, window: TimeInterval) -> [Meeting] {
        Self.justStarted(meetings(around: now, slack: window), now: now, window: window)
    }

    /// The trigger's rule, apart from the calendar it reads.
    static func justStarted(_ events: [Meeting], now: Date, window: TimeInterval) -> [Meeting] {
        events.filter {
            let sinceStart = now.timeIntervalSince($0.start)
            return sinceStart >= -30 && sinceStart <= window && $0.guessable
        }
    }

    /// How far either side of a recording's start its events are looked for,
    /// and how long after a meeting's start a recording can begin and still
    /// be named after it by time: Granola's fifteen minutes.
    static let window: TimeInterval = 15 * 60
    /// How long before a meeting's start a recording can begin and be named
    /// after it by time — amanu's own allowance for opening a call early.
    static let early: TimeInterval = 5 * 60
    /// How far a Meet call's room is looked for. A recurring meeting's room
    /// is still that meeting on another day, and a week either side reaches
    /// the nearest occurrence of anything held weekly or fortnightly.
    static let roomReach: TimeInterval = 7 * 24 * 60 * 60

    /// What best names a recording started at `date` — used to name the
    /// session folder even when the recording began some other way.
    func bestMatch(for date: Date) -> Match? {
        let calls = MeetSpeakers.callsInProgress(at: date)
        // Only a Meet call looks past the window, for its room's meeting.
        let reach = calls.isEmpty ? Self.window : Self.roomReach
        return Self.pick(from: meetings(around: date, slack: reach), duringMeet: calls, at: date)
    }

    /// What a recording started at `date` is named after, if anything;
    /// section 3 of `docs/specs/2026-10-01-calendar-meetings-design.md` gives
    /// the rule.
    ///
    /// A Meet call in progress is proof rather than a guess. The event that
    /// links to it is the one, in whichever calendar, declined or not, even
    /// after its slot is over. Events around the start come first, then the
    /// nearest within `roomReach`. An event that links to another call is
    /// never the one.
    ///
    /// When no event links to the call, the title Meet shows for it is next,
    /// ahead of any guess from the time, since it is Meet saying what this
    /// call is. It names a declined Google meeting, which Google appears not
    /// to hand the Mac, and a call whose invitation went to an account the
    /// Mac lacks.
    ///
    /// Otherwise time decides, and only for an event that is `guessable`. The
    /// recording must have begun no more than `early` before the event's
    /// start, no more than `window` after it, and before its end. The nearest
    /// start wins either way: taking the earliest used to hand recordings to
    /// the long block. When nothing matches, the folder is named after the app
    /// alone, since an honest "FaceTime" beats a wrong title.
    static func pick(
        from events: [Meeting], duringMeet calls: [MeetSpeakers.Call], at date: Date
    ) -> Match? {
        let codes = Set(calls.map(\.code))
        let linked = events.filter { !$0.meetCodes.isDisjoint(with: codes) }
        let around = linked.filter {
            $0.end > date.addingTimeInterval(-window) && $0.start < date.addingTimeInterval(window)
        }
        if var event = nearest(around, to: date) ?? nearest(linked, to: date) {
            event.matchedBy = .meet
            return .event(event)
        }
        if let title = calls.lazy.compactMap(\.title).first {
            return .meetTitle(title)
        }
        return nearest(events.filter {
            $0.guessable
                && (codes.isEmpty || $0.meetCodes.isEmpty)
                && date >= $0.start.addingTimeInterval(-early)
                && date <= $0.start.addingTimeInterval(window)
                && date < $0.end
        }, to: date).map(Match.event)
    }

    private static func nearest(_ events: [Meeting], to date: Date) -> Meeting? {
        events.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }

    /// Meeting codes of the Meet links in `text`: the path after
    /// `meet.google.com/`, which is also how the extension names a call.
    static func meetCodes(in text: String) -> Set<String> {
        Set(text.lowercased().matches(of: #/meet\.google\.com/([a-z0-9-]+)/#).map { String($0.1) })
    }

    // MARK: -

    private func meetings(around date: Date, slack: TimeInterval) -> [Meeting] {
        guard authorized else { return [] }
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else { return [] }

        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-slack),
            end: date.addingTimeInterval(slack),
            calendars: calendars
        )
        let chosen = Config.meetingCalendars()
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.status != .canceled }
            .map { Self.convert($0, chosen: chosen) }
            .sorted { $0.start < $1.start }
    }

    private static func convert(_ event: EKEvent, chosen: [String]?) -> Meeting {
        let attendees = (event.attendees ?? []).compactMap { participant -> String? in
            participant.name
                ?? participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }
        let haystack = [
            event.location ?? "",
            event.url?.absoluteString ?? "",
            event.hasNotes ? (event.notes ?? "") : "",
        ].joined(separator: " ").lowercased()

        // The link is worth keeping verbatim; the notes are not — they are as
        // often a wall of boilerplate or something private as they are useful.
        let link = [event.url?.absoluteString, event.location]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return Meeting(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "meeting",
            start: event.startDate,
            end: event.endDate,
            attendees: attendees,
            link: link,
            // Self counts as an attendee, so "other people" means more than one.
            looksLikeCall: attendees.count > 1
                || Self.conferenceMarkers.contains { haystack.contains($0) },
            meetCodes: Self.meetCodes(in: haystack),
            calendarName: event.calendar?.title,
            account: event.calendar?.source?.title,
            // Google appears not to hand declined invitations to the Mac at
            // all, so on a Google calendar this has yet to find one.
            declined: event.attendees?.first { $0.isCurrentUser }?.participantStatus == .declined,
            chosen: MeetingCalendars.counts(
                MeetingCalendars.key(
                    account: event.calendar?.source?.title, calendar: event.calendar?.title),
                chosen: chosen)
        )
    }

    /// Substrings that mean "there's a call link in here". Kept broad rather
    /// than clever: a missed marker only costs the calendar trigger for that
    /// event, and the mic trigger still catches the meeting.
    private static let conferenceMarkers = [
        "zoom.us", "meet.google.com", "teams.microsoft", "teams.live", "whereby.com",
        "webex.com", "jitsi", "around.co", "gather.town", "huddle", "discord.gg",
        "telemost", "yandex.ru/telemost", "ktalk", "contour.ru", "salutejazz", "vkmeet",
    ]
}
