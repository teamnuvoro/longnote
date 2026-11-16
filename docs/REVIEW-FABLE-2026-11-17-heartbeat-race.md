# Review: heartbeat-vs-Stop race fix (commit 988abd1)

Reviewer: Claude Fable 5.1, 2026-11-17. Read-only review of branch v1-build.
Files read: recording_controller.dart, segment_writer.dart, wav.dart,
recording_repository.dart, recovery_service.dart, pcm_source.dart,
app_services.dart, recording_screen.dart, test/recording_controller_test.dart.

## 1. The fix itself: correct and complete for this race

`recording_controller.dart:227` returns unless `identical(_sink, sink) && isActive`.

Why it closes the hole: `stop()` sets `state = stopping` synchronously at
line 333, before its first await, and cancels the heartbeat timer at 336.
So the only heartbeat that can resume after Stop started is one already parked
in `repo.heartbeat()`. Whenever it resumes, `isActive` is already false
(stopping or idle), so the late `upsertSegment` never runs. Both halves of
the guard are needed:

- `!isActive` covers the window from line 333 to the `finally` (where `_sink`
  is still the same object).
- `!identical(_sink, sink)` covers a quick Stop then Start: `state` is set to
  idle at line 392 before `await onFinished` at 399, so a new `start()` can
  make `isActive` true again while the old heartbeat is still pending. Without
  the identity check it would write the OLD recording's row with the closed
  sink's 0 bytes.

Writes issued before Stop are safe: `sqflite` serialises calls per database in
call order, and the heartbeat reads `currentSegmentBytes` synchronously before
its own `upsertSegment` call, so a heartbeat that passed the guard always
writes the real size and lands before Stop's final row.

The regression test (`_SlowHeartbeatRepo`, test lines 179-204) parks the
heartbeat inside `repo.heartbeat`, stops, releases, then asserts the segment
row still has 96000 bytes. That is exactly the failing interleaving.

## 2. Sibling races

### F1 (Medium): `_setStatus` after an await can reopen a stopping recorder

`recording_controller.dart:256-263` has no guard. Three callers reach it after
awaits: `pause()` 244, `resume()` 253, and `_onInterruption` 292 / 302. The
interruption path is the realistic one: `stop()` awaits `_source.stop()` at
339 (record stop + AudioSession reconfigure + setActive(false), hundreds of
ms) BEFORE cancelling `_intSub` at 345, and cancelling a subscription does
not stop a handler that is already running.

Interleaving (a phone call lands as the user taps Stop):

1. `stop()`: state = stopping, timers cancelled, `await _source.stop()`.
2. `_onInterruption(began)`: `sink != null` passes (268), `await repo.addGap`
   (274), `await analytics.log` (284).
3. `_setStatus(paused, paused)` (292): `current` is still set, so
   `rec.status = paused`, `state = paused`, `updateCapture(paused)`.
   `isActive` is now TRUE again while Stop is mid-flight.
4. Consequences, depending on where Stop is at that moment:
   - If Stop's `updateCapture(completed)` (371) has already been queued, the
     DB row ends as `paused` with an open gap row. Next launch,
     RecoveryService rewrites it as "Interrupted - saved X" (status
     interrupted, home_screen.dart:264) and `_afterRecording` enqueues it a
     second time. Audio is not lost (files on disk are the truth), but the
     clean Stop is reported as a crash.
   - While `state == paused` the screen re-enables Pause/Resume/Stop
     (recording_screen.dart:321 only disables on `stopping`), and `_fail`'s
     `stop()` is no longer a no-op. A second `stop()` passes the guard at
     332, reads `lastBytes = sink.currentSegmentBytes` = 0 from the closed
     sink (segment_writer.dart:55) and writes the final row with
     `dataBytes: 0, closed: true` (356-364). That is the same
     "No audio was saved" failure through a second door.
   - The heartbeat guard from 988abd1 is also defeated in this state
     (`identical` true, `isActive` true).

Smallest fix:

```dart
Future<void> _setStatus(RecordingStatus s, CaptureState cs) async {
  final rec = current;
  if (rec == null || !isActive) return;   // Stop already owns the ending
  ...
```

Recommended in addition (one line): move `await _intSub?.cancel()` above
`await _source?.stop()` in `stop()` so the long audio-session teardown is not
inside the window. And in the `began` branch, after `await repo.addGap`,
if `!isActive || !identical(_sink, sink)` close that gap right away instead
of storing it in `_openGapId`.

### F2 (Low, not a race, but it leaks into the next recording)

`_userPaused`, `_openGapId` and `_gapStartedAt` are never reset in `start()`
or `stop()`. `_userPaused` is set at 241 and cleared only in `resume()` 249.
The ordinary flow Pause then Stop leaves it true. In the NEXT recording a
phone call runs `began` (status paused, banner "Paused by a phone call")
and `endedResumable` returns at 294 because `_userPaused` is still true: the
controller stays `paused`, the gap stays open and grows until the user taps
Resume, and the transcript later reports that time as "not recorded" even
though the native recorder (AudioInterruptionMode.pauseResume) was writing
into the still-open sink. `_openGapId` leaks the same way through F1
(step 3 stores a gap id after Stop's `_endGap` already ran), and then the next
recording's `began` returns early at 272 and never marks itself paused.

Smallest fix: at the top of `start()` (after the idle check) set
`_userPaused = false; _openGapId = null; _gapStartedAt = null;`.

### F3 (Low): a failed `start()` leaves the recorder half-open

`start()` sets `_source`, `_sink`, `current` at 148-150, then awaits
`source.start()` 154. If that throws, the catch at 178 only resets `state`.
The WAV file stays open, the source is not disposed (mic may stay held) and
the row stays `recording` until the next launch. No audio is lost and the
next `start()` overwrites the fields, so this is hygiene only.

Smallest fix: in the catch, `_sink?.close()` in a try, `source.dispose()`,
and null `_source/_sink/current`.

### Checked and found safe

- `onSegmentOpened` / `onSegmentClosed` unawaited writes (127-144): issued
  synchronously from `sink.add` / `sink.close`, so they are queued before
  Stop's final `upsertSegment` and `updateCapture`; the close callback writes
  the same bytes Stop writes (`WavWriter.close` keeps `dataBytes`,
  wav.dart:167-179). Harmless duplicate.
- `tickFlush` (201): timer cancelled synchronously in Stop; on a closed sink
  `maybeFlush` is a no-op; `_fail` inside it hits the `!isActive` guard.
- `_onAudio` during Stop: the audio subscription is cancelled (343) before
  `sink.close()` (349), so no chunk reaches a closed sink.
- `_fail` → `stop(reason: 'error')` while a user Stop runs: returns null at
  332; the banner it set is cleared at 393 for a saved user Stop.
- RecoveryService: runs once in `boot()` (app_services.dart:309) before any
  recording can start; no concurrency with the controller. `recoverOne`
  takes sizes from the files, so it cannot be fooled by a bad row.
- `discardRecording` (app_services.dart:386): `_discarding` is set before
  `stop()`, so `onFinished` skips the enqueue.

## 3. Verdict

The fix in 988abd1 is correct for the reported race and may ship as is.
APPROVED for the heartbeat race.

Required before the next QA round on the same theme: F1 (the `_setStatus`
guard, one line) because it reopens the same 0-byte final row through a
second Stop. F2 is a one-line reset in `start()` and should go in the same
commit. F3 is optional.
