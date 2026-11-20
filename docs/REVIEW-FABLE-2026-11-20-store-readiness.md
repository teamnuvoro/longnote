# Fable review, 20 Nov 2026: App Store readiness (first submission)

Scope: branch `v1-build` at HEAD `5385e6c`, read-only. The working tree carried uncommitted analytics work in 26 files
while I read; everything below is checked against HEAD (`git show HEAD:`) where the two differed. No file was edited
except this one; no App Store Connect or Supabase management endpoint was called; no secret was read or printed.
The four `novaralabs.in/longnote/*` pages were fetched with curl and the JS bundle inspected.
Not re-reported: the Settings "Rate Longnote" button, per-screen analytics, ASC-side tasks (privacy label entry,
pricing, content rights, attaching the subscriptions), the "three intro screens" review-note wording.

Verdict: no outright 3.1.2 or 5.1.1 blocker in the paywall or privacy flow; the two items marked BLOCKER are a hidden
developer screen that is live in release (paywall bypass + placeholder-transcript trap) and a privacy-policy sentence
that promises an in-app account-deletion screen the app does not have. Both are small fixes.

## BLOCKER

### B1. Hidden developer screen is reachable in the release build (2.3.1 hidden features; paywall bypass)
- `lib/features/settings/settings_home_screen.dart:101-106`: tapping the version line 7 times pushes `R.benchmark`.
  Same again at `lib/features/settings/settings_screen.dart:186-196` (the "Advanced" screen, reachable from
  Settings › About › Advanced). Nothing gates either on `kDebugMode` or a dart-define.
- `lib/features/benchmark/benchmark_screen.dart:211-234` ("Developer" section):
  - "Use fake transcriber" writes `kvFakeTranscriber`; `lib/app_services.dart:447` reads it at every boot, so a user
    who flips it gets placeholder text in every on-device transcript from then on, with no visible way back.
  - "Reset test billing + free recording" sets `PaywallGate.freeUsedKey = 0` (`paywall_gate.dart:17`), i.e. a fresh
    free recording every time: the only paywall in the app is bypassed in 8 taps.
  - Benchmark also runs the whisper model against stored recordings and links to the widget gallery.
- Fix: wrap the 7-tap handlers and the `benchmark`/`gallery` routes (`lib/app/router.dart:293-300`) in
  `if (kDebugMode || const bool.fromEnvironment('LN_DEV'))`, or drop the Developer section from the release build.
  Also make `useFakeTranscriber` read `false` unless the same flag is on.

### B2. Privacy policy and support page describe an account-deletion screen that does not exist (5.1.1)
- `docs/store/website/privacy.md:162`: "**Delete your account.** If you have signed in with an account, go to
  **Settings > Account > Delete account**..."; `docs/store/website/support.md:27`: same. The deployed JS bundle
  contains the same sentences ("Delete account" x2, "Settings > Account" x2).
- The app has no account, no sign-in and no such screen (`privacy_screen.dart:49` says "No account"; the only
  settings routes are `routes.dart` plan/audioLanguage/summaryLanguage/defaultStyle/transcription/privacy/advanced).
  A reviewer who reads the policy and looks for Settings › Account will not find it; that reads as a missing
  account-deletion feature rather than as an app without accounts.
- Fix: delete the two "if you have an account" bullets; state once "Longnote has no accounts. To delete what our
  servers hold, email support@novaralabs.in with your Support ID (Settings › What happens to your audio)". Confirmed:
  no account creation exists anywhere in `lib/` (anonymous Supabase auth only, `supabase_auth.dart`), so the
  5.1.1(v) account-deletion requirement does not apply once the text stops claiming otherwise.

## SHOULD-FIX

### S1. Daily/hourly server limits can stop a paying user (owner: no daily limits for payers)
`supabase/functions/_shared/common.ts:81-103` defaults, all overridable by a function secret of the same name
(no code change needed):
- `LIMIT_AUDIO_SECONDS_PER_HOUR` = 4 h: importing a backlog of three 2-hour voice memos hits "Too much audio in the
  last hour" (`api_error.dart:33`); the job waits `hourLimitWait`.
- `LIMIT_IP_AUDIO_SECONDS_PER_DAY` = 24 h per IPv4 / IPv6-64 per day: an office or campus NAT with a handful of
  paying users sharing one address is capped as a group ("Too much use from this network today").
- `LIMIT_USER_LLM_USD_PER_DAY` = $1 and `LIMIT_ASK_PER_DAY` = 60: at gpt-5.4-mini prices (`openai.ts:10-12`,
  $0.75/M in) a 3-hour transcript is ~36k tokens, so each Ask costs ~$0.03 and each summary reserves ~$0.08
  (`reserveCall(..., estimateUsd(messages, MAX_OUT=12_000))`, `summarize/index.ts:128,157`). ~30 questions on one long
  note in a day reaches $1 and Ask shows "You have used today's questions" (`ask_view.dart:45`).
