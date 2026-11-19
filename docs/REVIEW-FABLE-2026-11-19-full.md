# Fable review, 19 Nov 2026: analytics + server subscription events + ATT removal (full, money + identity)

Scope: branch `v1-build`, `d3a5a93..95056f6` (HEAD). Read in full: `supabase/functions/appstore-notifications/index.ts`,
`tracking-profile/index.ts`, `_shared/appstore_jws.ts`, `appstore_events.ts`, `tracking_profile.ts`, their tests,
migration `20261118000008`, `ios/Runner/AppDelegate.swift` (StorePlugin + DeviceInfoPlugin), `lib/core/analytics/*`,
`lib/core/billing/storekit_billing_service.dart`, `lib/app_services.dart`, `lib/features/settings/privacy_screen.dart`,
`docs/store/website/privacy.md`, ANALYTICS.md, BACKEND-API.md 4.6-4.7, the QA commit. The 18 Nov analytics and Meta-pin
reviews (both APPROVED) cover `6a895ff`-`466fc8d`; only the diff since then was re-read. No code was changed; no production
endpoint was called; no secret was read or printed.

## Verdict: CHANGES NEEDED (two small fixes before the build; the rest can follow)

No blocker: money and entitlement are safe (StoreKit on the device is the only entitlement source; nothing in `lib/`
reads server subscription state), the public webhook cannot be forged, no secret is logged, stored or tracked in git.
Four majors. Two of them are user-facing or data-losing and are each a few lines: **M1** (the in-app privacy screen
still promises the ATT prompt that no longer exists) and **M2** (a locale with `@` makes the server reject the whole
tracking profile, so that user never gets a single server event). Fix those two, re-run `flutter test`, and this is
APPROVED for the TestFlight build; M3 and M4 are design follow-ups that do not need to hold it.

## Checks that passed

