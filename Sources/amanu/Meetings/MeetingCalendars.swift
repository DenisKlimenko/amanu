import EventKit
import Foundation

/// The `calendars` setting: which calendars a recording may be named after by
/// its time. Section 4 of
/// `docs/specs/2026-10-01-calendar-meetings-design.md` describes it.
///
/// A work account can list many calendars that are not the user's own,
/// colleagues' and teams' among them, and every one that syncs to the Mac
/// could name a recording. While the setting is absent every calendar still
/// counts. Once it lists some, only those do, and a calendar that appears
/// later stays out until it is ticked, which is Granola's behaviour. A Meet
/// call in progress finds its own event in any calendar regardless.
enum MeetingCalendars {
    /// One account's calendars, the way Calendar.app's sidebar groups them.
    struct Account: Equatable {
        let name: String
        let calendars: [String]
    }

    /// How the setting writes a calendar: its account, a slash, its name —
    /// `Work/me@example.com`. Compared whole and never split, so a slash in
    /// either name does no harm.
    ///
    /// Names rather than `EKCalendar.calendarIdentifier`, which Apple
    /// documents a full sync replaces. With identifiers stored, every chosen
    /// calendar would drop out at once, and the calendar would stop naming
    /// anything without a word. With names, a renamed calendar drops out
    /// alone, and `amanu doctor` names it.
    static func key(account: String?, calendar: String?) -> String {
        "\(account ?? "")/\(calendar ?? "")"
    }

    /// Whether a calendar counts under the setting as read, nil being absent.
    static func counts(_ key: String, chosen: [String]?) -> Bool {
        chosen?.contains(key) ?? true
    }

    /// The calendars on this Mac by account, or nil when there are none to
    /// see — which, without calendar access, there never are. The store is
    /// asked rather than `authorizationStatus`, which a grant made in this
    /// process does not update (`Permissions.requestCalendar`). That a store
    /// made right after a grant in the same process lists the calendars is
    /// reasoned from that, never seen. The birthdays calendar is left out: it
    /// holds only all-day events, and those never name a recording.
    static func onThisMac(_ store: EKEventStore = EKEventStore()) -> [Account]? {
        let calendars = store.calendars(for: .event).filter { $0.type != .birthday }
        guard !calendars.isEmpty else { return nil }
        let byAccount = Dictionary(grouping: calendars) { $0.source?.title ?? "" }
        return byAccount.keys.sorted(by: inOrder).map { account in
            Account(
                name: account,
                calendars: Set(byAccount[account, default: []].map(\.title)).sorted(by: inOrder))
        }
    }

    private static func inOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}
