# Fable re-check, 20 Nov 2026: fixes for the full pre-submission review

Scope: diff-only re-check of `487708b..HEAD` (`09f9cf5` server + docs, `103e248` app + tests) against
`docs/REVIEW-FABLE-2026-11-20-full-presubmit.md`. Read-only except this file. No push, no ASC / Supabase management
call, no secret read or printed.

## Verdict: APPROVED

Every item the two commits claim is fixed (M2, M3, M4, m1, m2, m2b, m3, m4/m23, m6, m8, m9, m12, m14, m15, m16-part,
m19, m21-part, m22, m25). None of the fixes introduces a bug I could find. The three nits below are optional and can
wait for 1.0.1. The deferred list is acceptable for a first submission; M1 (re-publish the website) stays an owner
precondition for "Submit to App Review", as before.

## Test runs (HEAD `103e248`)

| Check | Result |
|---|---|
| `flutter analyze --no-pub` | No issues found |
| `flutter test` | **287 passed, 0 failed** (52 s) |
| `deno test --allow-env --allow-read supabase/functions/_shared/` | **38 passed, 0 failed** |
| `deno check supabase/functions/*/index.ts` | **9 of 9 clean** (`transcribe-status` now passes: m12 fixed) |

## Item by item

| Item | Where | Fixed? | Notes |
|---|---|---|---|
| M2 per-IP caps | `common.ts:103-104` (36 h, $4); `BACKEND-API.md:350-351,369-371`; `DECISIONS.md:85` | yes | Each IP now takes at most ~half a pool ($3.60 of $12 audio, $4 of $8 LLM). Commit says the live secrets match; not verified here (no management call). The 70% global-cap alert is still absent (deferred, see below). |
| M3 discard ordering | `app_services.dart:595-609` | yes | Order is now: `_discarding = id`, read `elapsed`, `await recorder.stop()`, `unawaited(analytics.log)`, `await repo.deleteByUser(id)`, `finally _discarding = null`. No await before the mark. `_onRecordingFinished` (`:616`) returns early on `r.id == _discarding`. Test `analytics_events_test.dart:166` runs `discardRecording()` and `recorder.stop()` concurrently and asserts free count 0, no job, no row. If `stop()` throws, `finally` clears the mark and the row is not deleted (pre-existing; recovery handles it). |
| M4 processing copy | `processing_view.dart:100-108`; `note_ready_ask.dart:42` | yes | Cloud: "Keep Longnote open until the upload is done; if you close it, the note finishes the next time you open the app." On-phone variant likewise. Both true of the build (no background task, no push). Golden `d1_processing.png` regenerated. The note-ready ask now says the notification comes only while Longnote is open in the background. |
| m1 / m2 awaited analytics | `recording_controller.dart:182-185,278-279,289-290,331-338,423-427` | yes | start / pause / resume / interrupted / completed all `unawaited`. Also `restorePurchases` (`app_services.dart:188-196`), share-on (`:180-181`), `note_actions_sheet.dart:101`, `paywall_screen.dart:103`. Un-awaited safety: `Analytics.log` (`analytics.dart:213-232`) wraps the DB insert and every `sink.track` in try/catch and `remoteSafeProps` is pure, so a dropped future cannot surface an uncaught error. `remote_analytics_test.dart:343` adds `pumpEventQueue()` for the restore order. |
| m2b import row on failure | `import_controller.dart:179,207,217,221,228,236-243` | yes | `rowOnly` is true from `repo.insert` to `enqueue`; `_undo` calls `repo.deleteByUser(id)` (row + folder in the background, `recording_repository.dart:197-208`) and falls back to `_cleanup(dir)` if that throws. `_fail` re-inserts the card if it was already removed (`:261`). See nit 1 for the one residual. |
| m3 double event | `summary_style_sheet.dart:70-74`; `ANALYTICS.md:72` | yes | Only `summary_style_changed from=settings`. ANALYTICS.md updated. |
| m4 / m23 too_long exits | `processing_view.dart:287-298`; test `analytics_events_test.dart:185` | yes (UX) | No "Try again" when `too_long`. Recording: "Transcribe on this phone instead" (`canUsePhone`, `note_screen.dart:273` excludes imports). Import: "Cut the file into parts shorter than 5 hours ... and import each part." The m23 re-plan into 4 h pieces was not done (deferred; the import copy is the exit). |
| m6 import cancel | `import_controller.dart:245-253`; `analytics.dart:93-94,150`; `ANALYTICS.md:70-71`; tests list it | yes | New `import_cancelled` with `kind`, `format` only. |
| m8 retention sentence | `privacy_screen.dart:38` | yes | "... deletes its copy within 24 hours of your phone collecting it (after 7 days if your phone never collects it)". Matches the server and the published policy. |
| m9 subscription ordering | `appstore_events.ts:63-65,225-235`; `appstore-notifications/index.ts:136,147`; test `appstore_events_test.ts:190` | yes | See the dedicated analysis below. |
| m12 deno check | `transcribe-status/index.ts:17-19` | yes | `COLS` is one literal; `deno check` clean for all 9 functions. |
| m14 pinned supabase-js | `common.ts:5-6` | yes | `npm:@supabase/supabase-js@2.118`; `deno check` resolves it. No other unpinned import of it (grep). |
| m15 webhook id | `soniox-webhook/index.ts:26-27` | yes | `/^[A-Za-z0-9_-]{1,128}$/`. Soniox ids are UUIDs (hex + hyphens), which pass. If Soniox ever sent an id the regex rejects, the webhook answers 400 and the job still completes through the status poll (`transcribe-status` pulls after `WEBHOOK_GRACE_SECONDS`), so a false reject is a ~2 min delay, not a loss. |
| m16 (part) | `BACKEND-API.md:269` | partly | "200 asks" fixed. Review notes (`launch/app-store-listing.md`) and `launch/privacy-policy.md:68` still open (untracked folder; deferred). |
| m19 orphan `.part` | `recording_repository.dart:174-195`; `app_services.dart:502-503`; test `recovery_test.dart:143` | yes | See the dedicated analysis below. |
| m21 (part) | `tus_uploader.dart:130-135` | partly | Create 400 and 403 both map to `upload_refused`. The 401-refresh part was not done (a 401 on TUS is still a used try; deferred). |
| m22 upload_refused | `cloud_pipeline.dart:515-525`; test `cloud_pipeline_test.dart:270` | yes | `JobDeferral(wait: hourLimitWait = 15 min, status: queued, progress: 'Waiting to upload')`; tries stay 0 (asserted). See the dedicated analysis below. |
| m25 comment drift | `longnote_api.dart:66` | yes | "until the ack, at most 24 h after the first fetch". `pcm_source.dart:35` NOT DEVICE-TESTED comment remains (harmless). |