| Area | Result |
|---|---|
| Test runs | `flutter analyze`: no issues. `flutter test`: 269 pass, **1 fail** (`bcd_golden_test.dart` "C0 ready to record", see m8: the golden carries the real date "Wed, Nov 18"; not caused by this range). `deno test --allow-env --allow-read supabase/functions/_shared/`: **36 pass** (deno 2.9.7). |
| JWS chain (`appstore_jws.ts`) | `alg` must be ES256; `x5c` exactly 3; root byte-equal to the embedded Apple Root CA - G3 (the test pins SHA-256 `63343abf…3e9179`, which is Apple's published fingerprint); root self-check, intermediate-by-root and leaf-by-intermediate via `@peculiar/x509 verify({publicKey, date})`, which (checked in the cached source) returns `ok && notBefore < date < notAfter`; date = payload `signedDate` (what Apple's library does offline); intermediate must be a CA with OID 1.2.840.113635.100.6.2.1; leaf must carry 1.2.840.113635.100.6.11.1; leaf key exported as P-256, raw 64-byte signature, `crypto.subtle.verify` over `header.payload`. A **real Apple-signed sandbox TEST notification** verifies and one flipped byte fails. Non-JwsError throws (bad base64 in x5c) are caught by the caller's `catch` -> 400, not 500. |
| Webhook checks (`index.ts`) | bundleId (`APPLE_BUNDLE_ID` or constant), environment in {Production, Sandbox}, Production `appAppleId` = `APPLE_APP_ID` when set, inner `signedTransactionInfo`/`signedRenewalInfo` verified with the same code, `tx.bundleId` must match. Idempotency: `ln_appstore_claim` (security definer, execute only for service_role) inserts once per `notificationUUID`; concurrent duplicates get `duplicate`; a run that died before planning is re-run after 2 min; a stored plan is re-sent, never recomputed. Replaying the public fixture only yields `duplicate`. Reply 200 after the plan is stored; sending is `EdgeRuntime.waitUntil` with one retry. |
| Forgery / poisoning | Without Apple's leaf key nothing verifies. A sandbox purchase by a modified client with a victim's UUID as `appAccountToken` could create a sandbox `subscriptions` row for that user: analytics-only (Amplitude `sandbox: true`; Meta only with the test code). Entitlement never depends on it. |
| Money mapping (`appstore_events.ts`) | SUBSCRIBED + offerType 1 + FREE_TRIAL/price 0 -> StartTrial without value; paid SUBSCRIBED -> Subscribe with value; first DID_RENEW after a trial (stored state, else production gap < 14 d, flagged `inferred`) -> Subscribe; later DID_RENEW -> Purchase; REFUND -> Amplitude negative revenue only, nothing to Meta; trial refund (price 0) no revenue. `price/1000`, storefront currency. `insert_id` and `event_id` = notificationUUID. Sandbox never reaches Meta unless CAPI + `META_TEST_EVENT_CODE`, and the code is attached only when `environment !== "Production"`. Meta older than 7 days skipped. |
| Opt-out, PII | Server sends nothing without a profile or with `share_analytics=false`; the opt-out upsert nulls every other column. No `ip`, no IDFA/IDFV, no user id to Meta; Amplitude `user_id` = Supabase id only. `extinfo` strings capped at 64. |
| Meta CAPI payload | `action_source: "app"`, `event_name/event_time(s)/event_id`, `user_data.anon_id`, `app_data.{advertiser_tracking_enabled, application_tracking_enabled, extinfo[16] with "i2" + bundle}`, `custom_data.{value, currency, content_ids, content_type, order_id}`: matches Meta's app-events CAPI shape. Amplitude HTTP V2: `time` in ms, `revenue/price/quantity/revenueType/productId`. |
| Secrets | `scrub()` removes tokens from stored/logged bodies; URLs carry only the dataset id; `.env*` not tracked (`git ls-files` empty); CI masks keys. `console.*` lines carry no tokens or user ids. |
| RLS (migration 00008) | `tracking_profiles`: RLS on, select/insert/update own row only (`auth.uid()`), no delete, cascade on user delete. `appstore_notifications`, `subscriptions`: RLS on with no policies, all privileges revoked from anon/authenticated, service_role only. |
| App side | `appAccountToken` = `knownUserId() ?? userId()` (anonymous sign-in) under a 5 s timeout, regex-checked UUID, null on any failure, and Swift drops a non-UUID: the purchase never waits on it longer than 5 s and never fails for it (tests `storekit_billing_test.dart:326-360`). `TrackingProfileSender.sync` is never awaited on a UI path, each native/network read is wrapped in `_safe` (5 s), sends only on change, coalesces concurrent calls, triggers once per launch (6 s timer), on the switch, on purchase start and on entitlement change. |
| Swift | `Product.purchase(options: [.appAccountToken(uuid)])`, `VerificationResult.jwsRepresentation` (correct: the JWS is on the result, not on `Transaction`), `Transaction.currentEntitlements` filter unchanged, `Transaction.updates` finish + `changed`. Purchase and restore behaviour unchanged. |
| ATT removal (HEAD) | No `app_tracking_transparency` in pubspec/lock, no `NSUserTrackingUsageDescription`, no `ATTrackingManager`/`advertisingIdentifier` in `lib/` or `ios/Runner`; `NoTrackingConsent` always; `setAdvertiserIdCollectionEnabled(false)` + `FacebookAdvertiserIDCollectionEnabled=false`; `askTrackingOnce` is no longer called (onboarding diff) and `app_flow_test` asserts 0 prompts and `advertiserId == false`. Version `1.0.0+1`; CI sets `--build-number`. |

## Findings

Severity: **major** = wrong user-facing statement or silent loss of the money-measurement events; **minor** = correctness
or hygiene, no money or identity exposure.

### M1 (major) In-app privacy screen still promises the ATT prompt and omits the server path
`lib/features/settings/privacy_screen.dart:47`:
"Your advertising ID is shared with Meta only if you allow tracking when iOS asks."
Failure: a tester (or App Review) opens Settings > What happens to your audio and reads that the app may share the IDFA
after an iOS prompt; the build has no prompt and never reads the IDFA (HEAD). The same paragraph says nothing about
Apple's notifications reaching our server or that the server (not the app) sends trial/subscribe/renewal events. This
screen is the policy the user actually sees; it must match `privacy.md` sections 7 and 9.
Fix: replace the sentence with, e.g., "We never collect or share your device advertising ID (IDFA), and the app shows
no tracking prompt. Apple tells our server when a trial starts or a subscription is bought, renewed or refunded; while
this switch is on, our server passes trial, purchase and renewal events (price and currency, no content) to Meta and
Amplitude." Also fix `_SupportId` line 80: the id is now also created at the first purchase (appAccountToken sign-in),
so "Made after your first cloud transcription" is no longer always true ("Made after your first upload or purchase").

