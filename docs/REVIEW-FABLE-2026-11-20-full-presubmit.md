# Fable review, 20 Nov 2026 (evening): full pre-submission review

Scope: branch `v1-build` at HEAD `487708b`, read-only (this file is the only write). Diff `5385e6c..HEAD` (7 commits) read
line by line; whole-app pass on billing / StorePlugin / PaywallGate / paywall copy / analytics privacy / recording /
jobs / cloud pipeline / Supabase functions, migrations and RLS; the 20 Nov store-readiness items re-checked at HEAD.
No App Store Connect or Supabase management call, no push, no secret read or printed. The untracked `launch/` folder
was only read. The live site was fetched with curl (public pages + JS bundle) to see whether B2/S7 are live.

## Verdict: APPROVED for TestFlight / submission, with four items to clear before "Submit to App Review"

No Critical finding. Four Major: the published website is still the old text (repo sources are fixed, the site is
not); one Supabase secret worth setting; a 3-line ordering fix in `discardRecording` (today's diff opened a race that
can spend the free recording on a discarded note); and one processing-screen sentence that promises background work
the app cannot do. The first two are owner/ops steps; the last two are small code/copy changes that fit in the same
build. Everything else is Minor and can ship.

## Test runs (this commit)

| Check | Result |
|---|---|
| `flutter analyze --no-pub` | No issues found |
| `flutter test` | **283 passed, 0 failed** (53 s) |
| `deno test --allow-env --allow-read supabase/functions/_shared/` | **37 passed, 0 failed** (deno 2.9.7) |
| `deno check supabase/functions/*/index.ts` | 8 of 9 clean; `transcribe-status/index.ts` fails with 27 x TS2339 on the job row (`GenericStringError`). Typing artefact only, pre-existing, not in this diff: `COLS` is built with `+` so postgrest-js cannot parse the select string; at runtime the same columns come back. See m12. |

## Major

### M1. The published website still carries the text B2/S7 removed (5.1.1 / 2.3 risk until re-published)
- Repo sources are fixed (`docs/store/website/privacy.md`, `support.md`, `FIGMA-MAKE-PRIVACY-UPDATE.txt`, commit
  `e0cbe4a`): no "Settings > Account > Delete account", Support ID path = Settings > What happens to your audio,
  dated 20 Nov 2026.
- The live site is not: `https://novaralabs.in/longnote/privacy|support|terms` all serve the 1,158-byte shell titled
  `Figma Make App`; its bundle `assets/index-Bt7Gx3RG.js` (813 KB, fetched 20 Nov evening) still contains
  "Settings > Account > Delete account" (x2), "Delete account" (x2), "Effective date: June 4, 2026" (x2),
  "Last updated: November 19, 2026", "Support ID shown in Settings > Privacy"; it does not contain "What happens to
  your audio", "has no accounts" or "20 November 2026".
- Failure scenario: the reviewer opens the Privacy Policy URL from the ASC form, reads "Settings > Account > Delete
  account", looks for it in the app, finds no account screen, and files 5.1.1(v) or a metadata mismatch.
- Fix: owner step A.2 in `docs/SUBMISSION-EVENING-2026-11-20.md` (paste the two texts into Figma Make, set the page
  title, remove the June 4 date), then re-run the curl check above before "Add for Review". This is a precondition
  for submission, not a code change.

### M2. Per-IP LLM cap above the global LLM pool: set the secret, no code change
- `supabase/functions/_shared/common.ts:89,101`: `globalLlmUsdPerDay` 8, `ipLlmUsdPerDay` 10, `userLlmUsdPerDay` 3.
  The per-IP dollar cap can never bind for LLM; the global pool trips first. Money exposure is unchanged ($8/day), so
  this is availability, not cost: three anonymous accounts from one IP (anon sign-ups are free) can spend 3 x $3 and
  switch summaries + Ask off for every paying user until 00:00 UTC. Audio is similar (72 h x ~$0.10 = $7.20 of the
  $12 pool).
- Judgement: acceptable for the first days (documented in BACKEND-API.md 369-371 as the App Attest trade-off), but it
  is a one-line secret: set `LIMIT_IP_LLM_USD_PER_DAY=4` and `LIMIT_IP_AUDIO_SECONDS_PER_DAY=129600` (36 h) so a
  single network can take at most half a pool. Also add the 70% alert on the global caps that S1 asked for (still
  absent; the day a cap trips, every user reads "The service is busy today").

