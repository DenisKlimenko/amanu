---
title: "A mic restart can hang amanu inside AVAudioEngine while AirPods change mode"
date: 2026-10-02
status: open
affects: "the mic track and the whole app, for as long as the hang lasts"
---

## What happened

`2026.10.02-1201 snowflake meeting cost managment (Browser Helper)`, a Meet
call in Dia on the built-in microphone with AirPods as the default input and
output. The system log has the whole of it; amanu's own stderr went nowhere,
because macOS launched the app.

- 12:01:34 — a restart follows Meet to the built-in microphone. The engine
  starts and delivers nothing: `AUHAL::AUIOProc: mono buffer too small
  (512 > 480)` on every cycle. `MicRecorder.restartIfSilent` is the answer
  to that part.
- 12:02:48.80 — something restarts capture. The old engine stops, the new
  one's input unit connects to the default device aggregate, and AVFAudio
  logs `Error setting device on iounit, err = 1852797029` ('nope',
  `kAudioHardwareIllegalOperationError`) from a thread of its own.
- 12:02:48.81 to 12:14:09 — nothing at all from the main thread. No engine
  start, no retry two seconds later, no watchdog tick. Only RunningBoard and
  Core Audio threads log in between.
- 12:13:42 — the AirPods reconnect. At 12:14:00 AVFAudio threads come alive
  (`TCCAccessRequest`, `AVAUVoiceIOGetPreferredChatFlavorForBundleID`), and at
  12:14:09 the main thread carries on with the bind it was in the middle of —
  into the format mismatch that ended the app at 12:14:23.

So for eleven minutes the first touch of a new `AVAudioEngine`'s `inputNode`
never returned, and everything that runs on main — the menu, the recording
timer, the stall watchdog, `restartIfSilent` itself — waited with it. The
system track kept writing; it has its own queue.

## What is not known

- What started the 12:02:48 restart.
- Whether `inputNode` was waiting on Bluetooth (at 12:01:25
  `SetBluetoothAudioFormatAndWait(349)` had timed out) or on the
  previous engine's default-device aggregate being torn down under it.
- Whether a pause between releasing one engine and creating the next would
  have been enough.

None of it reproduces without AirPods, and no one has sampled the main thread
during a hang.

## What would end it

Two directions, neither started:

1. **Read the microphone without `AVAudioEngine`.** An IO proc on the chosen
   device itself, the way `SystemAudioRecorder` reads its tap: no default
   device aggregate, no Bluetooth format negotiation, no tap format to
   mismatch. The raw path is the default, and voice processing would keep
   the engine.
2. **Build engines off main.** A hang would then take the mic track and
   nothing else, and main could notice that an attach has not come back.

If it happens again, `sample Amanu 5` during the hang says where `inputNode`
is waiting, which is the first thing either direction needs.