### M2 (major) A locale with `@` makes the server reject the whole profile: that user never gets any server event
`lib/core/analytics/tracking_profile.dart:109` sends `locale = extinfo[6]` = `Locale.current.identifier`
(`AppDelegate.swift` DeviceInfoPlugin). On iOS 16+ that identifier carries extension keywords for common settings,
e.g. `en_US@rg=inzzzz` (language region different from the device region) or `en_IN@calendar=...`.
`supabase/functions/_shared/tracking_profile.ts:9` `CODE = /^[A-Za-z0-9_.,:+\- ()]{1,64}$/` has no `@` or `=`, so
`str(body.locale)` throws `ProfileError` -> `400 bad_request` for the **entire** profile (`tracking-profile/index.ts:26`).
Failure: an Indian user with English (US) + region India buys a trial; `tracking_profiles` has no row; Apple's SUBSCRIBED
arrives -> `metaSkip = no_profile`, `amplitudeSkip = no_profile`; every later renewal is skipped too. The app retries on
every launch and fails every time (`kvLastSent` is only written after a 200). Silent: the only trace is `debugPrint`.
Fix (both sides): in `buildBody`, send `locale` as the part before `@` (and cap at 35); on the server, normalise soft
fields instead of rejecting the profile (drop/trim `locale`, `device_model`, `os_version` that fail `CODE`; keep the
400 only for `share_analytics` and `extinfo` shape). Add a Deno test with `en_US@rg=inzzzz` and a Dart test for the
stripped locale.

### M3 (major) A notification that arrives before the profile/user is known is skipped forever
`appstore-notifications/index.ts:150-180`: `plan()` returns `no_user`/`no_profile`, the row goes to `state: done`, and
nothing ever revisits it. The profile is only *started* with the purchase (`store.onPurchaseStarting`, 20 s timeout) and
Apple's SUBSCRIBED typically lands seconds after the sheet closes; a slow network, a failed POST (see M2), or the user's
first purchase on a fresh install with no prior sign-in all lose **StartTrial / the first Subscribe**, the events the
Meta campaign optimises on. The reinstall case is the same: notifications between the reinstall and the first profile
sync of the new user are attributed to nobody.
Fix: in `tracking-profile/index.ts` after the upsert and the (optional) link, select `appstore_notifications` rows for
the user's `original_transaction_id` (and rows whose `payload.transaction.appAccountToken` = user id) with
`plan.amplitudeSkip in ('no_user','no_profile')` and `signed_date > now() - 7 days`, re-plan them with the new profile
and send (insert_id / event_id keep it idempotent). Alternatively a small pg_cron pass over such rows. Record the replay
in `attempts`.

### M4 (major) The deletion promise is not met by the schema for notification rows
`privacy.md` section 5 ("Subscription status … and ad measurement details: Deleted with your anonymous ID") and
section 10 ("delete your anonymous ID … subscription status and ad measurement details from our backend"). Code:
`tracking_profiles` cascades (good), `subscriptions.user_id` is set null (acceptable, no personal data left), but
`appstore_notifications.user_id` has **no foreign key** (migration 00008:63) and `payload.transaction.appAccountToken`
holds the same anonymous id in JSON; both stay for 13 months after the 90-day cleanup (`ln_cleanup`, migration 00007
L9) or a deletion request.
Failure: a user emails their Support ID and asks for deletion; the id is removed from `auth.users` but remains in up
to 13 months of notification rows (plus product, price, dates, transaction ids).
Fix: add `user_id uuid references auth.users (id) on delete set null` and a trigger (or do it in `ln_cleanup` and the
future delete-my-data function) that sets `payload = jsonb_set(payload, '{transaction,appAccountToken}', 'null')` for
that user; or stop storing `appAccountToken` in `payload` at claim time (it is already in `user_id`). Update
BACKEND-API 4.7's table row to say what actually remains.

