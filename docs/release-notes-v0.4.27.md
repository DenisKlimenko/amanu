# Amanu 0.4.27

This release follows a full audit of the app. It closes several ways a meeting could leave the Mac against your choice, or be lost, and makes recording, transcription and setup behave the same way everywhere.

## Privacy

- Speaker naming now goes wherever summaries go. Choosing Ollama, or turning summaries off, no longer lets naming send the transcript to Claude or OpenAI.
- The `claude` command-line tool is run with no tools, no personal settings and no hooks, so something said on a call cannot make it act on your Mac. Codex runs with its MCP servers turned off.
- Choosing an engine for one recording is honoured even while other recordings are being transcribed, and a fallback to the local engine applies only to the recording that needed it.
- Keys for OpenAI-compatible summary servers are kept apart from the OpenAI transcription key, and neither is sent to the other's server.
- A config file that cannot be parsed no longer resets every setting to its default: Amanu keeps using the last settings it read, refuses to overwrite the file, holds transcription and summaries, and says what is wrong until the file is fixed.

## Recordings

- Automatic recording no longer starts again seconds after stopping at its own silence or duration limit.
- A recording that cannot start is retried with growing pauses and one banner, instead of every few seconds with a new empty folder each time.
- The auto-record switch in the menu, the status window and Settings is one setting, remembered across restarts and applied at once.
- Recurring calendar meetings are recognised every time, and a meeting started from the calendar waits for you to join before it can stop as ended.
- A recording ends cleanly when the Mac goes to sleep.
- The microphone falls back to the default device or to plain capture when the chosen one refuses, at the start as well as mid-call, and a refusing device is no longer retried every few seconds.
- The archived audio keeps both channels of the call audio, and a file that cannot be read in full is never replaced by one that is silent at the end.
- A session whose details could not be saved stays recoverable instead of disappearing from the list.

## Transcription

- Re-transcribing now discards cached answers from AssemblyAI, OpenAI and ElevenLabs, so a corrected language gives a new transcript.
- An AssemblyAI job survives a brief network problem and is resumed rather than uploaded and paid for again.
- A failed model download or a missing key no longer counts against your meetings. Downloads are shared between windows and resume where they stopped.
- If echo cancellation fails, the meeting is transcribed without it instead of failing.
- A recording with one empty or missing track is transcribed from the other track.
- Whisper no longer forces the configured language on meetings expected in two languages.
- The `on_stop` hook runs once, after names and summary, including for sessions finished later.

## Summaries

- A summary is postponed rather than abandoned while a model is only temporarily unreachable, and gives up after a few real attempts instead of retrying for ever.
- Ollama receives a context large enough for the whole prompt.

## Setup and settings

- A new recordings folder takes effect without restarting.
- The sound test cannot be run during a recording.
- Setup notices permissions granted in System Settings when you return to it.
- Choice cards and switches work with the keyboard and VoiceOver.
- A key check tells an unreachable server apart from a refused key.

## Compatibility

- Universal binary for Apple Silicon and Intel Macs running macOS 14.2 or later. Local transcription requires Apple Silicon; Intel requires a cloud transcription key and has not been tested on physical hardware.