### M3. `discardRecording` now logs before it marks the discard: a Stop in that window spends the free recording (today's diff)
- `lib/app_services.dart:594-597`: the new `await analytics.log(recordingDiscarded, ...)` runs before
  `_discarding = id` and `recorder.stop()`. `Analytics.log` (`analytics.dart:212-232`) never throws but has no
  timeout: it waits in the sqflite queue (behind e.g. a `_saveTurns` transaction of a long transcript,
  `cloud_pipeline.dart:403-440`) and then awaits `_amp.track` over the method channel. The 17 Nov heartbeat-race fix
  relied on `_discarding` being set synchronously; the team already treats this await as a hang risk
  (`setShareAnalytics` wraps the same call in a 2 s timeout, `app_services.dart:173-175`).
- Scenario: the user confirms Discard; the log stalls; the recording screen's Stop button is still enabled
  (`recording_screen.dart:566` disables only on `stopping`); a Stop tap (or a self-stop: heartbeat, interruption,
  part-rotation failure) reaches `_onRecordingFinished` with `_discarding == null`, which counts the recording against
  the one free allowance (`paywall_gate.dart:37`) and enqueues it; the discard then resumes and deletes the note under
  the queued job. The user's single free recording is gone on a note they threw away. If the log hangs outright the
  mic stays open.
- Fix (3 lines): read `elapsed` first, set `_discarding = id`, `await recorder.stop(...)`, then
  `unawaited(analytics.log(...))` (or `.timeout(const Duration(seconds: 2))`). Add a test: a stop during the discard
  must not call `gate.onRecordingFinished`.

### M4. The processing screen promises "close the app. We'll tell you when the note is ready"; nothing runs once the app is closed
- `lib/features/note/processing_view.dart:103`: "You can leave this screen or close the app. We'll tell you when the
  note is ready." `Info.plist` has `UIBackgroundModes = audio` only; `pcm_source.dart:100-105` deactivates the audio
  session at Stop, so that mode no longer keeps the app alive; `ios/Runner/*.swift` has no `beginBackgroundTask` /
  background `URLSession` (grep). The upload/poll job is suspended seconds after backgrounding, the in-flight HTTP dies
  into a `JobDeferral` (`cloud_pipeline.dart:483-497`) and resumes only on `pokeAll` at the next foreground
  (`app_services.dart:527-530`); `_LocalNoteReadyNotifier` (`app_services.dart:659-677`) fires only while the app is
  still running. `docs/APP-ARCHITECTURE.md:136` states the real behaviour ("if the app is in the background").
- Scenario: a first user's one free 2-hour recording; they stop, read this line, swipe the app away; nothing happens
  until they reopen it; no notification ever arrives. It is the first thing a new user is told after their first
  recording, and it is not true.
- Fix: copy, this build: "You can leave this screen. If you close Longnote, the note finishes the next time you open
  it." Later: `beginBackgroundTask` around the upload (about 30 s) or a background `URLSession`.

## Minor

### Today's diff

- **m1. Awaited analytics inside `RecordingController.start()`** — `lib/core/recording/recording_controller.dart:182`:
  `await analytics.log(recordingStarted)` sits between `state = recording` and `notifyListeners()/return`, so a hung
  sink strands `startRecording()` (mic recording, screen stuck in `_starting`). Pre-existing, same cause as M3; make it
  `unawaited(...)` or give `Analytics.log` a short timeout.
- **m2. Awaited analytics in `RecordingController.pause()/resume()`** — `lib/core/recording/recording_controller.dart:275,286`.
  Harmless today (the status change is already done and notified, and the screen calls `c.pause()` / `c.resume()`
  unawaited, `recording_screen.dart:75-87`), but make both `unawaited(...)` so the controller's futures stay about
  capture only.
