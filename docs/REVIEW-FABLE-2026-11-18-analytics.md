# Review: analytics commits 6a895ff + 4df1d6c (branch v1-build)

Reviewer: Fable 5.1, 18 Nov 2026. Scope: Amplitude + Meta App Events + ATT +
"Share usage analytics" switch (6a895ff) and the privacy screen / Support ID /
hidden iCloud switch (4df1d6c). Read against docs/ANALYTICS.md and
docs/store/website/privacy.md, the package sources in ~/.pub-cache
(amplitude_flutter 4.8.2, facebook_app_events 0.34.0,
app_tracking_transparency 2.0.7) and all 27 `analytics.log` call sites.

## Verdict: APPROVED

No blocker, no major. The privacy promises in privacy.md are true of the
code as shipped: no note content, title, transcript, speaker name or file
path can reach Amplitude or Meta from any existing call site; the Amplitude
privacy flags map to real native calls; Meta is init-gated, auto-logging is
off, IDFA collection follows ATT; the switch is persisted and read at
launch; builds without keys never touch either SDK or the ATT prompt.

`flutter analyze`: No issues found.
`flutter test`: 261 tests, all passed (48 s).

Six minor findings follow. None needs to hold the TestFlight build; two
(M1, M2) are wording fixes in privacy.md the launch session should pick up.

## Checks that passed (with the evidence)

Privacy
- Sanitiser (lib/core/analytics/remote_analytics.dart:33-94): a key denylist
  (whole key and each `_`/`-`/`.`/camelCase part) plus a value shape rule:
  strings must match `^[A-Za-z0-9_.:+\-]{1,64}$` or become `other`; lists,
  maps and nulls are dropped. It is a denylist on keys, but the shape rule
  is what actually stops free text. Every call site's string props are
  app-chosen codes: status/from/result/plan/period/currency/placement/mic/
  kind/via/cause/reason; the only free-text source is
  `processing_failed.error` = `code ?? _short(e)` (job_queue.dart:289-296),
  where `_short(e)` is an exception `toString()` up to 300 chars; anything
  with a space, slash or quote becomes `other`. `recording_id` is the note
  UUID. No call site passes a title, transcript, file path or speaker name.
- Amplitude (amplitude_sink.dart:36-60): TrackingOptions fields exist in
  4.8.2 (tracking_options.dart) and the Swift plugin maps
  `ipAddress=false` -> `disableTrackIpAddress()`, `idfv=false` ->
  `disableTrackIDFV()`, region/dma/city/carrier likewise
  (SwiftAmplitudeFlutterPlugin.swift:297-343). `adid`, `appSetId`, `latLag`,
  `locationListening` are Android-only no-ops on iOS (harmless). IDFA needs
  the optional Amplitude IDFA plugin, which is not added. `optOut` is passed
  in `init` and `setOptOut` maps to `amplitude.optOut` (lines 161-174).
  Device id = random UUID once IDFV is off. US server zone.
- Meta (meta_sink.dart + Info.plist): `FacebookAutoInitEnabled=false` makes
  the plugin skip `initializeSDK()` at registration and reject every other
  method with `sdk_not_initialized` until Dart calls `initializeSdk()`
  (FacebookAppEventsPlugin.swift:48-54, 128-139). Order in `activate()` is
  init -> metadata off -> advertiser-id = ATT answer -> `activateApp()`.
  `FacebookAutoLogAppEventsEnabled=false` stops automatic events and the
  SDK's own IAP logging, so Subscribe/StartTrial are not double counted.
  `setAdvertiserIdCollectionEnabled` maps to the persisted
  `Settings.shared.isAdvertiserIDCollectionEnabled` (line 454-458); it is
  true only after `AttStatus.authorized`, and iOS zeroes the IDFA anyway
  when not authorized. Meta gets no user id (`setUserId` is a no-op).
- Switch: `AppServices.setShareAnalytics` persists `set_share_analytics`
  then calls `Analytics.setRemoteEnabled`, which both stops forwarding in
  `Analytics.log` (analytics.dart:121) and calls `setEnabled(false)` on each
  sink (Amplitude `setOptOut(true)`, Meta `_enabled=false`). At launch
  `create()` reads the setting and builds Amplitude with `optOut: !share`
  and Meta with `enabled: share`, so Meta is never initialised while off.
