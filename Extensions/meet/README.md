# Meet speakers

Names the far end of a Google Meet call from Meet itself. While you are in a
call, this extension notes whose tile Meet lights up as speaking, and amanu
matches that timeline against the transcript by the clock. Every name comes
from something Meet showed, not from a model guessing, and the extension
sends nothing anywhere except to amanu on this Mac.

## Setup

1. Register the host that the extension talks to, once per machine:

   ```sh
   amanu meet install
   ```

   This writes `me.samat.amanu.meet.json` into the `NativeMessagingHosts`
   folder of every Chromium-family browser it finds (Dia, Chrome, Arc,
   Brave, Edge, Vivaldi). `amanu meet install --uninstall` removes it again.

2. Load the extension in each browser profile you join Meet from:
   - open `dia://extensions` or `chrome://extensions`;
   - turn on Developer mode;
   - choose Load unpacked, and pick this folder.

   The extension ID is fixed by the key in `manifest.json`
   (`nbighglgalgflgobaljbogmopffnjohd`), so the host accepts it on any
   machine.

3. Restart the browser.

## Checking it works

In a call, open the page's DevTools console and filter for `amanu:`. Every
change of speaker is logged there. amanu writes each connection's timeline to
`~/Library/Application Support/amanu/meet/<start-ms>.jsonl` and keeps it for
good, so a session transcribed again later is named again. When a session is
transcribed, `transcribe.log` in the session folder reports a line like
`Meet named them A → …`, and `speakers.json` records those names with
`"source": "meet"`.

The timeline also carries the call's meeting code and the tab's title, from
the waiting room on. A recording can start there, while the preview holds the
microphone, and its folder is named when it starts. The extension reports a
meeting page until the call's tiles first appear, then while they are on
screen, and nothing once they have gone. The page Meet leaves after a call
says nothing, however long it stays open.

A recording that starts during a call is named after the calendar event that
links to that call, in whichever calendar it is, and never after an event that
links to another call. If none around the start does, it takes the nearest
one within a week: a recurring meeting's room used on another day. `meta.json`
then says `"matched_by": "meet"` under `calendar`, next to the calendar's name
and account. When no event links to the call, the folder takes the title Meet
shows for it, the tab's title after `Meet - `, and `meta.json` says
`"title_from": "meet"` instead. A tab that shows only the meeting code gives
no title, and time or the app names the recording. With both `calendar` and
`auto_record.calendar` off, the calendar is not read, so neither a linked event
nor Meet's title names a recording.