- **m2b. Import: a failure after `repo.insert` deletes the audio but keeps the note row** —
  `lib/features/import/import_controller.dart:189-212`: the row is inserted at 189, then `gate.onRecordingFinished`
  (a kv write, added today), `jobs.enqueue`, `noteQueuedByUser` run inside the same `try`; both catches (214, 224)
  `_cleanup(dir)` and `_fail(job)` but never remove the row. A `DatabaseException` there (not a `FileSystemException`)
  leaves a completed "imported" note with `importFile` pointing at nothing and `processing_status none`, which
  `resetInterrupted` (`job_queue.dart:128-141`) never queues. Low likelihood (a DB write must fail right after a
  successful insert); cheap fix: on any failure after the insert call `repo.deleteByUser(id)` instead of
  `_cleanup(dir)`, or insert the row last. The gate-before-enqueue order itself matches `_afterRecording`.
- **m3. `summary_style_changed` and `setting_changed` for one action** — `lib/features/note/summary_style_sheet.dart:70-73`.
  Changing the default style in Settings logs two events; onboarding and the note sheet log only
  `summary_style_changed`. Keep one (drop the `setting_changed` here, or document the pair in ANALYTICS.md) so the
  "settings changed" count is not inflated by one path.
- **m4. "Try again" is a dead end for `too_long`** — `lib/features/note/processing_view.dart:240-241,283`. The new
  title "Longer than 5 hours" is right, but the primary button is still "Try again", which re-queues a job that
  `transcribe-start` rejects every time (`too_long`, non-retryable in `cloud_pipeline.dart`). Hide "Try again" when
  `tooLong` and lead with "Transcribe on this phone instead" (when `canUsePhone`), or say "Cloud transcription stops
  at 5 hours" under the button. Also: nothing stops or warns the recorder at 5 h; a 6-hour recording is transcribed
  nowhere in the cloud. The copy now says "up to 5 hours ... is transcribed", which is honest, so this is UX, not 3.1.2.
- **m5. `delete_data_confirmed` is defined and listed but never fired** — `lib/core/analytics/analytics.dart:104`,
  `docs/ANALYTICS.md:77` says "reserved". Fine, but the privacy label / policy must not list a "delete my data"
  action the app does not have. No change needed; noted so nobody reads it as implemented.
- **m6. `import_failed` for a user cancel** — `import_controller.dart:103-111` logs `error: cancelled` under
  `import_failed`. A cancel is not a failure; either a separate `import_cancelled` or document it, or every failure
  rate on this event is wrong by the cancel share.
- **m7. Rate button before launch** — `settings_home_screen.dart:135-141`, `links.dart:24-26`. Opens
  `apps.apple.com/app/id6835017154?action=write-review`, which shows "not available" until the app is live (the
  submission doc says so). If App Review taps it they see an App Store error page. Acceptable; if you want zero risk,
  fall back to `External.requestReview()` when the store page fails, or hide Rate until `appStoreLive` (a define).
- **m8. In-app transcript-retention sentence vs server** — `lib/features/settings/privacy_screen.dart:38`: "The
  transcript is sent to your phone and deleted from our server within 24 hours." Server: deleted on ack, 24 h after
  fetch, **7 days if never fetched** (`migrations/20261116000007...sql:404-407`, `cleanup/index.ts:3`); the published
  policy says exactly that. Say "within 24 hours of reaching your phone (7 days if your phone never collects it)".
  Not a review risk (the policy is correct); a wording fix.

### Whole-app pass (pre-existing, none a blocker)

- **m9. Subscription state has no ordering guard (server, analytics only)** — `_shared/appstore_events.ts:212-250`,
  `appstore-notifications/index.ts:182-187` upsert `subscriptions` unconditionally; `last_signed_date` is stored but
  never compared, so an Apple retry (our 500 -> resend 1 h later) can overwrite newer status with older. Nothing
  reads `subscriptions` for entitlement (StoreKit 2 on the device is the only source; `lib/` has no `.from(` /
  `.rpc(`), so it is reporting only. Fix: skip the `subscriptions` write when `prior.last_signed_date > n.signedDate`.
- **m10. Reservation kept when the server fails between reserve and the Soniox call** — `transcribe-start/index.ts:206-213`:
  if `createSignedUrl` or the DB update throws after `ln_reserve_audio_v2`, the catch clears the claim but
  `charged_at` stays, so the user's day quota and the audio pool hold the reservation until retry or 00:00 UTC.
  Fix: in the catch, `if (!started) await db.rpc("ln_refund_audio", { p_job: jobId })`.