- `LIMIT_GLOBAL_AUDIO_USD_PER_DAY` = $12 (~120 audio hours/day for all users at $0.10/h) and
  `LIMIT_GLOBAL_LLM_USD_PER_DAY` = $8: fine at launch, but every user is told "The service is busy today. Try
  again tomorrow" the day it trips. Needs an alert, not just a cap.
- Fix (secrets only): raise the per-user/per-IP ceilings to anti-abuse levels (e.g. hour 24 h, IP day 200 h, user LLM
  $10, ask 500/day, summary 200/day), keep `user_day` 8 h or raise to 16 h, and alarm on the global caps at 70%.

### S2. Recordings over 5 hours fail for good, while the paywall promises "no time limit"
- `_shared/common.ts:94` `maxAudioSeconds` = 300 min (Soniox per-file limit); `transcribe-start/index.ts:46,88`
  returns `too_long`; `lib/core/cloud/cloud_pipeline.dart:523-524` makes it a non-retryable failure; the user sees
  "Recordings over 5 hours can't be transcribed in one piece" (`api_error.dart:49-50`). No split and no automatic
  on-device fallback exists (no `split`/`chunk` in `cloud_pipeline.dart`).
- The paywall says "Hours per recording. No time limit" (`paywall_more.dart:75`) and the FAQ "Record for minutes or for
  hours" (`:188`); onboarding says "Longnote has no time limit, whatever you pick" (`onboarding_screen.dart:188`).
- Fix: upload long recordings in <=5 h parts (the audio already exists as 5-minute WAV segments) and stitch the
  transcripts; until then add "Cloud transcription handles up to 5 hours per recording" to the FAQ `length` answer.

### S3. Import is not behind the paywall
- Only `home_screen.dart:32` and `notes_screen.dart:112` call `canStartRecording()`; nothing in
  `lib/features/import/*.dart` checks the entitlement or the free allowance, and the server has no entitlement check
  (anonymous users). A user who never pays can import unlimited files and get cloud transcripts and summaries, at our
  cost. "Import audio" is listed as part of Pro (`paywall_more.dart:80`).
- Fix: call `canStartRecording()` before starting an import (show the paywall otherwise) and count an import against
  the free allowance in `gate.onRecordingFinished`.

### S4. Paywall copy breaks if the intro offer is not attached in ASC (3.1.2 misleading trial)
- `planFromStore` sets `trialDays: 0` when the product has no free-trial intro offer
  (`storekit_billing_service.dart:363`), but `trialEligible` stays true, so the paywall shows "Try everything free for
  0 days" (`paywall_screen.dart:213-214`), "Free until <today>" (`trial_copy.dart:363`) and a "Start free trial"
  button while Apple charges at once. Attaching the offer is an owner task still open, so guard it.
- Fix: `final trial = billing.trialEligible && plan.trialDays > 0;` in `paywall_screen.dart:170` (and the same in
  `_Timeline`/`priceLine` callers).

### S5. Universal app with iPad landscape, but iPhone-portrait layouts
- `ios/Runner.xcodeproj/project.pbxproj:367,493,546` `TARGETED_DEVICE_FAMILY = "1,2"`; `Info.plist:95-101` allows all
  four iPad orientations; no `setPreferredOrientations` anywhere in `lib/`; fixed widths (e.g. paywall title
  `width: 300`, `paywall_screen.dart:205-206`; recording layout "Figma: x 245 of 393", `recording_screen.dart:778`).
  `launch/FACTS.md` says "iOS (iPhone)". App Review runs universal apps on an iPad, often in landscape.
- Fix: set `TARGETED_DEVICE_FAMILY = 1` (iPhone-only; still installable on iPad in compatibility mode), or test every
  screen on an iPad simulator in landscape before submitting.

### S6. App Privacy label plan predates the Meta SDK; honest ATT assessment
- `launch/app-store-listing.md` §6 (16 Nov): "no ad SDK, no IDFA, no ATT... Tracking: none". The build now ships
  FBSDKCoreKit 18.0.3 (`third_party/facebook_app_events/ios/facebook_app_events.podspec:20`) and the server sends
  StartTrial/Subscribe/Purchase to Meta's Conversions API.
