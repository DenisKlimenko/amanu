# Calendar events that are meetings

2026-10-01

## Why

Over the last two days, six recordings out of seven were named after something
that was not a meeting. Four took the name of an out-of-office block that
covers the working day. Two Meet calls that no event on the Mac links to took
the names of focus-time blocks, one of them a block that began eight minutes
after the call did. One recording began a minute after its block had ended.
The only recording named correctly was a Meet call, found by the meeting code
in its invitation.

The cause is in `CalendarWatcher`:

- **The time window.** `meetings(around:slack:)` returns every event that
  overlaps eight minutes on either side of the recording's start, so a block
  that began hours earlier still qualifies, and so do one that ended a few
  minutes before and one that begins a few minutes after.
- **The choice.** `pick` sorts by start, prefers an event with other people or
  a call link, and falls back to `rest.first`, which is whatever is left. A
  solo block is therefore what a recording gets named after whenever nothing
  better overlaps it, and the earliest-starting, longest block wins among
  several.
- **The calendars.** Every calendar on the Mac is read. A work account can list
  many calendars that are not the user's own — the one behind these
  recordings lists about twenty, colleagues' and teams' among them — and any
  of them that syncs to the Mac can name a recording.

Granola documents rules that avoid each of these, and they are what this
design borrows
([notifications](https://docs.granola.ai/help-center/taking-notes/notifications),
[calendars](https://docs.granola.ai/help-center/getting-started/syncing-your-calendars)):

- only the primary calendar counts until others are switched on in its
  settings;
- declined events and out-of-office, focus-time and working-location blocks
  are not meetings;
- a reminder is shown only for an event with two or more attendees;
- a call noticed through the microphone is linked to an event only if it
  starts within fifteen minutes of that event's start;
- the next five meetings are listed on the home screen, and clicking the
  reminder a minute before one opens its call and starts transcribing.

Four things are wanted in amanu — which events are meetings, the choice of
calendars, the upcoming list and the reminder — and they split into two parts
with a spec each. This is the first: which events count as meetings, and from
which calendars. The second, upcoming meetings and a reminder before each,
depends on this one and is sketched at the end.

## What changes

### 1. What this decides, and what it does not

Nothing here decides whether a meeting is recorded. A recording starts when a
call app holds the microphone or when the button is pressed, and the calendar
only names it. The one start that depends on the calendar,
`auto_record.calendar`, is off by default, and where it is on, the mic trigger
still records the same meeting a moment later whatever the calendar says. A
declined meeting the user joins after all is recorded either way; what follows
is only about what it is called.

### 2. Which events may be guessed

An event may be picked by time when all of these hold:

- it is in a chosen calendar (section 4);
- it is not all-day and not cancelled, as today;
- the user has not declined it — the attendee EventKit marks `isCurrentUser`
  does not have `participantStatus == .declined`;
- it has someone besides the user in it, or a call link: today's
  `looksLikeCall`, unchanged.

Out-of-office, focus-time and working-location blocks have no type in
EventKit, but they are the user alone with no link, so the last condition is
what removes them. An invitation not yet answered still counts, as it does in
Granola. The same conditions decide which events may start a recording from
the calendar (`justStarted`), and in the second part which are listed and
reminded of.

These are rules for a guess. A Meet call in progress is not a guess, and the
next section treats it as proof.

### 3. Which meeting a recording belongs to

The events considered are those overlapping fifteen minutes on either side of
the recording's start; only a Meet call looks further. From them:

1. **A Meet call settles it.** When the browser extension reports a call in
   progress, the event that links to that call is the one, even if its slot
   has just ended — a meeting that runs over is still that meeting. When none
   around the start does, the nearest one within a week either side is,
   because a recurring meeting's room is still that meeting on another day: a
   weekly one-to-one's room, used midweek for a call agreed in chat, names
   that call after the one-to-one. Because the call is proof, this looks past
   the rules for a guess: the event may be declined, and it may be in a
   calendar that is not ticked. An event that links to a different Meet call
   is never chosen, as today.
2. **Meet names a call the calendar does not have.** When no event within that
   week links to the call in progress, the folder takes the title Meet shows
   for the call. Meet puts it in the tab's title, after `Meet - ` — seen
   during a call on 1 October 2026 — and the extension sends the tab's title
   beside the meeting code it already sends. This is what names a declined
   meeting on a Google calendar, because Google appears not to hand declined
   events to the Mac at all, and it also names a call whose invitation went
   to an account this Mac does not have. A title that is only the meeting
   code is not a title and is ignored.
3. **Otherwise time decides**, the way Granola's fifteen minutes do: the
   recording began no earlier than five minutes before the event's start and
   no later than fifteen minutes after it, and before the event's end. Five
   minutes early is amanu's own allowance for opening a call ahead of time;
   the reminder Granola shows comes a minute before.
4. **Nearest start wins** among several, for a Meet code and for time alike.
   Sorting by start and taking the first used to hand the recording to
   whichever event began earliest, which is the long block.
5. **Nothing found names nothing.** The folder is named after the app, and
   the fallback to any event at all is removed. An honest "FaceTime" beats a
   wrong title, for the same reason an honest `them A` beats a wrong name.

The cost is accepted on purpose: joining a meeting half an hour late names the
recording after the app instead of the meeting, when time is all there is to
go on. A Meet call joined late is not affected: its code finds the meeting
in progress, and Meet's title names one the Mac does not have.

**The waiting room reports too.** The code and the title both come from the
extension, which today reports only once the call's tiles are on screen. A
recording starts in Meet's waiting room when its preview holds the microphone
for `start_delay_seconds`, twelve by default — waiting to be let into a
meeting already under way easily takes that long — and the folder is named
when the recording starts, so such a recording has neither and falls to time.
The extension therefore reports a meeting page's code and title from the
moment it opens until the call's tiles first appear; once they have appeared
and gone, the call is over and the page goes quiet. That is what tells the
waiting room from the page Meet leaves after a call, which stays until the
tab is closed, and it reads none of Meet's wording, so it works in any
language. A new meeting in the same tab starts over. The waiting room's
reports carry nobody speaking, which the speaker timeline reads as a quiet
call for that tab alone. Each page load gives its reports an id of its own,
and a state ends only at the next report from the same tab on the same call,
so a waiting room in another tab ends no turn, whether that tab is on this
call or on another. A waiting room left open without joining goes on
reporting its call, and a recording from another app meanwhile would take
that call's name; that waits until it happens.

Against the seven recordings, the new rule gives `2026.09.30-0950`,
`… FaceTime`, `2026.09.30-1526` and `… FaceTime` for the four out-of-office
names, and the Meet-matched name unchanged. The two focus-time ones were Meet
calls that no event on the Mac around their start links to. In Google's
calendar the first coincided with a declined meeting on a different call, and
the second was in a team's standing room, hours after that room's own event,
which the user had declined. Each gets the event that links to its room within
the week, if the Mac has one, or else the title Meet showed for its call — for
the second, the one read from the tab during the call — or `… Dia` where Meet
showed only the code.

### 4. Choosing the calendars

A new key, `calendars`, lists the calendars meetings come from, each written as
the account and the calendar the way Calendar.app's sidebar groups them:
`"Work/me@example.com"`. An entry is compared as a whole string with the one
composed for each calendar, and never split, so a slash inside a name does no
harm.

- **Absent:** every calendar counts, which is how amanu behaves today.
- **Present:** only the calendars listed count. A calendar that appears on the
  Mac later — a new team calendar, a colleague's — stays out until it is
  ticked. This is Granola's behaviour, and it is the one that keeps other
  people's events out without anybody having to notice them arrive.
- **Empty:** no calendar counts.

The choice is a rule for guesses, like the others in section 2: a Meet call in
progress still finds its event in any calendar on the Mac.

The key holds names, not `EKCalendar.calendarIdentifier`. Apple documents that
a full sync loses that identifier, and with identifiers stored, every chosen
calendar would vanish together and the calendar would stop naming anything
without saying so. Names survive a resync; `meta.json` already records the
event's calendar and account by name for the same reason.

**Where it is chosen.** Settings → Advanced → Calendar and naming gets a
"Meeting calendars" entry: a checkbox for every calendar on the Mac, grouped
by account. The birthdays calendar is left out, because it holds only all-day
events, which never count. While the key is absent every box is ticked,
because every calendar counts. Ticking or unticking writes the full list of
ticked calendars; ticking all of them keeps the list rather than clearing the
key, because a list of every calendar today is not the same answer as
"whatever calendars there will be". Without calendar access the entry says so
and points to the Setup tab, where access is given.

The entry is a schema entry like every other on that tab, with a kind of its
own that renders as a checklist, so the README check and the translation check
cover it, and the window shots show it.

**`amanu doctor`** says how many calendars count — "3 of 21" — and names any
chosen calendar that is no longer on the Mac, which is what a renamed calendar
looks like.

### 5. Dia by its name

With fewer recordings named after events, the app is more often the whole
name, and Dia's audio service names itself "Browser Helper".
`AudioProcesses.displayNames` gets `company.thebrowser.browser.helper` →
"Dia", next to `avconferenced` → "FaceTime". Arc uses the same helper and
would be called Dia too; this fork's user runs Dia and not Arc, and the
helper's parent app is where to look if that changes.

## What stays

- **Calendars come from EventKit, not from Google's API.** EventKit already
  has access and needs no sign-in or network, and it carries everything the
  rule needs: attendees and their answers, the call link, and — confirmed on
  30 September — the Meet link in a Google invitation. What the API adds is
  the event type, which the rule does not need, and the declined invitations
  Google appears to keep from the Mac, which Meet's own title covers for Meet
  calls.
  OAuth, token storage and a second provider for Outlook are a large price for
  the rest.
- `calendar` (read the calendar for names) and `auto_record.calendar` (start
  from events) keep their meanings and defaults.
- `meta.json` keeps `calendar_name`, `account` and `matched_by`. A title that
  came from Meet has no event to carry `matched_by`, so it is marked
  `"title_from": "meet"` beside `title`.

## Not in this part

- **Upcoming meetings and the reminder** are the second part. The menu lists
  the next meetings that pass the rule above, each with a Join action that
  opens its call link; a minute before a meeting with other people in it, a
  reminder offers the same action and starts recording. Both read through the
  same rule and the same `calendars`, which is why they come second.
- Renaming a folder after the summary's topic when no event matched, which is
  how Granola titles a note with no event behind it.
- Checking that the user is among an event's attendees. The calendar choice
  covers colleagues' calendars; the check stays deferred until something gets
  through anyway.

## Testing

Next to the existing `pick` tests in `SessionNamingTests` and the calendar
tests in `AutoRecordTests`:

- the seven recordings above as cases with the expected names, with neutral
  titles — "Out of office", "Focus time", "Sprint demo" — since this fork is
  public;
- the rule one condition at a time: a solo block names nothing; a declined
  event is never chosen by time; five minutes early and fifteen late are
  inside the window, six early and sixteen late are not; an event that has
  ended is never chosen by time; the nearest start wins; a Meet code wins
  after the event's end; a Meet code finds an event days away when none
  around the start links to the call, and one around the start beats it; an
  event linking to another call is never chosen;
- proof over the rules for a guess: a declined event the call in progress
  links to names the recording, and so does one in a calendar that is not
  ticked; a call with no event takes Meet's title, even over an event that
  time alone would choose; a title that is only the meeting code is ignored;
- `calendars` absent, listing one calendar, and empty — for naming and for
  starting from the calendar.

The settings entry goes through `SettingsDocumentationTests` and the
translation check like every other, and the Advanced tab is photographed in
both languages and appearances as `docs/testing/window-shots.md` describes.

What only a live check shows, after installing: a Meet call with an invitation
gets `"matched_by": "meet"`; a declined Meet meeting joined after all is named
after itself; a call with no event during a focus block is named after its
Meet title or its app; a recording that starts while waiting to be let in is
named after the meeting; `amanu doctor` lists the chosen calendars.

## Documentation

- README: the `calendars` key, beside `calendar`.
- `docs/pitfalls.md`: the entry on finding a Meet call's event by its code
  moves out of "believed correct on reasoning alone" — an event in a personal
  Google calendar was matched by its code on 30 September 2026. The declined
  check moves in: Google appears not to hand declined events to the Mac at
  all — a declined invitation overlapping a recording on 30 September was not
  among the candidates — so on a Google calendar the check has never run.
  So does Meet's title: the tab's `Meet - <title>` was seen on one call, and
  whether Meet writes it the same way in every language, or already in the
  waiting room, is not known.
- `Extensions/meet/README.md`: the title the extension now sends, and that it
  reports from the waiting room.

## Delivery

One branch off `fork`, one pull request into DenisKlimenko/amanu, four
commits: the rule and the window, the calendar choice, Meet's title and the
waiting room, Dia's name. The extension is loaded unpacked from the
repository, so Dia has to reload it after the third.