### m1 (minor) Subscription relink is last-writer-wins and open to any signed-in holder of a valid JWS
`tracking-profile/index.ts:36-41`: any authenticated (anonymous) user who posts a verified Apple transaction JWS for our
bundle takes over `subscriptions.user_id`, and the webhook then prefers that user over the `appAccountToken`
(`appstore-notifications/index.ts:163`). Two devices on one Apple ID (two anonymous users) flip attribution to whichever
synced last; a JWS copied off a device does the same. Money: none (entitlement is StoreKit on the device, confirmed: no
server read anywhere in `lib/`). Analytics: renewals land on the wrong Amplitude user / Meta anon id. Acceptable for v1;
document it in BACKEND-API 4.7, and consider requiring `tx.expiresDate > now` (an expired JWS has no renewals to claim)
and keeping `appAccountToken` as the owner when the token user still exists and differs.

### m2 (minor) Upgrade "Purchase" value and the policy's event list
`appstore_events.ts:112,194`: `DID_CHANGE_RENEWAL_PREF` + `UPGRADE` sends Meta **Purchase** with `tx.price` = the full
price of the new product, not the prorated amount Apple charges; Amplitude gets `+price` as `upgrade`. `privacy.md`
section 7 lists "bought or renewed" (not upgraded) and section 6 omits plan change, revoke, offer redeemed and refund
reversed/declined, which the server does send to Amplitude. Fix: either drop the Meta value for upgrades or add
"upgraded" to the policy; add the missing Amplitude kinds to section 6.

### m3 (minor) `tracking_profiles` is writable by the user directly, bypassing the function's validation
Migration 00008:35-41 grants insert/update to `authenticated` on own row; the length checks hold but `CODE` and the
`extinfo` content rules live only in `tracking_profile.ts`. A user can only damage their own analytics (and the server
truncates extinfo items to 64). Since the app writes through the function with the service role, `revoke insert, update`
from `authenticated` (keep select) removes the second path.

### m4 (minor) `paid_count` read-modify-write across concurrent notifications
`appstore-notifications/index.ts:160-175` reads `prior` then `nextState()` writes `paid_count = prior + 1`; Apple can
deliver two notifications for one `originalTransactionId` within the same second (SUBSCRIBED + DID_CHANGE_RENEWAL_PREF).
A lost increment only affects the `trial_converted` vs `renewed` choice later (and only when `paid_count` was 0). Fix:
increment in SQL (`paid_count = subscriptions.paid_count + 1`) via a small RPC, or accept.

### m5 (minor) Sandbox and Production share one `subscriptions` key space
`original_transaction_id` is the primary key; `environment` is a column. Apple's id spaces are distinct in practice;
keying by `(environment, original_transaction_id)` removes the assumption. Same for the seed in `tracking-profile`.

### m6 (minor) A send that dies after `planned` is never retried
`send()` moves the row to `sending`; if the isolate is killed mid-flight the row stays `sending`, Apple got its 200,
and `ln_appstore_claim` treats `sending` as `duplicate`. Documented as "never retried after that"; fine for v1. A daily
cron that re-sends `sending` rows older than 10 min (idempotent ids) would close it.

### m7 (minor) Stale ATT text in code and docs
`ios/Runner/Info.plist:36-38` comment ("only after the user allows tracking"), `lib/core/analytics/meta_sink.dart:53,100`,
`docs/ANALYTICS.md:168-172` ("ATT … Apple's prompt is shown at most once …"), `docs/store/website/PRIVACY-SERVER-EVENTS.md`
(still says "whether you allowed tracking"). `remote_analytics_test.dart:236-275` tests `askTrackingOnce`, which is now
dead code; keeping it is honest (the function exists and the flow test asserts 0 prompts), but say so in the group name.