- What actually leaves the device: the SDK is initialised only when "Share usage analytics" is on
  (`meta_sink.dart:83-98`), `FacebookAdvertiserIDCollectionEnabled`/`AutoLogAppEvents`/`AutoInit` are false in
  `Info.plist:41-48`, `setAdvertiserTracking` is never called with true (`attAuthorized` is hard-wired false via
  `NoTrackingConsent`, `app_services.dart:343`), so no IDFA and `advertiser_tracking_enabled=false`. App events:
  `activateApp` and `CompleteRegistration` only (`meta_sink.dart:77-79,127`). The SDK still sends Meta's anonymous
  install id plus device model/OS/locale/timezone (extinfo); the server repeats `anon_id` + extinfo with the money
  events. No `NSUserTrackingUsageDescription` in `Info.plist` (good). No `PrivacyInfo.xcprivacy` in `ios/Runner`
  (acceptable: the Runner target calls no required-reason API directly; Flutter and every pod ship their own; Meta's
  manifest declares `NSPrivacyTracking` and its tracking domains, which iOS blocks without ATT, so the ATE=false path
  is what runs).
- Risk, honestly: this is the standard "Meta without ATT" pattern. App Review does not detect it; the exposure is the
  label. Under Apple's definition, ad measurement that links to Meta's own data is tracking, and Meta's position is
  that ATE=false events are not. Owner decision for the label: either declare "Data Used to Track You: none" and rely
  on no-IDFA + ATE=false, or add ATT in a later build. Either way the label must now list the Meta install id (Device
  ID, Analytics/Advertising) and Purchase History going to Meta, and the listing §6 text must be rewritten so the
  label matches the build. Check the archive's aggregated privacy report (Xcode > Generate Privacy Report) before
  upload.

### S7. novaralabs.in pages are a JS-only shell titled "Figma Make App"
- `curl` of `/longnote/privacy`, `/terms`, `/support` and `/longnote` returns the same 1,158-byte shell:
  `<title>Figma Make App</title>`, meta description "Create stunning websites effortlessly with this user-friendly
  platform...", `robots noindex,nofollow`, and a nonsense path also returns 200. The policy text exists only in
  `assets/index-*.js` (confirmed: Soniox, OpenAI, Meta, Amplitude, "Last updated: November 19, 2026", refunds,
  Nagpur all present), so it renders in Safari for a reviewer; but anything that reads HTML (link previews, Apple's
  URL checks, screen readers before JS) sees a Figma template. The bundle also shows "Effective date: June 4, 2026",
  before the app existed.
- Fix: set a per-page title/description in Figma Make (or serve the static `launch/site/longnote/*/index.html`
  after refreshing it to the 19 Nov text), fix the effective date, and apply B2 there too.

## NICE

- N1. Review notes (`launch/app-store-listing.md` §7) name "Settings > Transcription & privacy"; the build has
  Settings › Privacy › "Transcription" and "What happens to your audio". Step 1 says a paywall opens first; onboarding
  does. Align while updating the notes.
- N2. `lib/features/settings/settings_screen.dart:189` hard-codes "Version 1.0.0"; the whole "Advanced" screen is the
  Material-styled v0.1 settings (summary engine, 148-488 MB whisper downloads, usage log) and looks like a different
  app next to the new design. Consider moving it behind the dev flag of B1.
- N3. Stale comments: `Info.plist:33-38` still says "the advertising ID only after the user allows tracking";
  `lib/core/analytics/amplitude_sink.dart:17` TODO refers to a "Delete my data" button that is not planned for v1.
- N4. `trial_copy.dart:342-352` `_currency` takes the prefix only; for suffix-currency locales ("59,99 €") the yearly
  card shows "5 / mo" with no currency sign.
- N5. The onboarding sample notes ("Q4 planning with the product team", `onboarding_content.dart:106`) carry no
  "Example" marker on screen (`onboarding_visuals.dart:215-220`); the lead-in "We'll show you what your notes look
  like" covers it, but a small "Example" chip removes any 2.3 doubt.
- N6. `privacy_screen.dart:38` says the transcript is "sent to your phone and then deleted from our server"; the
  server keeps results 24 h after fetch / 7 days if never fetched (`cleanup/index.ts:3`, policy §5 says so). Say
  "within 24 hours" in the app too.

## Checked and OK

- 3.1.2 paywall (`paywall_screen.dart`, `paywall_more.dart`, `trial_copy.dart`): product name "Longnote Pro ·
  auto-renewing subscription" (:231); both plans with store price and period, yearly preselected, Save %; timeline with
  real dates (today / reminder / charge); the fixed footer line "Free until <date>, then <price> a year. Cancel any time
  in Settings → Apple ID." or, without trial, "<price> a year, charged today and renewed until you cancel" (:304,
  `trial_copy.dart:359-367`); Start free trial / Subscribe button; Restore purchase, Terms, Privacy links (:309-317);
  Close X at top right, immediate (:190-197); no delayed close, no weekly plan, no fake reviews, no "limited time".
  Restore distinguishes "no purchase" from "could not reach the App Store" (:142-146).
