# Longnote whole-codebase review (Fable), 16 Nov 2026

Branch `v1-build`, head `c00ea6d`. Read-only review before the next TestFlight build.
`flutter analyze`: no issues. `flutter test`: 209 passed.

Why: build 105 froze twice on the owner's iPhone (note-ready sheet after the first recording; Back while "Writing
summary"). The microtask livelock in NoteModel/NotesModel is fixed in c00ea6d (`CoalescingRunner`). This review looks
for the rest of that class and for anything else that can hurt a user on a real phone.

How it was done: I read `lib/core/**`, `app_services.dart`, `main.dart`, `ios/Runner/AppDelegate.swift`, `Info.plist`,
the pipeline tests and the runner test myself; two Opus reviewers covered the Supabase backend and the
`lib/features/**` + `lib/app/**` + `lib/ui/**` layer; I re-checked their money, auth and freeze findings in the code
before including them. Line numbers are from `cat -n` on c00ea6d.

Severity: **critical** = freeze/crash/data loss likely in normal use; **high** = likely in a common edge case or a real
money/abuse hole; **medium** = needs an unusual sequence or costs money/trust; **low** = worth a line in the backlog.

---

## A. App: freezes, crashes, stranded states (lib/core, services, iOS)

### A1. HIGH: the app can never open again if `AppServices.boot()` throws (black screen on every launch)
- `lib/main.dart:448` awaits `AppServices.boot()` before `runApp`. There is no try/catch and no fallback UI.
- `boot()` runs the DB migration (`lib/core/db/app_database.dart:329-352`), then recovery
  (`lib/core/recording/recovery_service.dart:372-379`): `recoverOne` does sync file I/O (`dir.listSync()`,
  `repairWav` with `openSync`/`truncateSync`/`writeFromSync`) for every recording left in `recording`/`paused`.
  A `FileSystemException` there (disk full when truncating/writing the header, a file iOS has locked, a permissions
  oddity) or a `DatabaseException` in the migration propagates out of `main()`.
- Scenario: the phone runs out of space during a long recording and the app is killed (A4 below makes that more
  likely). Next launch: recovery's first DB write (`repo.upsertSegment` :406/:412 or `repo.update` :433) fails with
  `SQLITE_FULL` (SQLite needs journal space even for a small update) -> `boot()` throws -> the launch screen stays
  forever. Every later launch does the same, because the row is still `recording`. The user cannot free space from
  inside the app (no UI) and must delete other apps. The crash reporter records it, but nothing uploads it (upload
  needs `boot()` to finish). A failed `onUpgrade` on a future schema bump has the same shape.
- Fix: wrap `boot()` in try/catch and `runApp` a minimal "Longnote could not start" screen with a retry and a
  "report" action; make `recoverAll` catch per recording (mark the row `interrupted` with `note = 'could not be
  repaired'` and continue); never let a diagnostics/migration failure block the UI thread's first frame.

### A2. HIGH: a crash or force-quit during a direct re-summary (D6) leaves the note on "Writing summary" forever
- `lib/features/note/summary_style_sheet.dart:84-99` calls `CloudPipeline.resummarize(id)` directly, **not through
  the job queue**. `resummarize` (`lib/core/cloud/cloud_pipeline.dart:459-464`) sets `processing_status = summarizing`
  and only sets `done` when it finishes.
- `ProcessingJobQueue.resetInterrupted()` (`lib/core/jobs/job_queue.dart:107-127`) only resets **jobs** in state
  `running`. A note whose status is `summarizing` with its job already `done` is never touched.
- Scenario: change the style on a cloud note (or tap "Make summary again"), app is killed within the ~10-20 s the call
  takes (iOS memory pressure, a crash like the ones in build 105, the user swiping it away). Next launch: the note shows
  "Writing summary" with a spinner, `needsAttention` is false (no Retry), and nothing will ever change it. Same if the
  sheet's `catch` at :90 is skipped because the process dies.
- Fix: route resummarize through the queue (a job kind "summary only"), or at start-up reset every recording whose
  `processing_status.inProgress` has no `pending`/`running` job to `failed` (error "Interrupted. Tap Retry") or
  re-enqueue it. Add the same guard after `jobs.resetInterrupted()`.