- ATT: `askTrackingOnce` (app_services.dart:182-201) is the only prompt
  call and runs once from onboarding `_finish` (onboarding_screen.dart:42)
  after the StoreKit refresh, before the first paywall. It returns early
  when Meta is absent (`meta == null`: local builds, tests, sim QA with
  `LN_TRACKING=off`, ios-build-check) or sharing is off; it never prompts
  when iOS already has an answer; `_untilActive` waits for `resumed` plus
  400 ms so iOS does not drop the request while the mic dialog is closing.
  Tests use `NoTrackingConsent` and a fake Meta. The Info.plist usage
  string matches what the app does.

Crash safety
- The committed Info.plist has no FacebookAppID/ClientToken; with auto-init
  false and no `META_APP_ID` dart-define the SDK is never initialised, so
  ios-build-check, local runs and sim QA cannot hit the missing-app-id
  exception. The TestFlight workflow writes both keys or fails
  (ios-testflight.yml:107-112) and only adds the dart-define inside that
  branch, so Dart can never think Meta is on while the plist lacks the id.
- Every sink call is inside try/catch; `Analytics.log` swallows everything;
  `AmplitudeSink.create` caps start-up wait at 3 s. `logPurchase` is
  awaited on the purchase path but each native call is a method-channel
  round trip that returns immediately (see M3 for the residual risk).

Revenue/events
- `startedTrial` comes from the post-purchase entitlement status
  (storekit_billing_service.dart:250-251), i.e. Apple's answer, not the
  eligibility guess. Currency comes from
  `product.priceFormatStyle.currencyCode` (AppDelegate.swift:136) and is
  carried on `Plan.currency`. Restore logs `restore_tapped`/`restore_result`
  only, never a purchase. Entitlements arriving via the listener (Ask to
  Buy approved later) close the paywall without logging (see M4). The only
  `billing.purchase` call site is the paywall, so no double logging.

CI/secrets
- No `set -x`; secrets are used only inside `[ -n ]` tests, PlistBuddy
  arguments and `--dart-define`, none echoed. The plist edit happens on the
  runner only; nothing is committed or pushed. `AMPLITUDE_API_KEY` and
  `META_CLIENT_TOKEN` are masked. The Amplitude SECRET key appears nowhere
  in lib/, ios/, pubspec or workflows (grep), only as a TODO comment.

4df1d6c
- Support ID = `auth.knownUserId()` -> `_current()` -> kv read, no network
  (supabase_auth.dart:139-145). It is the same id used as the Amplitude
  user id, so the deletion-by-email flow in privacy.md section 10 can work.
  Copy uses `Clipboard.setData` + toast; `context.mounted` is checked.
  Privacy screen text matches privacy.md on OpenAI 30 days, iCloud = the
  user's own device backup, Amplitude/Meta and the switch path.
- Removing the iCloud switch leaves `excludeFromBackup()` default false, so
  recordings stay in the device backup. `AppServices.create` still reads the
  key (app_services.dart:438) and only acts when it is true; nothing else
  reads it. Test updated to assert the switch is gone and the default holds.

## Findings (ranked)

### Minor

M1. privacy.md over-states what Amplitude receives.
docs/store/website/privacy.md:92 and :44 list "subscription ... renewed or
cancelled" and "settings changed" as events sent to Amplitude. The app sends
neither: renewals/cancellations happen at Apple (ANALYTICS.md says so) and no
`settings_changed` event exists (analytics.dart:11-47). Failure scenario: a
reader or App Review compares the policy with the app's traffic and finds
the policy claims data flows that do not exist; harmless to users but
inaccurate. Fix in the launch session: drop "renewed or cancelled" and
"settings changed", or add the events.

