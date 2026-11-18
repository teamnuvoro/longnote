# Review: Record opens a ready screen; Start / Pause / Stop & save controls

Reviewer: Claude Fable 5.1, 2026-11-18. Read-only review of branch v1-build,
`git diff faab1eb..HEAD` for lib/features/recording, lib/features/notes,
lib/app/router.dart, plus test/screens/bcd_flow_test.dart,
integration_test/qa_3_recover_test.dart (H3), integration_test/support/qa_harness.dart.
Also read for context: lib/core/recording/recording_controller.dart (start, stop,
_setStatus, _onInterruption, failure clean-up), lib/app_services.dart
(startRecording, canStartRecording, lifecycle listener), lib/app/nav.dart
(NavGuard), lib/ui/widgets/pressable.dart, lib/ui/widgets/buttons.dart,
lib/core/audio/pcm_source.dart. Billing files skipped (already approved).

## Verdict: APPROVED

Nothing in this change can start a recording the user did not ask for, lose one,
or leave the screen in the wrong state on the paths I traced. The ready/live/ended
decision in `build` is driven by the controller's state, not by the screen's own
flags alone, so every failure path lands on a sensible screen:

- Start fails (mic denied, source error): controller returns to `idle` and clears
  `current`; `_ready = !isActive` keeps the ready screen with the toast. Permission
  text is correct ("Bad state: microphone permission denied" contains "permission").
- Phone call while starting: `_onInterruption(began)` sees `!isActive` (state is
  `starting`), closes the gap it just wrote, and returns; the source then either
  throws (ready screen + toast) or starts (live screen). No stuck state.
- Backgrounded on the ready screen: no timers, no listeners beyond the repo; on
  return the screen is still ready, the 400 ms open guard has long passed.
- Re-opened while recording: Notes `_onRecord` pushes `/record` without `ready`;
  a stale `/record?ready=1` with an active recorder gives `_ready = false` (line 57)
  and the live view. `initialLocation` never points at `/record`.
- Live view appearing before `startRecording()` returns (the controller notifies
  `recording` before `setNoteOptions` runs): Pause is blocked by `_starting`, Stop
  works (controller is active), `_start` then finds `!mounted` and returns.
- Double tap on Record: NavGuard drops the second push; a second tap that lands on
  the sliding-in Start is dropped by the 400 ms open guard (set in `initState`).
- Double tap on Start: the second tap lands on the disabled Start (spinner) or on
  Pause, which `_pauseOrResume` ignores while `_starting` or within 600 ms of the
  tap. Geometry check: Start's hit box is 160 wide (±80 from centre); on the live
  row Discard spans −170..−86 and Stop & save 86..170, so a second tap inside
  Start's box can never reach Discard or Stop.
- iOS swipe-to-dismiss: `CupertinoPage(fullscreenDialog: true)` has no back
  gesture, so the ready screen cannot be dismissed mid-start by a swipe.
- Accessibility: Start ("Start recording"), Close ("Close (nothing is recorded)"),
  Pause/Resume/Resume now, Discard, Stop & save all carry labels through
  `LnPressable` (`button: true`, `enabled` follows `onTap`). Timer on the ready
  screen is labelled "Recorded time".
- App Review: the microphone prompt now fires on an explicit Start tap, which is
  the pattern Apple prefers; the denied-path message points to Settings.
- Tests: the widget test's `settle()` pumps 4 × 120 ms under flutter_test's fake
  clock, so the 400 ms open guard is honoured, not bypassed. H3 now measures the
  real gap and adapts to a stalled CI machine; the logic is sound.

Four minor items below; none blocks the TestFlight build.

## Findings

### 1. minor — if Start hangs, the user has no way off the ready screen
`lib/features/recording/recording_screen.dart:632` (`onPressed: starting ? null : onClose`),
`:113-141` (`_start`, no timeout).
Scenario: `startRecording()` awaits `hasPermission(request: true)` and then
`startStream` with no timeout. If the `record` plugin or the audio session stalls
(it should throw, but a stall is not impossible on a device with another app
holding the session), the ready screen shows the spinner with Close disabled, and
the only exit is killing the app. Before this change the same stall left the user
on Notes, free to move around.
Fix: either keep Close enabled while starting (pop; if the start later succeeds the
Notes pill shows "Recording · 00:0x", which is visible and honest), or wrap the
await in a ~15 s timeout that resets `_starting`, shows "Could not start
recording. Please try again." and re-enables Close. The timeout is the safer of the
two: it never leaves a recording running behind a closed screen.

### 2. minor — wrong toast when capture started but the defaults could not be saved
`lib/features/recording/recording_screen.dart:120-132`, `lib/app_services.dart:448-462`.
Scenario: `recorder.start()` succeeds, then `setNoteOptions` or a settings read
throws. The screen correctly stays live (`_ready = !isActive` → false), but the
toast says "Could not start recording. Please try again." while the timer is
visibly running. `startRecording`'s catch also calls `jobs.resume()`, so
background jobs run during capture.
Fix: in the catch, when `_s.recorder.isActive`, show nothing (or "Recording
started; default language/style could not be applied") and skip the error toast.
In `startRecording`, only `jobs.resume()` when `!recorder.isActive`.

### 3. minor (pre-existing, now reachable from the ready screen) — a failed start after the DB insert leaves a ghost "recording" row
`lib/core/recording/recording_controller.dart:120-121, 183-204`.
Scenario: mic permission is fine but `source.start()` throws (audio session
error). `repo.insert(rec)` has already run and notified; the controller's catch
frees the mic and sink but leaves the row with status `recording` ("repaired at
next launch"). The user taps Start again and records; back on Notes the ghost row
sits in the list until the next cold launch. Not introduced by this change (the
old home-screen Record had the same path), but the ready screen makes "try again"
the natural next move, so it is more likely to be seen.
Fix: in the controller's catch, `repo.deleteByUser(rec.id)` (or mark it failed)
when the row was inserted and no audio was written.

### 4. minor — guard-dropped taps give no feedback
`lib/features/recording/recording_screen.dart:78-81, 114-115`.
Scenario: a tap on Pause within 600 ms of Start, or on Start within 400 ms of the
screen opening, shows the pressed-opacity flash but does nothing. For a human
double tap that is the intent; for a deliberate quick tap it looks like a missed
press. In practice the modal transition alone exceeds 400 ms and nobody pauses
within 600 ms of starting, so this is cosmetic.
Fix (optional): while the guard is active, pass `onTap: null` so the button renders
disabled (0.4 opacity) for those few hundred ms instead of pretending to accept
the tap. Not worth a build on its own.

## Not findings (checked and fine)

- `notes_screen.dart:104-123`: `_starting` wraps the paywall await and resets in
  `finally`; a paywall `pushOnce` that NavGuard drops returns null and simply does
  nothing (pre-existing).
- `_TrialChip` now uses `screenNow()` (a plain `DateTime.now` by default, pinned
  in golden tests); no behaviour change in the app.
- `clock` is a regular dependency (pubspec.yaml:39), already used by NavGuard.
- Ready-screen layout fits a 568 pt tall phone (≈350 pt of content).
- `_loadNote` after a failed start: `current` is null and `_lastId` null, returns.
- `_leaving` is never set on the ready path, so Close never shows the blank
  night scaffold; `_Ended` is only reachable after a real start.