### m8 (minor) Golden `c0_ready.png` depends on today's date
`test/screens/bcd_golden_test.dart:132` renders "Wed, Nov 18 · not started yet" from the real clock; on 19 Nov the test
fails (0.25 % diff, only the date line). Pre-dates this range (c9013de) but it makes `flutter test` red on every other
day. Fix: inject the fixed test clock into the ready-screen subtitle, or mask the line.

### m9 (minor) Policy statements outside this range that are not true of the build
`privacy.md` section 10 "Delete your account … Settings > Account > Delete account": no account or such screen exists in
v1. Flagging because it sits next to the server-events text being reviewed; drop or mark as "when accounts exist".

## What I did not do
- Call the deployed functions or Supabase Management API; read `/root/.secrets/longnote/.env`.
- Verify the App Store Connect notification URL/version or the Meta dataset settings (owner-side, per BACKEND-API 4.6).
- Compile the Swift (a CI compile check runs in parallel); I checked the StoreKit 2 API names and types by reading.

---

## Re-review (diff-only), 19 Nov 2026: fixes for M1, M2, M3 and the minors

Uncommitted diff on top of `95056f6` plus the new untracked `supabase/functions/_shared/appstore_send.ts`.
Re-ran: `deno test --allow-env --allow-read supabase/functions/_shared/` 37/37; `deno check` of both functions OK.
The coordinator reports `flutter test` 270/270 and analyze clean.

### Verdict: APPROVED

| Item | Checked | Result |
|---|---|---|
| M1 privacy screen | `privacy_screen.dart:46` | Now: trial/subscription events come from the server when Apple tells us; "We never read your advertising ID (IDFA)". True of the build. |
| M2 locale | `AppDelegate.swift:304` strips at `@`; `tracking_profile.ts soft()` for app_version / os_version / device_model / locale cleans (cut at `@`, trim, cap, CODE) to null instead of throwing; test `en_US@rg=inzzzz -> en_US`, `<script> -> null`. `meta_anon_id` stays strict (`XZ` + upper-case UUID passes). | Fixed; older builds that still send `@` are handled by the server. |
| Moved code | Old `background/post/scrub/sendAmplitude/sendMeta/send/metaPath` vs `appstore_send.ts` | `diff` identical apart from `export` and one trailing blank line. |
| M3 replay: double-send | `replaySkipped`: select `state=done AND meta_result='skip: no_profile' AND kind in (trial_started, subscribed) AND received_at >= now-7d`, limit 5; claim = `update ... where notification_uuid=? and state='done' and meta_result='skip: no_profile' returning`; only a non-empty return proceeds to `send()`. A concurrent replay (two profile POSTs) finds 0 rows on the second claim. After a send the row carries the real result, so it never matches again. Second guard: Amplitude `insert_id` and Meta `event_id` are still the notificationUUID. `nextState` is not re-run, so `paid_count`/state are not double-counted. | Cannot double-send. |
| M3 replay: opted-out user | tracking-profile calls it only when `row.share_analytics === true`; `replaySkipped` re-reads `tracking_profiles` and returns 0 unless `share_analytics`; `plan()` gates again (`opted_out`). Rows skipped as `opted_out` at the time are never replayed (filter is `no_profile` only). | Cannot send for an opted-out user. Consent is evaluated at send time, which is the right time. |
| M3 replay: wrong user | Rows are selected by `appstore_notifications.user_id = caller's user id` (set by the webhook from `subscriptions.user_id` or the signed `appAccountToken`), and planned with the caller's own profile. A relink (m1) changes `subscriptions.user_id` only, so a hijacker's replay finds nothing of the victim's. | Cannot send to the wrong user. |
| M3 replay: prior=null | Only SUBSCRIBED kinds are replayed; `classify()` ignores `prior` for SUBSCRIBED, so the re-plan equals the original (StartTrial vs Subscribe from the transaction itself). | Correct. |
| Golden C0 | `withClock(Clock.fixed(...))`; `recording_screen.dart` reads `clock.now()`. | Date-stable. |
| Docs | ANALYTICS.md ATT section and Meta bullets, `meta_sink.dart:53`. | Match the build. |