M2. "After that, no events are sent" is true from the next flush, not the
instant the switch is flipped.
lib/core/analytics/amplitude_sink.dart:436 and meta_sink.dart:668-671.
`setOptOut(true)` stops Amplitude accepting new events, but events already
in its on-device queue (up to 30 s / 30 events old) are still uploaded by
the native flush timer; Meta's `setEnabled(false)` only sets a Dart flag,
and the already-initialised SDK flushes its queue on its own 15 s timer or
on backgrounding. Scenario: user finishes onboarding (CompleteRegistration
queued), opens Settings within 15-30 s and turns the switch off; that event
still leaves the phone. Not a bug in the code, but privacy.md:100 and :128
say "no events are sent ... after that". Either accept (standard SDK
behaviour) or soften the policy wording to "no new events".

M3. No timeout on the awaited analytics calls in the purchase path.
lib/features/paywall/paywall_screen.dart:118 awaits `s.logPurchase`, which
awaits up to three method-channel calls (Amplitude track, Amplitude revenue,
Meta logSubscribe/logStartTrial). They cannot throw past the try/catch, but
they can hang if a native handler never calls `result` (for example a
plugin bug after `initializeSdk()` during a cold Meta gatekeeper fetch).
Scenario: the charge succeeded, `_busy` is already false, but the paywall
neither closes nor navigates to the trial screen; the user sees a stuck
sheet and may tap Buy again (StoreKit would refuse the duplicate, but it is
a bad moment). Suggest wrapping each sink call in `Analytics.log` with
`.timeout(const Duration(seconds: 2), onTimeout: () {})`, or `unawaited`
on the purchase path.

M4. Purchases approved later (Ask to Buy / "pending") are never logged.
lib/features/paywall/paywall_screen.dart:107-111 and :63-66. A `pending`
purchase returns `success: false`; when the entitlement arrives later,
`_onEntitlement` closes the paywall without `logPurchase`. Scenario: a
teen's parent approves the purchase ten minutes later; Amplitude revenue
and Meta Subscribe never see it, so ad ROAS is under-counted for family
accounts. Measurement gap only; document in ANALYTICS.md or log from the
entitlement change when the previous status was `none` and `_buying` was
set.

M5. The ATT "may ask another time" path has no second caller.
lib/app_services.dart:194-198 resets `kvAttAsked` to false when iOS
returned `notDetermined` (prompt not shown because the app was not active),
but `askTrackingOnce` is only called from onboarding `_finish`, which runs
once. Scenario: the mic dialog is still closing, `_untilActive` times out at
3 s, iOS drops the request; that user is never asked, and Meta runs without
IDFA for them forever. Not a privacy problem (default is off), only a
measurement loss. If it matters, call `askTrackingOnce()` again at the
first paywall open or the first app resume.

M6. Testers from build 109 who turned iCloud backup off keep that hidden
state. lib/app_services.dart:438 still applies `excludeFromBackup()` when
true, and 4df1d6c removed the only UI that could set it back to false.
Scenario: a TestFlight tester who flipped the switch in build 109 updates
to this build; their recordings stay excluded from iCloud backup with no
way to change it, while the privacy screen now says notes are part of the
device backup. Affects TestFlight testers only (no App Store build has
shipped). Options: reset the key once on upgrade, or leave as is and note
it in the TestFlight notes.

### Notes (no action needed)

- `FBSDKAutoLogMetaDataEnabled` in Info.plist is the key name the plugin's
  README documents for FBSDK 19; the runtime `setAutoLogMetaDataEnabled(
  false)` right after init is persisted and overrides the plist anyway, so
  even a wrong key name would be covered.
- Only `AMPLITUDE_API_KEY` and `META_CLIENT_TOKEN` are masked; `META_APP_ID`
  is a public numeric id. Dart-defines also reach the xcodebuild log in
  base64 form (Generated.xcconfig `DART_DEFINES`) if a script phase fails;
  since all three values ship inside the IPA this is not a secret leak.
- Sharing is default-on and Meta's `activateApp` (install/open event, no
  IDFA) fires at first launch before onboarding. The policy discloses it;
  whether EU users need opt-in instead is the lawyer item already listed in
  ANALYTICS.md, not a code defect.