## The questions asked

### M3 discard ordering: correct
The mark is set synchronously before any await, `elapsed` is read before `stop()` (so the logged duration is the one
the user saw), and the only awaits are `stop()` and `deleteByUser()`, both of which run with the mark set. A Stop
that lands during `stop()` is absorbed by the controller's own stop guard; a Stop that lands during `deleteByUser()`
has nothing to stop. The test fails on the old order per the commit message (not re-verified by reverting; the
assertion set is the right one: free count, pending jobs, row).

### Un-awaited analytics: no lost-error crash path
`Analytics.log` never throws (both halves in try/catch, the props mapper is pure). The three bare calls without
`unawaited()` (`note_actions_sheet.dart:101`, `paywall_screen.dart:103`, `summary_style_sheet.dart:71`) are fine
for the same reason; `flutter analyze` does not flag them (the `unawaited_futures` lint is not on).

### m9 subscription ordering: cannot drop a real state change
`nextState` skips the state write only when `prior.last_signed_date` is strictly newer than `n.signedDate`. A
notification's `signedDate` is when Apple signed that notification, so a refund (`REFUND`), expiry (`EXPIRED`) or
revocation that happens after the stored notification is always signed after it and is applied; equal dates are
applied; a null / unparsable prior date is applied. Only a notification signed before the one already stored is held
back, and that one by definition describes an older snapshot. The slim row still counts the payment (`paid_count`)
and `appstore-notifications` still adds `user_id` and upserts on `original_transaction_id`, so nothing else about
the pipeline changes (plan / Meta / Amplitude run as before with the event's own time). Test covers both directions.
Limit: this guards delivery order and retries that keep the original `signedDate`; a retry Apple re-signs with a
fresh `signedDate` would still apply its (stale) status, exactly as before the fix, so there is no regression, only
a smaller window. `subscriptions` is reporting-only (no entitlement reads it), as noted in the original review.

### m22 retry without consuming a try: cannot loop forever in the legitimate case; no ceiling in the illegitimate one
The 25-object cap clears as jobs end and, at worst, by the hourly server sweep of objects older than 24 h, so a
genuine `upload_refused` resolves within ~24 h of 15-minute retries (plus a retry on every foreground via `pokeAll`,
which includes `queued` jobs). Each retry is one TUS create (no upload bytes), so the cost is negligible. Residual:
a non-cap 400 at TUS create (a request bug) would now wait forever as "Waiting to upload" instead of failing on
the 4th try. Every input to that request is code-fixed (path `<user>/<clientId>.m4a`, fixed metadata, fixed
bucket) and covered by the fake backend and e2e, so I accept it; see nit 2 for an optional ceiling.

### m19 startup deletion: cannot delete a real recording or a live import
- Only `*.part` files are deleted, only inside direct subfolders of `recordings/` whose basename has no `recordings`
  row (`repo.get`). Recordings write `.wav` / `.m4a` parts and always have a row before files exist; an import's
  final file is renamed off `.part` before its row is inserted and the folder with the row is skipped.
- Whisper's model download writes `ggml-*.bin.part` in the iOS Library root
  (`whisper_ggml-2.9.0/lib/src/whisper_controller.dart:189-198`), not under `recordings/`, so it is out of reach.
- A live import cannot overlap: the sweep's only caller is `AppServices.boot` (`main.dart:40`), it runs once right
  after `recoverAll`, and the first import needs the UI, the paywall gate and a file picker. If the app is killed
  during an import, that import is dead by definition; its `.part` is what the sweep is for.
- Errors are swallowed (`catch (_) {}`), it is `unawaited`, so it cannot delay or break boot. Test
  `recovery_test.dart:143` covers orphan `.part` deleted, sibling non-`.part` kept, owned `.part` kept.

### m2b row deletion: correct, one residual (nit 1)
`deleteByUser` removes the row and schedules the folder delete; `_undo` falls back to `_cleanup(dir)` if the row
delete throws. After `enqueue` succeeds `rowOnly` is false again, so a later failure only cleans files; the only
await after that is `noteQueuedByUser()` (a `kv.getBool`, `app_services.dart:234-237`), which does not realistically
throw.

### m15 regex vs real Soniox ids
Soniox transcription ids are UUIDs; `[A-Za-z0-9_-]{1,128}` accepts hex and hyphens (and base64url if the format
ever changes). A false reject degrades to the status-poll path, not a lost transcript.

## Nits (optional, not blockers)

1. **Import: a failure between the gate and `enqueue` spends the free recording on nothing** —
   `import_controller.dart:210-217`: `gate.onRecordingFinished` runs before `enqueue`; if `enqueue` throws, the row
   is now (correctly) deleted but the free count stays used. Before the fix the same count was spent and a broken
   note remained, so this is not a regression. Optional: move the gate call after `enqueue` (it is a kv write and
   cannot fail the queue), or call it inside the same `try` after `rowOnly = false`.
2. **`upload_refused` deferral has no ceiling** — `cloud_pipeline.dart:515-525`: see above. Optional: fail after
   24 h of deferrals (or N deferrals) so a request bug surfaces as "failed" instead of waiting forever.
3. **Whisper `.part` comment** — `recording_repository.dart:174-177` says "nothing else can free"; worth one line that
   the sweep is scoped to `recordings/` subfolders so a future model-download or export writer under the same root
   does not get swept. Documentation only.

## Deferred list: acceptable for a first submission

Not fixed in these commits, all pre-existing and none a guideline or money risk: M1 (website re-publish: owner step,
still a precondition for "Add for Review"; re-run the curl check after the Figma Make publish), the 70% global-cap
alert (M2 second half), m5 (reserved event), m7 (Rate before live), m10 (reservation held on a rare server failure
until retry / 00:00 UTC), m11 (storage sweep on `created_at`), m13 (Soniox's own too-long as `upstream_failed`,
rare VBR imports), m16 review notes in `launch/`, m17 Advanced screen, m18 (6 h/h cap on re-transcribe), m20 (TUS
PATCH timeout uses a try; manual Retry resets), m21 401-refresh on TUS, m23 re-plan (the import copy is the exit),
m24 interruption-ended. Each has a manual path (Retry, re-import, the 00:00 reset) or is cosmetic.

## Not done
- No device run. The live site was not re-fetched (owner step M1 is unchanged by these commits).
- The live Supabase secrets for M2 were not read; the commit message says they match the new defaults.