- **m11. Storage sweep keys on `created_at`, which an upsert keeps** — `0001:226-232` `ln_old_objects`,
  `cleanup/index.ts:36`. A path first uploaded >23 h ago and re-uploaded now can be swept while Soniox is queued.
  Rare; one line: `coalesce(o.updated_at, o.created_at)`. Also the sweep runs at :07 with a 24 h threshold, so audio
  can live ~25 h against "within 24 hours"; `p_hours: 23` closes it.
- **m12. `deno check` fails on `transcribe-status`** — `transcribe-status/index.ts:17-18` builds `COLS` with `+`, so
  its type is `string` and postgrest-js types the row as `GenericStringError` (all 27 errors). Runtime is fine (the
  same column list reaches PostgREST). Fix: one literal string, or `.select(COLS).returns<JobRow>()`. Then put
  `deno check supabase/functions/*/index.ts` in CI next to the tests.
- **m13. Soniox's own "too long" lands as `upstream_failed`** — `transcribe-start:44-47,86-89` catch honest clients;
  a file under the byte floor x1.05 but over 300 min fails at Soniox and `finalizeJob` (`soniox.ts:255-265`) writes
  `upstream_failed`, so the app says "upload again to retry" (a loop). Map Soniox's duration error to `too_long`.
- **m14. `npm:@supabase/supabase-js@2` unpinned** — `common.ts:5`; the deploy resolves latest. Pin a minor.
- **m15. Webhook `id` interpolated into the Soniox URL unvalidated** — `soniox-webhook/index.ts:24,34` -> `soniox.ts:84`.
  Reachable only with the shared secret; add `/^[A-Za-z0-9_-]{1,128}$/`.
- **m16. Doc drift** — `docs/BACKEND-API.md:269` says 60 asks/day (code: 200); `launch/privacy-policy.md:68` says
  failed audio "within 7 days" (server: 24 h; stricter, harmless); `launch/app-store-listing.md:262,285` review
  notes still say "Settings > Transcription & privacy" and "three intro screens" (N1; the submission doc says the
  notes are updated after build 118 is attached: do it).
- **m17. The "Advanced" screen (N2) still ships** — `lib/features/settings/settings_screen.dart`: Material-styled
  v0.1 settings (summary engine, whisper downloads, usage log) reachable from Settings. The version line is now
  dynamic (good) and the 7-tap benchmark is gated; the screen itself still looks like another app. Not a rule
  violation; a polish item for 1.0.1 or put it behind `AppConfig.devTools`.
- **m18. Re-transcribing a fetched note resets `charged_*` without a refund** — `transcribe-start/index.ts:122-128`.
  Correct for the day cap, but the earlier seconds drop out of the rolling-hour sum, so the 6 h/h cap can be
  exceeded by re-running fetched notes. The 16 h day cap still binds. Leave it.

### Recording / jobs / cloud pipeline (pre-existing)

- **m19. App killed mid-import leaves the partial copy forever** — `import_controller.dart:170-178` writes
  `<recordings>/<uuid>/import.<ext>.part` before any DB row exists; `RecoveryService.recoverAll`
  (`recovery_service.dart:350-352`) looks only at rows in recording/paused and `deleteByUser` needs a row, so a 3 GB
  video killed at 90% is 2.7 GB nobody can free. Fix: at boot, for dirs under `recordingsRoot` with no `recordings` row,
  delete `*.part` files only (keeps the "only `deleteByUser` deletes audio" rule).
- **m20. A TUS PATCH timeout consumes a try** — `tus_uploader.dart:22,109` (5 min per 6 MB chunk, a ~21 KB/s floor)
  becomes `JobFailure('timeout')` via `_translate` (`cloud_pipeline.dart:488-490`); 4 tries then "failed" on a slow
  link. The billing rationale in the comment is about edge functions, not storage. Wrap TUS timeouts as `JobDeferral`.
- **m21. TUS has no 401 refresh and maps the 25-object cap wrongly** — `tus_uploader.dart:76-79,129-141`: a 401 is a
  used try (unlike `LongnoteApi.call`, `longnote_api.dart:298-307`); the cap is HTTP 400 per `BACKEND-API.md:47` but
  only create-403 maps to `upload_refused`, so a 400 becomes `bad_request` -> `retryable: false` = permanent. Treat
  create 400/403 as `upload_refused`.