- Claims vs code: "60+ languages" = 62 entries in `lib/core/notes/languages.dart` + auto + Hinglish; "9 summary
  styles" = 9 `SummaryStyle` values; "remind you a day before" = local notification 26 h before the charge
  (`trial_reminder.dart:12-16`, `config.dart:46`), only with permission, which is asked on the trial-started screen
  with the reason on screen; "deleted from their servers and ours as soon as the transcript is back" matches
  `cleanup`/`soniox.ts` deletion and policy §5; "Audio saved on your phone as you record" = 5-minute WAV segments with
  1 s fsync (`config.dart:18-22`); the "first recording is free" FAQ is shown only on the first-run paywall (:275).
- 3.1.1/3.1.3: no external purchase or pricing links anywhere (`AppLinks` is the single list, `links.dart`);
  "Cancel or change plan" opens `itms-apps://apps.apple.com/account/subscriptions` with https and a text fallback
  (`plan_screen.dart:23-29`). Terms + Privacy are in the description and on the paywall; Apple's standard EULA is
  referenced in the Terms §15.
- Entitlement: StoreKit 2 is the only source (`AppDelegate.swift` StorePlugin: verified transactions only,
  `Transaction.updates` listened from first call, `currentEntitlements` with `revocationDate == nil`, `AppStore.sync`
  on restore); nothing in `lib/` reads server subscription state. Default billing on iOS is the real store with no
  define needed (`app_services.dart:357-361`); `LN_BILLING=fake` is used only by the simulator QA suite and the
  TestFlight workflow passes no such define, so the "Test build: purchases are simulated" chip cannot show in release.
- 5.1.1 permissions: `NSMicrophoneUsageDescription` present and specific (`Info.plist:27-28`), asked on the onboarding
  "Allow microphone" screen with the reason, denied path explained (`onboarding_screen.dart:138`,
  `recording_screen.dart:155-156`). Notifications asked only after a trial starts, with the reason (`trial_started_screen.dart`),
  `requestAlertPermission` etc. false at init. No speech-recognition, photo-library, camera or location usage: import
  uses the document picker (`FileType.custom`/`FileType.video`, `import_controller.dart:63-68`), which needs no
  purpose string. No `NSUserTrackingUsageDescription` leftover.
- Data vs policy: policy (19 Nov) names Supabase, Soniox, OpenAI, Amplitude, Meta, Apple, retention table, no-training
  statement, Support-ID deletion by email, GDPR/DPDP controller, contact email; the in-app "What happens to your audio"
  screen matches it (bar B2/N6). Terms: 3-day trial, $9.99/$59.99, auto-renew, 24 h cancel rule, refunds via Apple,
  consent-to-record section, age 13+, India/Nagpur law, Apple EULA. Support page: email, 2-working-day reply, cancel,
  restore, delete-data.
- 2.1 completeness: no "coming soon", lorem or placeholder strings in `lib/` (the only "Not available in this build
  yet" is shown when the backend is not configured, never in CI builds); every URL the app opens is in
  `links.dart` and all four load (200); mail fallback copies the address when no mail app; offline states exist for
  processing ("Waiting for internet", auto-upload), Ask ("You are offline"), restore; `StartupFailedApp` with retry
  on boot failure; empty states in Notes/Usage log.
- 2.5.4: `UIBackgroundModes = audio` only; session `playAndRecord` + `defaultToSpeaker|allowBluetooth`
  (`pcm_source.dart:47-51`), used for the user's recording and playback of their own notes.
- Legal copy: recording-others consent is on the onboarding "Plainly, before you start" screen (`onboarding_screen.dart:524`),
  in the privacy screen (:53-54), the Terms §5 and the review notes.
- Release config: `ITSAppUsesNonExemptEncryption = false` set (`Info.plist:60-61`); `version: 1.0.0+1` with the
  build number from `github.run_number + 100` in the workflow; deployment target iOS 16; Meta keys injected at build
  only when both secrets exist, else the SDK stays off; API key deleted from the runner; bundle id
  `com.novaralabs.longnote` matches ASC app 6835017154.
- Server notifications: JWS chain verified to Apple Root CA G3 (`appstore_jws.ts`), bundle-id check, environment in
  {Production, Sandbox}, optional `APPLE_APP_ID` check on Production, sandbox never reaches Meta without a test code
  (reviewed 19 Nov, unchanged).
- Cleanup: hourly pg_cron; audio deleted at job end and swept at 24 h; Soniox copies deleted; orphan sweep.

## Not done
- `flutter test` / `flutter analyze` were not run: the working tree was mid-edit by another session (26 files). Run
  them on the commit that goes to TestFlight.
- No device run; the iPad check in S5 is from the project settings and layout code only.