### Residual notes (no action needed for this build)
- r1. The replay covers `no_profile`, not `no_user` (a purchase whose `appAccountToken` could not be set because sign-in
  timed out leaves `user_id` null, and nothing can later claim that row). Rare; the m1 relink then attributes
  renewals, and the first event is lost. Could be added to the follow-up with M4.
- r2. The comment in `tracking-profile/index.ts:65-67` says the link makes "a reinstall's subscription already this
  user's" for the replay; the link updates `subscriptions.user_id`, not the old notification rows, so a reinstall does
  not replay the previous user's rows (correct behaviour, slightly misleading comment).
- r3. `replaySkipped` runs up to 5 sequential `send()`s inside `waitUntil` (each up to ~24 s worst case). Within the
  edge function wall-clock budget in practice (normally 1 row); if the limit is ever raised, send in parallel.
- r4. M4 (FK + scrub of `appstore_notifications.user_id` / `payload.transaction.appAccountToken` on user deletion)
  remains open, as agreed, for the login/delete-my-data work; `privacy.md` section 5/10 overstates deletion until then.

---

## Re-review (diff-only), 19 Nov 2026: share sheet rows tappable while the note loads (build 115)

`git diff de4a890 HEAD -- lib`: only `lib/features/note/share_sheet.dart` (+28/-7).

### Verdict: APPROVED (one minor, optional)

| Check | Result |
|---|---|
| mounted / setState | `_loaded = _load().catchError(..).whenComplete(() { if (mounted) setState(_ready = true) })`: a failed load still completes `_loaded`, `_ready` flips, `_note` stays null so PDF/Audio disable and Summary/Transcript/Copy toast "no … yet". Every action does `await _loaded; if (!mounted) return;` before touching `context`; `_run` re-checks `mounted` after the job and in `finally`. No setState after dispose. |
| Double tap during load, same row | Two `_pdf` calls both await `_loaded`; the first resumes and runs `setState(_busy = 'pdf')` with **no await between the resume and the guard**, so the second sees `_busy != null` and returns. Summary/Transcript go through their own `await _loaded` and then `_run`'s second `await _loaded` (a microtask yield on a completed future), still with no await between `_busy` check and set: the second caller returns. Holds for mixed rows too (one `_busy`). |
| Re-check of the old disabled conditions | PDF: `n == null` -> return (in `_run`). Summary/Copy: `_summaryText == null` -> toast. Transcript: `!_hasTranscript` -> toast. Audio: `n == null || n.durationMs == 0` -> return (the old row condition exactly). Build-time `onTap` uses the same predicates once `_ready`. |
| Copy path | `await _loaded; mounted; _summaryText/_note` re-read after the load; `copyText` then `if (mounted) showToast`. A double tap copies twice and shows two toasts: harmless. |
| Imported audio | Unchanged branch: `n.source == 'imported'` -> `_run('audio', shareAudio)`; the `durationMs == 0` return now applies before it, which matches the previous disabled state of the row. |
| Analyzer | `use_build_context_synchronously` satisfied by the `mounted` checks immediately before each `context` use (analyze clean per the coordinator). |

### m10 (minor, optional) Two taps on "Audio file" during a slow load open two format sheets
`share_sheet.dart:123-157`: `_audio` passes its checks and calls `showLnSheet` **before** anything sets `_busy`;
`LnPressable` (`pressable.dart:43`) and `showLnSheet` (`sheet.dart:131`) have no re-entrancy guard. Before this change
the row was disabled until the load finished, so two taps had to land within the sheet's open animation; now they can
land anywhere in a multi-second load and both resume together after `_loaded`, stacking two "Audio file" sheets (the
second one's choice runs `_run`, the first one is left underneath). Not an imported-audio problem (that branch goes
straight to `_run`). Fix (3 lines): a `bool _choosing` set before `showLnSheet` and cleared in `finally`, returning early
when already set; or set `_busy = 'audio'` around the choice. Does not need to hold build 115.

Also optional: a widget test that taps PDF before the fake repo resolves and asserts one `sharePdf` call, so the
"tap during load" behaviour this fix introduces is pinned.