### A3. LOW: a 401 that persists makes a note fail after 4 tries with "Please reopen the app to sign in again" - and reopening does nothing
_(Low because the triggers are operator events: JWT secret rotation, project paused. Anonymous users are never deleted
server-side, see B-L9.)_
- `lib/core/cloud/longnote_api.dart:295-298`: on 401 the client calls `auth.invalidate()` once and retries. If the
  refresh succeeds but the function still returns 401 (user deleted server-side, JWT secret rotated, project paused),
  the second reply throws `ApiException('unauthorized')` -> `JobFailure` (retryable) -> 4 tries -> `failed` with the
  text "Please reopen the app to sign in again" (`api_error.dart:321-322`).
- `SupabaseAuth` only signs up a new user when GoTrue says the refresh token is dead (`supabase_auth.dart:536-552`).
  Reopening the app repeats the same refresh with the same result. Retry repeats the same 4 tries. The user is told to
  do something that cannot help.
- Fix: when the function layer answers 401 twice with a fresh token, treat the session as dead (sign up again and
  reset the piece's user id - the pipeline already handles a user change at `cloud_pipeline.dart:147-156`); change the
  message to something true ("Could not sign in to the service. We will try again.").

### A4. MEDIUM: `RecordingController.stop()` can get stuck in `stopping`; the Record button is then dead until restart
- `lib/core/recording/recording_controller.dart:282-330`. After `state = stopping`, every later await
  (`repo.upsertSegment` :305, `repo.updateCapture` :317, `analytics.log` is safe) is unguarded. On disk-full
  (`SQLITE_FULL`) or any `DatabaseException`, the method throws: `_source` is never disposed (mic stays open, orange
  dot on), `current`/`_sink` stay set, `state` stays `stopping`, `onFinished` is never called, and `isActive` is false
  so a second `stop()` returns null (`:283`). `start()` throws "already recording" (`:79`).
- Scenario: a 3-hour recording fills the phone (WAV is 115 MB/h); `_onAudio` catches ENOSPC and calls
  `_fail` -> `stop(reason: 'error')` -> `updateCapture` throws SQLITE_FULL -> stuck. The recording screen shows the
  banner and a Stop that does nothing; on the Notes screen every tap on the Record pill shows "Could not start
  recording. Please try again." (`notes_screen.dart:113-122`, `start()` throws "already recording"). Only a
  force-quit and relaunch (then A1 may hit) gets out.
- Fix: wrap the body in try/finally that always disposes the source, nulls `_sink`/`current`, sets `idle` and
  notifies; call `onFinished` best-effort; the row is recovered at next launch anyway.

### A5. MEDIUM: a request slower than the HTTP timeout is treated as "no network" and retried without limit
- `lib/core/cloud/api_error.dart:348-353` counts `TimeoutException` as a network error; `cloud_pipeline.dart:475-485`
  turns every network error into a `JobDeferral` (30 s, **does not use up a try**).
- `LongnoteApi.call` has a 90 s timeout (`longnote_api.dart:274`); `summarize` sends up to 100k characters and the
  server then runs OpenAI (measured 6.8 s for 51k chars - fine on Wi-Fi). On a slow mobile link (a 100 KB POST on 2G,
  an overloaded edge function) the call can exceed 90 s **after the server has already started billing**. Each
  deferral re-sends it: unbounded OpenAI spend (server cap aside) and a note that flips between "Waiting for internet"
  and "Writing summary" indefinitely. Same for `transcribe-start` (cheap) and TUS PATCH chunks (6 MB per 5-min
  timeout - fine).
- Fix: count consecutive network deferrals per job and fail (with Retry) after e.g. 20; raise the summarize timeout
  to 3 min; on the server, make summarize idempotent per (user, note, style, part) for a few minutes so a re-send
  returns the cached result.

### A6. MEDIUM: `_onRecordingFinished` can leave the queue paused for the rest of the session
- `lib/app_services.dart:375-380`: `jobs.resume()` runs only if `_afterRecording` (gate + `enqueue`) completes. If
  `enqueue` throws (DB full - the same scenario as A4), the queue stays `_paused`; every other note waits
  ("Waiting to start") until the app is restarted. `startRecording` (:391-406) has the same shape but does resume on
  error.
- Fix: `try { await _afterRecording(r); } finally { jobs.resume(); }`; same in `discardRecording` (:360-371).

### A7. MEDIUM: a note deleted while its job runs is partly recreated on disk
- `RecordingRepository.deleteByUser` (`recording_repository.dart:172-177`) removes the row (cascades jobs,
  pieces) and the folder while the pipeline may be inside `_encode`/`_upload`/`_saveTurns`.
  `_encode` recreates `<note>/cloud/` (`cloud_pipeline.dart:272`) and writes the m4a; `_saveTurns` fails on the FK
  (caught as "unexpected", harmless). Result: an orphan folder with a full-length m4a for a note the user deleted
  ("delete nothing" is a promise to the user in the other direction too: deleted audio should be gone).
- Also: `deleteSync(recursive: true)` of a 3-hour note (36 WAVs + m4a, ~400 MB) runs on the UI thread (:175) -
  a visible stall of a few hundred ms, not a kill.
- Fix: have the pipeline check `repo.get(id) != null` after each long step and before writing files; delete the
  folder with `Directory.delete` (async); sweep orphan folders at start-up.

### A8. MEDIUM: an exception inside a `CoalescingRunner` task drops the pending re-run
- `lib/core/util/coalescing_runner.dart:33-44`: if `task()` throws, `finally` clears `_running` but the `_again`
  request made during the run is forgotten and the error leaves the microtask as uncaught. For `NoteModel._load`
  a `DatabaseException` (e.g. query while a transaction holds the DB, disk full) means the screen keeps stale data
  until the next unrelated repo change. No freeze - the old bug is really fixed (verified the loop exits only via the
  awaited task) - but the UI can show "Transcribing" after the note is done.
- Fix: catch in `_run` (report via `CrashReporter.record`, keep `_again` semantics), or wrap `_load` bodies.

### A9. LOW: import copies a 2-3 GB video through an unbounded `IOSink` buffer
- `lib/features/import/import_controller.dart:216-245` reads with `openRead().listen` and calls `sink.add(chunk)`
  without honouring back-pressure. Reading from the picker's temp copy is usually faster than writing, so the
  difference accumulates in memory; on a big iPhone video this can be hundreds of MB and iOS jetsams the app
  ("import froze"). The picker itself already copies the file once into the app cache (double disk use).
- Fix: `await sink.addStream(from.openRead().map(progress))` (back-pressure for free), or `RandomAccessFile`
  chunks with awaits.

### A10. LOW: the first local notification parses the whole time-zone database on the UI thread
- `lib/core/billing/trial_reminder.dart:395-408`: `tzdata.initializeTimeZones()` (`latest_all`) runs synchronously
  (~100-300 ms on a phone) the first time any notification is shown or scheduled - including `showNow` for "Your note
  is ready" when the app is backgrounded. A hitch, not a hang. `latest_10y` or lazy init off the hot path.

### A11. LOW: crash reporter lists the diagnostics folder synchronously on every Flutter error
- `crash_reporter.dart:65-84`: `record()` is called from `FlutterError.onError`; a layout error that fires every frame
  (an overflow in a scrolling list) does `listSync()` + a sync write each frame until `maxPending` (40) is reached.
  Keep a counter in memory instead of listing the directory.

### Checked and sound (app)
- The livelock fix: `CoalescingRunner` loops only after the awaited task returns; `request()` during a run sets a flag
  and never schedules a microtask. The new test reproduces the old starvation. `NoteModel`/`NotesModel` both use it.
- The job queue: every `JobDeferral` wait is > 0 (5 s min; limits 15 min / next UTC day), backoff base 10 s, max
  4 tries, `runDue` is single-flight, `pokeAll` leaves `failed` (limit) jobs alone, network wake targets only
  `waitingForNetwork`. No path spins without an await on a timer or a DB reply.
- Crash-safe capture: WAV header rewritten at every flush (1 s), heartbeat 5 s, rotation every 5 min with the DB row
  written before data; recovery uses files on disk as truth and closes open gaps. `updateCapture` writes capture
  columns only. Stop is guarded against re-entry. Interruptions (calls) are marked as gaps, not lost.
- Mic session: `RecordPcmSource.stop()` now reconfigures to `.music()` and deactivates with
  `notifyOthersOnDeactivation`; errors there cannot lose audio. `AudioEncoderPlugin` runs on a detached task, calls
  `result` exactly once (`Once`), on the main queue. `FilesPlugin` is sync and safe. MetricKit subscriber writes
  atomically and dedupes by timestamp.
- Cloud pipeline resumability: every step is persisted in `cloud_pieces`; TUS resumes from the server offset; user
  change resets pieces; `not_found` re-uploads; `done` is saved in one transaction **before** ack; repeat `done` within
  15 min returns the result again (server verified). Local audio is never deleted by processing.
- Memory: 6 MB TUS chunks, transcript rows (a 3-hour note is a few thousand turns), waveform peaks and whisper run in
  isolates; PDF export runs on the UI isolate (a 3-hour transcript takes a second or two - a stall, acceptable).

---

## B. Backend (Supabase functions + migrations)

Identity and access are sound: `verify_jwt` on every user function, `requireUser` rejects the bare anon key, RLS on
`jobs`/`usage_daily` is read-own-rows only, the cost/IP/report tables are closed to clients, every SECURITY DEFINER
function pins `search_path` and revokes execute from `anon`/`authenticated`, storage policies anchor the path to
`<uid>/<note>.m4a`, `ack` is per-owner, the start/finalize claims are atomic. The webhook/cleanup secrets are compared
in constant time. No transcript text is logged or echoed.

### B1. HIGH: a few free anonymous accounts can use up the whole $20/day global cap and switch the service off for everyone
- `supabase/functions/_shared/common.ts:76-90`: per-user caps are **counts** (60 asks, 40 summaries, 8 h audio per
  day); the only dollar cap is `globalUsdPerDay = 20`, shared by all users and all three products.
- `ask` reserves ~$0.10 per call (240k chars + history + 4k output) and `summarize` ~$0.09 before the call. Anonymous
  sign-ups are free (10 per hour per IP per the API doc); the per-IP caps (300 summaries, 600 asks) allow ~$85/day
  from one IP.
- Scenario: 3-4 anonymous users from one IP send maximum-size asks with varying text (no prompt-cache hits).
  `cost_daily` hits $20 within minutes; every real user gets `global_day` on transcription, summary and ask until
  00:00 UTC. Money is capped; availability is not.
- Fix: separate global pools (audio vs LLM); cap users and IPs by dollars/tokens, not calls; App Attest (already on the
  open list) or a captcha on anonymous sign-up before any public build; alert when `global_day` trips.

### B2. MEDIUM: a restarted job keeps its old `created_at`, so cleanup can kill it or wipe its result
- `transcribe-start/index.ts:86-102` builds `fresh` without `created_at`; the restart paths (:119-134) and the plain
  "uploaded -> start" path (:117-118) never touch it. `cleanup/index.ts:39-52` treats a `transcribing` job older than
  30 min as stuck and **fails + deletes audio + refunds** at 6 h by `created_at`; the 7-day result clear and 30-day row
  delete in migration 00005 use `created_at` too.
- Scenario (common): a user hits the daily limit at 10:00 UTC; the row stays `uploaded`; the app waits until 00:02 UTC
  (`cloud_pipeline.dart:511-515`) and starts it: the row is 14 h old. If the hourly cleanup at :07 runs while Soniox is
  still transcribing (a 3-hour file takes minutes), the job is failed, the audio deleted, the minutes refunded; the
  phone re-uploads onto the same row and can hit it again. A row restarted after 7 days has its result cleared by the
  next 15-min cron before the phone fetches it.
- Fix: set a `started_at` on every successful start claim and use it for the 30-min/6-h/7-day timers.

### B3. MEDIUM: Soniox calls have no timeout; a lost reply leaves an unknown transcription behind and bills twice
- `_shared/soniox.ts:15-23` uses `fetch` with no `AbortSignal`. If the create call reaches Soniox but the function
  dies (150 s limit) or the reply is lost before the id is stored (`transcribe-start` :209-215), the start claim is
  released in the catch and the next start creates a second transcription. The first is never recorded: its webhook is
  ignored (unknown id), cleanup only deletes ids it knows, so audio and transcript stay at Soniox for 30 days - against
  the "deleted right after fetch" promise in BACKEND-API 6.
- Fix: `AbortSignal.timeout(30_000)`; in the webhook, resolve by `client_reference_id` or delete unknown
  transcriptions; before creating, list by `client_reference_id`.

### B4. MEDIUM: upload storage can be abused and the 24-h sweep can fall behind
- Bucket limit 500 MB per object (migration 00002), no per-user object count, type checked by declared content type
  only; cleanup removes at most **50** objects per hour (`BATCH = 50`, `cleanup/index.ts:12`), so even honest use by
  a few dozen users a day outruns the sweep and the "deleted after 24 h" promise slips.
- Fix: 100 MB object limit (5 h at 32 kbps is ~72 MB), a per-user object-count trigger, cleanup loops until empty.

### B5. MEDIUM: the new `report` function can be spammed and may receive user text
- `supabase/functions/report/index.ts:27-43`: the 50/day check (count) and the insert are two steps (parallel calls
  pass), there is no per-IP limit, bodies up to 260 KB are kept 30 days. One anonymous IP can write GBs/day.
- Privacy: `crash_reporter.dart:73` sends `error.toString()`. `FormatException` includes its source string and sqflite's
  `DatabaseException` includes the SQL and arguments of the failed statement - i.e. a failed `transcript_lines` insert
  would put transcript text in the report, contradicting the file's own promise ("never includes transcript").
  `launch/privacy-policy.md` and the App Store label do not mention crash data.
- Fix: one SQL step for count+insert; per-IP cap; drop `message` for `DatabaseException`/`FormatException` (keep the
  type and the stack); add "Crash data" to the policy and label. Also confirm migration 00006 is applied
  (BACKEND-API.md:373 lists only 00001-00005) - otherwise every report call is a `server_error` and the files pile up
  to `maxPending` on the phone.

### B6. MEDIUM: per-IP caps hash the exact IPv6 address and are charged on the client's claimed length
- `common.ts:182-198` hashes the full address; Jio and most Indian mobile users are on IPv6 with a /64 per device, so
  the IP caps (and GoTrue's sign-up limit) are trivially rotated. `transcribe-start:155-160` charges the IP
  `max(claimed, bytes/4000)` and never corrects it to the real duration (settle fixes user and global only).
- Fix: hash the /64 for IPv6; correct the IP counter at settle; read the real duration from the m4a header (`mvhd`).

### Low (backend)
- L1 `summarize`/`ask` reserve the IP count before the per-user check and never release it on `user_day` or
  `upstream_failed`; `transcribe-start` does release. Shared carrier IPs lose allowance.
- L2 `transcribe-status` can answer `done` with no result after the 7-day clear; the client treats a later `fetched`
  as "lost" and re-uploads. Return `fetched` once the result is gone.
- L3 Result cleared 15-30 min after the first fetch even without ack: if iOS suspends the app between fetch and
  `_saveTurns` (unlikely: both happen in one `_process` run) the piece is re-transcribed at full cost. Keep until ack
  or 24 h.
- L4 Cleanup refunds a job it failed to update (webhook finished it at the same moment).
- L5 OpenAI network errors are booked at $0 even when OpenAI billed.
- L6 Retried summaries re-run parts already done (`summarizeLong` has no per-part cache).
- L7 BACKEND-API understates reservations (~$0.055/$0.02 vs ~$0.09/$0.10).
- L8 Migrations 00001/00002 are not re-runnable (plain `create table`/`create policy`).
- L9 Anonymous users in `auth.users` are never deleted. L10 No index on `jobs.audio_path`.

---

## C. UI layer (lib/features, lib/app, lib/ui)

Reviewed by a second reader; I re-checked each high/medium item in the code. The two highs it found are the
same bugs as A2 and A4 above (listed once there). No UI listener writes back to the thing it listens to; no
`Timer.periodic`, no `while` on async state, no sync file I/O in `build`; the notes, transcript and search lists are
lazy; the note-ready sheet is asked once and only when its screen is on top and settled.

### C1. HIGH: "Transcribe on this phone instead" on an **imported** note produces a permanent, false "No speech was found"
- `lib/features/note/note_screen.dart:252-255` offers the button whenever the cloud run failed and the note is not
  already on-device; it does not check `n.source`. `NoteProcessor.transcribeOnPhoneInstead` pins the note to
  on-device; `ProcessingPipeline.process` (`lib/core/jobs/processing_pipeline.dart:22-24`) reads WAV segments only.
  An import has none -> empty transcript -> "No speech was found in this recording." saved as a *done* summary.
- The note is now pinned (`transcription_mode = on_device`) and no screen clears it; "Make a summary" repeats the
  same result. The user's imported lecture is stranded with a lie on it.
- Fix: hide the button for `source == 'imported'` (the architecture doc already says imports are cloud-only), and
  make `NoteProcessor.modeFor` force cloud for imports as a second guard.

### C2. MEDIUM: a deleted note can stay open as a ghost screen; the player sheet pops unguarded
- `note_screen.dart:147-155` `_leave()` pops only when the route `isCurrent`; a NoteScreen below another route is
  never closed. Path: Note -> Ask -> source chip (second NoteScreen) -> More -> Delete: the top one closes, the user
  lands on an Ask chat for a deleted note (sending still works; stores chat rows for nothing), Back shows the first
  NoteScreen with stale data, share/actions dead, player pointing at deleted files.
- `player_sheet.dart:38-41` calls `context.pop()` on **every** repository change once the note is gone, with no
  "already popped" flag: a second change during the dismiss animation pops the route under it (the owner's
  "Back pops the wrong screen" class).
- Fix: when gone and not current, `Navigator.of(context).removeRoute(ModalRoute.of(context)!)`; a `_popped` flag in
  PlayerSheet; AskView drops its note when it disappears.

### C3. MEDIUM: the note being recorded right now can be opened from Search and deleted under the recorder
- `core/notes/search.dart` does not filter live notes; `search_screen.dart:97-105` opens them; `note_actions_sheet.dart:84-97`
  `_delete` has no live-note guard and calls `deleteByUser`, which removes the folder synchronously while the
  `SegmentedWavSink` is writing into it. The recording pill keeps running; `_onAudio` then throws on the missing
  file -> `_fail` -> `stop` -> A4's unguarded path (`upsertSegment` on a deleted row succeeds, `updateCapture`
  updates 0 rows) -> `onFinished` enqueues a note that no longer exists and the free-recording counter is used up.
- Fix: exclude `status IN (recording, paused)` from search; disable Delete on live notes (point to Discard).

### C4. MEDIUM: a `failed` status hides a transcript and summary that already exist
- `note_screen.dart:236-239`: `failed` wins over `hasContent`. A 4-times-failed or `limit_reached` **summary** (a
  deferral with `status: failed`, `cloud_pipeline.dart:496-501`) hides the saved transcript, Share and Ask, and
  says "We couldn't make the transcript".
- Fix: with content present, show the normal screen plus a summary-error banner with Try again.

### C5. MEDIUM: Ask can be opened on a note that is not `done` and stays dead
- `note_screen.dart:300-301` enables Ask as soon as lines exist (e.g. during "Writing summary");
  `last_note.dart:24-31` returns it even if not askable; `ask_view.dart:109-111` disables the composer with no
  explanation, and `_onRepo` only refreshes when no note is picked, so it never comes alive.
- Fix: enable on `askable(note)` only; AskView re-reads its note on repository changes.

### C6. MEDIUM: "Make a summary" / style change re-run the whole pipeline under the current global setting
- `note_screen.dart:279`, `summary_style_sheet.dart:96-97` call `jobs.enqueue`; `NoteProcessor.modeFor` uses the
  note's override (null for normal recordings) else the global setting. A phone-transcribed note, Settings switched
  to cloud, then "Change style": the audio is uploaded and re-transcribed although the sheet says the transcript stays
  the same (privacy surprise). The reverse wipes a cloud transcript and the user's speaker names.
- Fix: pin `transcriptionMode` to `transcriptSource` before queuing, or add a summary-only job (also fixes A2).

### C7. MEDIUM: imported notes have no audio in the UI and the WAV export is silently empty
- `note_screen.dart:87`, `player_sheet.dart:44`, `share_sheet.dart:73,135-137`, `share_service.dart:87-91` all use
  recorded segments; imports have `importFile`. No mini player, "This note has no audio yet", and the Audio share row
  shares a 44-byte empty WAV with the note's title. Fix: play/export `importFile` for imports or hide the rows.

### C8. MEDIUM: on notes over 5 h, Change style runs on a partial transcript while the pipeline is still working
- `summary_style_sheet.dart:87-91`: piece 1's turns are saved before piece 2 is done, so the note looks ready;
  `resummarize` sets `done` while the job keeps running; status flips; Ask opens on half a lecture.
- Fix: disable style/summary actions while `processingStatus.inProgress`.

### Low (UI)
- L1 After a user Stop/Discard the screen briefly shows "Recording stopped... Everything up to now is saved" with
  "Open the note" (`recording_screen.dart:132-137`) because `stop()` notifies `idle` before `onFinished`; after
  Discard the text is false and a tap in that window can double-pop.
- L2 The recording screen rebuilds entirely (incl. an `IntrinsicHeight`) on every mic-level event, ~7/s
  (`recording_screen.dart:128,181-185`): battery cost over 3 hours, and not what the docs claim.
- L3 Ask reads services through the widget context after awaits (`ask_view.dart:88,125-126,191`); leaving the chat
  while an answer is pending throws an uncaught error that the crash reporter files as a crash.
- L4 Speaker merge disposes two text controllers before the rebuild that stops using them
  (`speakers_sheet.dart:103-106` vs `142-143`): a null `!` for one frame.
- L5 Import cancel is ignored once the copy finished (`import_controller.dart:166-198`); see also A9.
- L6 The Import tab re-reads all notes on every repository change without coalescing (`import_screen.dart:92-105`).
- L7 A note screen whose first load throws stays blank until an unrelated change (see A8).
- L8 Tapping the "note ready" notification does not open the note (no handler).
- L9 Onboarding `PageController` never disposed; benchmark screen `setState` after close.
- Dead code not reviewed: `home_screen.dart`, `detail_screen.dart`, `detail/playback_controller.dart` (unrouted).

---

## D. Verdict

**No critical findings.** The specific freeze class of build 105 (a microtask re-armed while its own reload is
awaited) is fixed and I found no other listener-feeds-itself loop, unbounded retry without a timer, or UI-thread
blocking work on a 3-hour note. The remaining app risks are **stranded states** (a note that can never leave
"Writing summary" or a dead Record button after a disk-full stop) and **one black-screen-at-launch path**; none of
them is a freeze that iOS would kill, but the owner would call each of them "the app is broken".

Must fix before the owner's TestFlight (small, mechanical, all in one evening):
1. A1 - `boot()` fallback screen + per-recording try/catch in recovery.
2. A2/C6 - re-summary through the queue (or a start-up reset of orphaned `summarizing`/in-progress notes).
3. A4/A6 - try/finally in `RecordingController.stop()`, `_onRecordingFinished`, `discardRecording`.
4. C1 - no "Transcribe on this phone" for imports.
5. C2 - ghost note screen + guarded PlayerSheet pop.
6. C3 - live note out of search / Delete disabled while recording.
7. C4 - failed status must not hide an existing transcript.

Should fix before anyone outside the owner gets a build (money and promises): B1 (dollar caps per user/IP and a
separate LLM pool, or App Attest), B2 (`started_at` for cleanup timers), B3 (Soniox timeout + unknown-transcription
delete), B5 (report rate limit; strip SQL args/FormatException text; privacy policy line), A5 (cap network
deferrals per job), B4 (cleanup batch 50 -> loop).

Everything else can wait for the next round.

Verdict: **safe to ship to the owner's TestFlight once items 1-7 are fixed and the existing test suite plus the
device list in docs/DEVICE-TEST-V1.md pass**, with a disk-full recording and a style change followed by a force-quit
added to that device list. It is **not** yet safe for a public or external-tester build until the backend "should
fix" list is done.