- **m22. `upload_refused` says "We will try again" but is final after 4 tries** — `api_error.dart:41`,
  `cloud_pipeline.dart:504-514`. Make it a `JobDeferral` like `limit_reached`.
- **m23. `too_long` has no exit for an import** — `planPieces` splits only when the client duration > 5 h
  (`piece_planner.dart`); a VBR mp3 the probe under-reads by > 5% gets one piece, the server says `too_long`
  (bytes floor), "Try again" (`note_screen.dart:276`) re-runs the same plan (`_start` keeps `uploaded`,
  `cloud_pipeline.dart:390-397`) and fails again; imports have no on-phone path (`note_screen.dart:273`). Fix: on
  `too_long`, `pieces.deleteAll` and re-plan from the server's `audioMs` into 4 h pieces. Related to m4.
- **m24. No interruption-ended handling** — iOS omits the ended event in some call flows; the recorder stays `paused`
  with an open gap until the user taps Resume while the screen says "resumes on its own"
  (`recording_screen.dart:320`). `PcmSource.pausedChanges()` (`pcm_source.dart:123`) is never listened to and could
  detect the native resume. State stays consistent (native recorder paused too), so no audio is mislabelled.
- **m25. Comment drift** — `longnote_api.dart:215` "repeats within 15 min" vs the server's 24 h
  (`transcribe-status/index.ts:2-3`). `pcm_source.dart:35` still says NOT DEVICE-TESTED for interruption/route change.

**Recording and pipeline: checked and OK**
- 17 Nov heartbeat-race fixes hold: heartbeat guard `recording_controller.dart:257`, `_setStatus` guard `:294`, `began`
  closes a gap if Stop ran `:318-324`, `_intSub` cancelled before `_source.stop()` `:384-387`, F2 resets `:104-106`,
  F3 full teardown in `start()` catch `:185-212`; tests at `recording_controller_test.dart:191,218,251`.
- Stop waits for the flush before enqueueing: `_source.stop()` -> `_audioSub.cancel()` -> `sink.close()` (sync header
  + fsync + close, `wav.dart:432-444`) -> final segment row -> `updateCapture(completed)` -> `onFinished` -> `enqueue`
  (`recording_controller.dart:387-446`). No path found that loses audio already written.
- Low disk: ENOSPC in `add`/`flush` -> `_fail` -> `stop(reason: 'error')`; header sizes written at the last flush
  (<= 1 s loss); a failed rotation leaves a 0-byte final row filtered by `dataBytes > 0`; a failed stop frees the mic
  and defers to recovery.
- Kill while recording: files are the source of truth (`recovery_service.dart:379-386`); `repairWav` rewrites RIFF/data
  sizes, truncates a partial sample, handles < 44-byte files (`wav.dart:350-389`); open gaps closed at the last
  heartbeat; status `interrupted` then `_afterRecording` enqueues; runs before any capture.
- Interruption / route: `audio_session` began/ended -> gap + paused/recording; `record` 7.2.0 `pauseResume` +
  `AudioRouteChangeMode.follow` (`pcm_source.dart:79-82`).
- 5+ h: 5-min / 9.6 MB parts; exact `durationMs` from bytes; > 5 h -> 4 h pieces stitched by `startMs`
  (`piece_planner.dart`, test `cloud_pipeline_test.dart:270`).
- Job queue: one job at a time (`_running`, `job_queue.dart:224-248`); backoff 10 s x 2^n capped 10 min, 4 tries;
  `JobDeferral` does not consume tries; `limit_reached` defers until 00:02 UTC / 15 min and is excluded from
  `pokeAll`; manual Retry resets tries; no automatic infinite loop on permanent errors.
- Network loss mid-upload: upload URL persisted at create, HEAD resume, 409 re-sync, `TusExpired` -> one re-create
  (test `tus_uploader_test:198`); offline -> deferral woken by connectivity.
- Auth: refresh only on dead-token codes (`supabase_auth.dart:579-595,612-626`); outages never swap the user; a new
  anonymous user resets pieces and re-uploads the kept local m4a (tests `cloud_pipeline_test:396,456`); entitlement is
  StoreKit-local so session loss costs no access.
- Upload idempotency: `x-upsert: true` + `<user>/<clientId>.m4a`; `transcribe-start` idempotent on `client_note_id`.
- Fetch/save/ack: `_saveTurns` is one transaction including `transcribed=1`; the server returns `done` + result until
  ack, so a crash between fetch and save re-fetches without re-upload; crash after save before ack -> piece skipped,
  server sweeps in 24 h. Encoder failure -> `encode_failed`, inputs untouched.
- Import cancel: checked after copy and after probe; dir cleaned.

## Store-readiness items (20 Nov morning) at HEAD

| Item | State at HEAD |
|---|---|
| B1 dev screen in release | FIXED. `AppConfig.devTools = kDebugMode \|\| LN_DEV` (`config.dart:14-15`); `router.dart:300-312` wraps `benchmark` + `gallery`; both 7-tap handlers return early (`settings_home_screen.dart:116`, `settings_screen.dart:205`); `useFakeTranscriber` reads false outside dev (`app_services.dart:451-452`). No workflow passes `LN_DEV` (`.github/workflows/*`). `BenchmarkScreen` has no other entry (`grep`). |
| B2 "Delete account" in policy/support | FIXED in sources; **NOT LIVE** (M1). |
| S1 server limits | DONE (`common.ts:82-103`: 16 h/day, 6 h/h, user LLM $3, ask 200, summary 100, IP 72 h / $10 / 600 / 1500). See M2 for the IP-vs-pool shape and the missing alert. |
| S2 "no time limit" copy | DONE. Onboarding `length`/`hours`/`ready` (`onboarding_screen.dart:194,211,242`), paywall feature grid + FAQ `length` (`paywall_more.dart:80,197`), headline `Keep recording, for hours at a time.` (`paywall_screen.dart:257`), `too_long` message (`api_error.dart:50-51`) and failed card title (`processing_view.dart:263`). Website sources still say nothing about a limit (the policy does not need to). |
| S3 Import behind the paywall | DONE. `importPaywallPassed` before the picker (`import_screen.dart:114`) and again at Start (`import_details_sheet.dart:95`); the import counts via `gate.onRecordingFinished` (`import_controller.dart:205-206`, under 30 s does not count, same as recording); placement `import` in the route (`router.dart:81-90`); covered by `app_flow_test.dart` "Import is behind the paywall". The server still has no entitlement check (anonymous users), as before. |
| S4 trial guard | DONE. `trial = trialEligible && plan.trialDays > 0` (`paywall_screen.dart:212-213`) feeds the headline, `_Timeline`, the button label, `priceLine`, `PaywallMore(trial:)` (FAQ `cancel` swaps to the no-trial answer, `_HonestBilling` swaps its sentence); the trial-started screen is reached only on Apple's `startedTrial` answer. Before store products load (or offline) the hard-coded fallback plans carry `trialDays: 3` (`billing_service.dart:19`, `config.dart:50`), so the trial copy can show briefly; the purchase then fails honestly ("Can't reach the App Store"). |
| S5 iPhone-only | DONE. `TARGETED_DEVICE_FAMILY = 1` in Debug/Profile/Release (`project.pbxproj:367,493,546`); iPad orientation list removed from `Info.plist`. |
| S6 privacy label / ATT | Owner/ASC task; the plan in `SUBMISSION-EVENING-2026-11-20.md` B.3 matches the build (no IDFA, no ATT, Meta ATE=false, server-side money events). Known residual risk, accepted 18 Nov. |
| S7 site shell | **OPEN** (M1): title still `Figma Make App`, June 4 date still present. |
| N1 review notes | OPEN (m16). |
| N2 Advanced screen | Version line fixed (`PackageInfo`, `settings_screen.dart:38-44`); screen remains (m17). |
| N3 stale comments | FIXED (`Info.plist:33-38`, `amplitude_sink.dart:17-20`). |
| N4 suffix currency | FIXED (`trial_copy.dart:43-57`: "5 € / mo"). |
| N5 sample marker | FIXED ("Sample · " on both demo cards, `onboarding_visuals.dart:218,360`). |
| N6 transcript "then deleted" | Changed to "within 24 hours"; see m8 for the 7-day case. |

## Checked and OK

**Diff 5385e6c..HEAD**
- `ScreenViewTracker` (`lib/app/screen_tracker.dart`): listens on `routerDelegate`, reads `router.state.topRoute?.name`
  (go_router 17.5.0: `GoRouter.state` -> `routerDelegate.state` -> `currentConfiguration.last.buildState`), guards the
  empty match list, dedupes same-name changes, never throws into the delegate; created in `initState` before the first
  frame and re-created on `didUpdateWidget`, disposed with the app (`main.dart:159-182`). The first `_onChange()` sees
  an empty configuration and logs nothing; the first real route is logged on the delegate's first notify. Covered by
  `analytics_events_test.dart` "tabs, pushes, sheets and pops; no duplicates".
- Analytics privacy: every new `log` call's props were read. Values are codes only: route names, product ids,
  placements, `result`/`how`/`from` enums, `duration_s`, `count`, `chars_bucket`, `opened`, booleans, language codes
  (`audio_language_screen.dart:120-126` maps a summary-language *name* back to its code or `other`), style ids, mode
  names, `kind`/`format` (extension from a picker restricted to `importExtensions` or Photos video; never the file
  name), `error` codes. No title, text, question, answer, speaker name or file name anywhere. `remoteSafeProps`
  (`remote_analytics.dart:68-85`) still drops denylisted keys and turns any non-token string into `other`;
  `recording_id` (a UUID) is forwarded as before. `remote_analytics_test.dart` / `analytics_test.dart` list all 47
  events.
- Double logging: `paywall_closed` guarded by `_closed` (own closes set it before `pop`; `PopScope` logs `system_back`
  only when `didPop && !_closed`; `goNamed` on first run does not invoke `onPopInvoked`); `paywall_plan_selected`
  only on a change; `notification_permission` once per answer on all four ask sites (`trial_started` allow/skip,
  `plan`, `note_ready`); `mic_permission` once per attempt (onboarding) and only on the denied path at Record;
  `search_used` once per visit in `dispose` (`_s` is `late final` and already initialised because a search ran);
  `playback_started` once per `NotePlayback` instance (`_started` flag) on both the note screen and the player sheet;
  `share_analytics_off` is sent before the switch flips and `setting_changed on` after it (tested).
- Mounted / context use after awaits: `import_screen._pick` (mounted after pick), `importPaywallPassed`
  (`context.mounted` after `canImport`), `import_details_sheet._start` (`|| !mounted`), `ask_view` (`_s` assigned in
  `initState`), `speakers_sheet`, `summary_style_sheet`, `note_actions_sheet` (captures `s` before `pop`),
  `recording_screen` (`late final _s`), `audio_language_screen`, `transcription_screen`, `trial_started_screen`,
  `plan_screen._turnOn` (local `s`), `onboarding._askMic` (`if (!mounted) return` before the log). `openOrExplain`
  checks `context.mounted` after the launch (`external.dart:45-54`).
- Import gate: both entry points (`_pick` from the buttons and the Voice Memos help sheet) and the Start button go
  through `importPaywallPassed`; `canImport` = `canStartRecording` (refreshes StoreKit past the paid-through date);
  the paywall route has `parentNavigatorKey: rootNavigatorKey` so it opens above the sheet; a `true` result continues,
  anything else (`null` from `NavGuard`) stops. The count happens after `repo.insert` and before `enqueue`.
- Dev tools: `kDebugMode` is false in TestFlight/App Store archives; `bool.fromEnvironment('LN_DEV')` is a const
  define no workflow sets.
- Server defaults (`common.ts`): global pools unchanged; per-user/per-IP raised; tests pass.
- Website sources: the three pages and the Figma Make instructions carry the agreed text (no accounts, Support ID
  path, 20 Nov date, remove the June 4 line).
- Copy vs behaviour (3.1.2): product name "Longnote Pro · auto-renewing subscription", both plans with store price and
  period, yearly preselected, Save %, real dates (today / reminder 26 h before / charge), price line with the exact
  charge date or "charged today", Restore / Terms / Privacy, immediate Close. All trial sentences now depend on the
  store's intro offer (S4). "Up to 5 hours", "9 summary styles" (9 values), "60+ languages" (62 + auto + Hinglish),
  "a day before" (26 h reminder), "Audio saved on your phone as you record" (5-minute WAV parts, 1 s fsync) are true
  of the build.

**Billing (whole app)**
- `StorePlugin` (`AppDelegate.swift`): `Transaction.updates` listened from the first Dart call, verified transactions
  finished and `changed` sent to Dart; `purchase` finishes the verified transaction before returning `status()`;
  `.userCancelled` -> `cancelled`, `.pending` (Ask to Buy / SCA) -> `pending` and the later update unlocks via
  `changed` -> `refresh` -> the paywall's entitlement listener (`_buying` is reset on a non-success); `.unverified`
  is reported, not trusted; `status()` picks the longest-running verified auto-renewable with `revocationDate == nil`
  (refunds/revocations drop out and arrive through `updates`); `restore` = `AppStore.sync()` + `status()`, errors ->
  `store_error` -> Dart distinguishes "could not reach" from "no purchase". `appAccountToken` only when a valid UUID.
- `StoreKitBillingService`: entitlement cached in KV for a fast unlocked launch, re-read with a 5 s timeout, refreshed
  on resume / `changed` / past `renewsAt` before a gate decision (`app_services.dart:626-633`); `trialEligible` from
  the products' `isEligibleForIntroOffer` and forced false while active; purchase outcome enum added without changing
  behaviour; "took the purchase but isn't active yet" message still points at Restore.
- `PaywallGate`: one free recording >= 30 s, counted on finish (recording or import) only when not entitled;
  `canStart` = active OR free unused; reset only from the dev-gated benchmark screen.
- Analytics money events: `logPurchase` (`trial_started` / `subscription_purchased`, `source: app`, no revenue) with a
  2 s timeout; revenue only server-side from Apple notifications; `restore_tapped` / `restore_result` in
  `restorePurchases`.

**Backend (Supabase)**
- Auth: every user function uses `requireUser` (anonymous allowed by design); `verify_jwt` on for all user functions,
  off only for the three machine-called ones (`config.toml`); service role only inside functions. Webhooks: Soniox
  constant-time secret compare; cleanup constant-time secret; Apple JWS full x5c chain to the embedded Root CA G3,
  WWDR/receipt OIDs, ES256, inner JWS verified, bundle id + environment + `appAppleId` checks.
- Replay/idempotency: `ln_appstore_claim` single atomic insert-or-reclaim; `planned` resends the stored plan only;
  Amplitude/Meta `send()` idempotent by insert_id/event_id.
- Money: `ln_reserve_llm` / `ln_reserve_audio_v2` check and charge under row locks in one lock order
  (jobs -> usage_daily -> ip_daily -> cost_daily); settle and refund idempotent, balances `greatest(0, ...)`; OpenAI
  settled exactly once in `finally`; Soniox refusal refunds; 3rd failure deletes and refunds.
- Job state machine: start claim (3 min) and finalize claim (5 min) make both sides single-writer; the row exists
  before Soniox is called so an early webhook resolves; duplicate webhooks hit the status check or the claim; lost
  webhook covered by status poll + cleanup (30 min pull, 6 h fail + refund); `too_long` pre-upload at 300 min.
- Cleanup covers every text-holding table (`jobs.result`, `summary_cache`, `client_reports`, `appstore_notifications`;
  `ask` stores nothing) and audio (finalize, hourly sweep, Soniox copies, orphans).
- RLS: all 10 tables RLS on; `jobs`/`usage_daily` select-own; `tracking_profiles` own-row; the other 7 revoked from
  anon/authenticated; storage policies restrict all verbs to `<auth.uid()>/` with a strict name regex; `ln_*`
  SECURITY DEFINER revoked except `ln_upload_count`. `report`: kind whitelist, 260 KB cap, dedupe, per-user 50 and
  per-IP 200 per day. `tracking-profile` returns `{ok, linked}` only.
- Prior fixes L1-L10, B1-B6, M2, M3 present at HEAD; M4 (appAccountToken in the stored payload) still open as agreed.

**Release config**
- `version: 1.0.0+1` with the build number from the workflow; `ITSAppUsesNonExemptEncryption = false`; mic purpose
  string present; `UIBackgroundModes = audio` only; Meta keys injected only when both secrets exist; bundle id
  `com.novaralabs.longnote` = ASC app 6835017154 (`links.dart:16`).

## Not done
- No device run. The `TARGETED_DEVICE_FAMILY` change and the Rate URL were checked in the project files only.
- The live-site check is of the public bundle at the time of review; re-run it after the Figma Make publish.
