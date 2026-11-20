# Analytics: Amplitude + Meta App Events

Added 18 Nov 2026 (branch v1-build). Code: `lib/core/analytics/`.

## How it works

- `Analytics.log(name, recordingId, props)` writes every event to the local
  sqflite log (as before), then forwards it to the remote sinks while
  **Settings > Privacy > Share usage analytics** is on (default ON, KV key
  `set_share_analytics`).
- Before anything leaves the phone, `remoteSafeProps()` (remote_analytics.dart)
  drops any key that is or contains `title`, `text`, `transcript`, `summary`,
  `name`, `file`/`filename`, `path`, `question`, `answer`, `speaker(s)`,
  `body`, `content`, `email`, `phone`, `subject`, `message`, `query`, `prompt`;
  drops lists/maps; and turns any string that is not a short code
  (`^[A-Za-z0-9_.:+-]{1,64}$`) into `other` (so an exception message with a
  file path can never be sent).
- Sinks: `AmplitudeSink` (all events) and `MetaSink` (app activation +
  CompleteRegistration only).
- **Money events come from the server** (18 Nov 2026, section "Server
  events" below): Apple's App Store Server Notifications V2 -> our Supabase
  function -> Meta Conversions API + Amplitude HTTP API. The app sends no
  Meta StartTrial / Subscribe and no Amplitude revenue, so nothing is counted
  twice.
  Tests and simulator QA have no sinks or fakes: no network, no SDK.
- Every whole-app flow test (`test/flows/`) checks at tear-down that no event
  has a forbidden key and nothing forwarded contains a note title.

## Events

| Event | Props | Local | Amplitude | Meta |
|---|---|---|---|---|
| recording_started | recording_id | yes | yes | - |
| recording_completed | duration_ms, reason | yes | yes | - |
| recording_interrupted | cause, at_ms or saved_ms/segments/repaired_files/last_heartbeat_age_s | yes | yes | - |
| recording_recovered | saved_ms, segments, repaired_files, last_heartbeat_age_s | yes | yes | - |
| processing_failed | attempt, final, error (a code; free text sent as `other`) | yes | yes | - |
| processing_retried | manual, attempt | yes | yes | - |
| transcript_viewed / summary_viewed | recording_id | yes | yes | - |
| export | kind, via | yes | yes | - |
| paywall_viewed | placement (`first_run` / `second_recording`) | yes | yes | - |
| trial_started | source `app`, plan, period, price, currency, trial_days, trial_ends_at | yes | yes (no revenue) | - (server sends StartTrial) |
| subscription_purchased | source `app`, plan, period, price, currency | yes | yes (**no revenue**: the server sends it) | - (server sends Subscribe) |
| restore_tapped | from (`paywall`/`settings`/`plan`/`settings_old`) | yes | yes | - |
| restore_result | from, result (`restored`/`none`/`failed`), active | yes | yes | - |
| onboarding_completed | mic (`allowed`/`denied`) | yes | yes | **CompleteRegistration** |
| att_result | status (`authorized`/`denied`/`restricted`/`notSupported`) | yes | yes | - |
| onboarding_step | step, index, dir (`forward`/`back`) | yes | yes | - |
| paywall_faq_opened | faq (question id) | yes | yes | - |
| screen_viewed | screen (route name, `R.*` in app/routes.dart) on every route change: tab switch, push, sheet, pop back; never twice in a row (`lib/app/screen_tracker.dart`, attached in `LongnoteApp`) | yes | yes | - |
| paywall_plan_selected | plan (store product id), placement (only when the plan changes) | yes | yes | - |
| paywall_purchase_tapped | plan, placement | yes | yes | - |
| paywall_purchase_result | plan, placement, result (`purchased`/`cancelled`/`pending`/`failed`, from `PurchaseResult.outcome`) | yes | yes | - |
| paywall_closed | placement, how (`close_button`/`purchased`/`restored`/`system_back`; a plan that shows up while open = `restored`) | yes | yes | - |
| paywall_more_opened | placement ("See everything you get") | yes | yes | - |
| mic_permission | result (`allowed`/`denied`), from (`onboarding`; `record` = Start refused for no mic, logged only on `denied`) | yes | yes | - |
| notification_permission | result (`allowed`/`denied`/`skipped` = our own ask declined, iOS never asked), from (`trial_started`/`plan`/`note_ready`) | yes | yes | - |
| recording_paused / recording_resumed | recording_id (user taps only) | yes | yes | - |
| recording_discarded | recording_id, duration_s | yes | yes | - |
| search_used | chars_bucket (`1-3`/`4-10`/`11+`, longest query of the visit), opened (a result was opened); once per visit to Search, never the text | yes | yes | - |
| note_renamed | recording_id, from (`actions`/`record`) | yes | yes | - |
| note_deleted | recording_id | yes | yes | - |
| speaker_renamed | recording_id, count (never the names) | yes | yes | - |
| summary_style_changed | style (id), from (`note`/`settings`/`onboarding`); note: recording_id, custom (own instructions given; never their text), as_default | yes | yes | - |
| playback_started | recording_id (first play of a note's audio while it is open) | yes | yes | - |
| ask_sent | recording_id, from (`composer`/`starter`/`follow_up`/`retry`), screen (`ask_tab`/`note`); never the question | yes | yes | - |
| ask_answered | recording_id, result (`ok`/`failed`); never the answer | yes | yes | - |
| import_started | kind (`audio`/`video` by extension), format (extension) | yes | yes | - |
| import_completed | recording_id, kind, format, duration_s | yes | yes | - |
| import_failed | kind, format, error (`no_sound`/`disk_full`/`copy_failed`/`failed`/`cancelled`) | yes | yes | - |
| setting_changed | setting (`audio_language`/`summary_language`/`transcription_mode`/`default_style`/`speaker_labels`/`share_analytics`), value (a code: language code, `same`, mode, style id, `on`/`off`) | yes | yes | - |
| share_analytics_off | (none) - logged BEFORE the switch stops the sinks, so it is the last event sent; turning it back on logs setting_changed share_analytics=on | yes | yes | - |
| rate_tapped | (none) - the button opens the App Store review page (`AppLinks.appStoreReviewUrl`), not Apple's in-app prompt | yes | yes | - |
| support_tapped | kind (`help`/`feature`) | yes | yes | - |
| manage_subscription_tapped | from (`plan`: G4 "Cancel or change plan") | yes | yes | - |
| legal_link_opened | link (`terms`/`privacy`), from (`paywall`/`settings`) | yes | yes | - |
| delete_data_confirmed | reserved: not fired yet (there is no "Delete my data" screen; see below) | - | - | - |
| (Amplitude autocapture) | session start/end, Application Installed / Updated / Opened / Backgrounded | - | yes | - |
| (Meta) | app activation (`activateApp`, at launch and each return to the app; gives install attribution) | - | - | yes |

`recording_id` is the random note id (a UUID), never the title.

Trial -> paid conversion, renewals, cancellations and refunds happen at Apple,
not in the app: the server events below cover them.

## Server events (App Store Server Notifications V2)

Code: `supabase/functions/appstore-notifications/` + `_shared/appstore_events.ts`
(mapping) + `_shared/appstore_jws.ts` (Apple signature check). Contract:
BACKEND-API.md 4.6-4.7. URL registered in App Store Connect for Production and
Sandbox, Version 2 (set through the App Store Connect API, 18 Nov 2026).

How a purchase is linked to a user: the app passes `appAccountToken` = the
Supabase anonymous user id to StoreKit; Apple puts it in every signed
transaction. After a reinstall (new anonymous user) the app's tracking
profile carries StoreKit's Apple-signed current transaction; the server
verifies it and re-links the subscription to the new user.

| Apple notification | Amplitude event (`source: server`) | Amplitude revenue | Meta event |
|---|---|---|---|
| SUBSCRIBED, free-trial intro offer | appstore_trial_started | - | **StartTrial** (currency, no value) |
| SUBSCRIBED, paid (no trial) | appstore_subscribed | +price, type `subscription` | **Subscribe** (value, currency) |
| DID_RENEW, first payment after the trial | appstore_trial_converted | +price, `subscription` | **Subscribe** (value, currency) |
| DID_RENEW, later (incl. BILLING_RECOVERY) | appstore_renewed | +price, `renewal` | **Purchase** (value, currency) |
| DID_CHANGE_RENEWAL_PREF UPGRADE | appstore_plan_upgraded | +price, `upgrade` | **Purchase** |
| DID_CHANGE_RENEWAL_PREF (other) | appstore_plan_change | - | - |
| REFUND | appstore_refunded | **-price**, `refund` | - |
| REFUND_REVERSED / REFUND_DECLINED | appstore_refund_reversed (+price) / appstore_refund_declined | | - |
| EXPIRED, GRACE_PERIOD_EXPIRED | appstore_expired | - | - |
| DID_CHANGE_RENEWAL_STATUS | appstore_auto_renew_on / _off | - | - |
| DID_FAIL_TO_RENEW | appstore_billing_issue | - | - |
| REVOKE / OFFER_REDEEMED | appstore_revoked / appstore_offer_redeemed | - | - |
| TEST, others | (stored only) | | |

Choices and why:
- **Subscribe for the first payment** (trial conversion or direct paid) is the
  conversion to optimise on; it lands inside Meta's 7-day click window (the
  trial is 3 days). **Renewals are Purchase** with value, so Meta's revenue
  (ROAS) reporting includes them; a monthly renewal comes ~33 days after
  install, outside the attribution window, so it does not disturb campaign
  optimisation. Refunds are not sent to Meta (Meta has no negative event);
  Amplitude gets negative revenue.
- "First payment after the trial" uses our stored state of the subscription
  (last offer = free trial, no payment yet). If we never saw the SUBSCRIBED
  (e.g. before this endpoint), a production DID_RENEW less than 14 days after
  the original purchase counts as the conversion (`inferred: true`); sandbox
  never guesses (its time is compressed).
- Price: Apple's `price` is in milliunits -> `price / 1000`, storefront currency.
- Dedupe: Amplitude `insert_id` and Meta `event_id` = Apple's
  `notificationUUID`; the DB claims each notificationUUID once
  (`ln_appstore_claim`), so Apple's retries never send twice.

Opt-out and privacy:
- Nothing is sent for a user without a tracking profile or with
  `share_analytics = false` (the Settings switch; the app then sends only
  `{share_analytics: false}` and the server wipes the rest). The subscription
  state is still recorded (no third party involved).
- Meta: `action_source: app`, `user_data.anon_id` = the Meta SDK's anonymous
  install id from the app, `app_data.advertiser_tracking_enabled` = the ATT
  answer (0 unless "Allow"), `application_tracking_enabled` 1 (switch on),
  `extinfo` (16 fields from the app's DeviceInfoPlugin). No IP, no IDFA (the
  server never has them), no user id. No anon id -> not sent.
- Amplitude: `user_id` = Supabase user id (same as the app's), no `ip`, no
  IDFA/IDFV, no location: the request comes from Supabase, so no user IP can
  reach Amplitude. Server events carry `app_version` only.
- Sandbox (TestFlight) notifications are processed and flagged (`sandbox:
  true` in Amplitude). They go to Meta only through the Conversions API and
  only with `META_TEST_EVENT_CODE` set (as Test Events); a production event
  never carries the test code.
- Meta older than 7 days -> not sent (`too_old`).

Meta paths (chosen by the secrets that exist): Conversions API
`POST graph.facebook.com/{META_GRAPH_VERSION|v24.0}/{META_DATASET_ID}/events`
with `META_CAPI_TOKEN` (set 18 Nov; dataset linked to app 1513011100880971);
fallback App Events API `POST /{META_APP_ID}/activities` with the app token
`{META_APP_ID}|{META_APP_SECRET}` (Meta no longer recommends it; not
configured). Neither -> Meta skipped (logged once per instance), Amplitude
still sent.

Where to look: `appstore_notifications` (one row per notification: `kind`,
`plan`, `meta_result`, `amplitude_result`), `subscriptions`,
`tracking_profiles`. Function logs never contain tokens.

## Identity

- Amplitude user id = the Supabase anonymous user id (`SupabaseAuth`
  session; set at launch from the stored session without a network call, and
  again whenever a new anonymous user is created).
- Amplitude device id = random UUID (IDFV off).
- Meta gets no user id. The app reads the Meta SDK's anonymous install id
  (`getAnonymousId`, only while sharing is on) and sends it in the tracking
  profile, so server events match the app's install.

## Privacy settings in code

Amplitude (`AmplitudeSink.configuration`): server zone US; tracking options
`ipAddress`, `city`, `dma`, `region`, `carrier`, `idfv`, `adid`, `appSetId`,
`latLag` all off (so Amplitude never receives the IP address); no IDFA
(no IDFA plugin; `useAdvertisingIdForDeviceId` false); autocapture: sessions +
app lifecycles only; opt-out = `setOptOut(true)`.

Meta (Info.plist + `MetaSink`):
- `FacebookAutoInitEnabled` = false: the SDK starts only when the app calls
  `initializeSdk()`, i.e. only while sharing is on.
- `FacebookAutoLogAppEventsEnabled` = false: no automatic events and no
  automatic in-app-purchase logging (no double count with our Subscribe /
  StartTrial). The app calls `activateApp()` itself.
- `FacebookAdvertiserIDCollectionEnabled` = false, and the app always calls
  `setAdvertiserIdCollectionEnabled(false)`: no IDFA (no ATT prompt in v1).
- `FBSDKAutoLogMetaDataEnabled` = false and `setAutoLogMetaDataEnabled(false)`
  at start. The app pins Meta SDK 18.0.3 (third_party/facebook_app_events),
  which has no metadata collection; SDK 19+ would attach screen titles and URLs.
- `SKAdNetworkItems`: `v9wttpbfk9.skadnetwork`, `n38lu8286q.skadnetwork`
  (checked against Meta's SKAdNetwork page on 18 Nov 2026).
- No `CFBundleURLTypes` / `LSApplicationQueriesSchemes`: only needed for
  Facebook Login / sharing, which we do not use.

ATT: none in v1 (owner, 18 Nov 2026). The app uses `NoTrackingConsent`, has
no `NSUserTrackingUsageDescription` and no tracking plugin; Meta never gets
the IDFA. Trial and subscription events come from the server (section above).

## Keys and builds

| Value | Where it comes from | How it reaches the app |
|---|---|---|
| Amplitude API key (project 909345, US) | GitHub secret `AMPLITUDE_API_KEY` | `--dart-define=AMPLITUDE_API_KEY` in ios-testflight.yml |
| Meta App ID | GitHub secret `META_APP_ID` | PlistBuddy writes `FacebookAppID` into Info.plist at build time + `--dart-define=META_APP_ID` (switches Meta on in Dart) |
| Meta client token | GitHub secret `META_CLIENT_TOKEN` | PlistBuddy writes `FacebookClientToken` into Info.plist at build time |
| Amplitude SECRET key | `/root/.secrets/longnote/.env` only | never in the app or CI |

These values ship inside the app and are not secret, but the repo is public,
so they stay out of git and are masked in CI logs. A build without them
(local, simulator QA, ios-build-check) has Amplitude and Meta switched off and
has no Meta at all. Simulator QA also passes `LN_TRACKING=off`.
The workflow fails if only one of META_APP_ID / META_CLIENT_TOKEN is set
(initializing Meta without an app id in Info.plist would crash).

## Dashboard settings (manual, not in code)

- Amplitude: set data retention (TTL) to 12 months (ask Amplitude support;
  the Free plan keeps 1 year). Optionally ask support to "drop IP addresses
  after ingestion" as a second guard. Turn off Amplitude AI features if wanted.
- Meta Events Manager: turn off "Log in-app events automatically" and
  "Automatically include more app event details" for the app (belt and braces
  with the Info.plist keys); add the iOS bundle id `com.novaralabs.longnote`
  and App Store id; check that SKAdNetwork is on.

## Delete my data

Not built yet. When it is: a Supabase function (holding
`AMPLITUDE_SECRET_KEY`) must call Amplitude's User Privacy (deletion) API for
the user id + device id; the app must not call it (TODO in
`amplitude_sink.dart`). Meta: no user id is sent; the app can call
`clearUserData()` and stop logging.

## To-do for the launch session (do NOT edit launch/ from here)

The launch docs were written for "Amplitude only, no tracking". Meta + ATT
change that. Needed:

Privacy policy (launch/privacy-policy.md):
1. Section 2 "No ads. No ad tracking...": now false. Say: no ads in the app;
   we measure our own ads on Meta (Facebook/Instagram).
2. Section 3 "We do not collect your Apple advertising ID (IDFA) ... the app
   never shows Apple's Allow tracking prompt": now false. IDFA is shared with
   Meta only if the user taps "Allow" in Apple's prompt.
3. New section "Advertising measurement (Meta)": what is sent (app install /
   open, onboarding finished, trial started, subscription bought with price and
   currency, device data the Meta SDK collects: device model, OS, app version,
   IP address at Meta, IDFA only with permission); purpose (measure which ads
   work; Meta may also use it to optimise ad delivery); Meta Platforms, Inc.
   as a third party with its own privacy policy and data policy link; how to
   say no (Apple's prompt; Settings > Share usage analytics; iOS Settings >
   Privacy > Tracking).
4. Section 7 processors table: add Meta Platforms, Inc. (USA/Ireland) - note
   Meta is a third party, not purely our processor, for ad measurement.
5. CCPA paragraph "We do not sell or share personal information": sharing
   device/purchase events with Meta for ad measurement is likely "sharing for
   cross-context behavioural advertising". Needs a lawyer's view; at minimum
   describe it and the opt-out.
6. GDPR legal basis: ad measurement with IDFA -> consent (ATT). Without IDFA,
   the opt-out switch; EU may need opt-in (lawyer).
7. Section 6 Amplitude list: add restore tapped/result, onboarding completed,
   ATT answer. Settings path is "Settings > Privacy > Share usage analytics"
   (matches the app).
8. Section 9 "Delete my data": add that Meta receives no user id; deletion
   flow still to be built.

App Store privacy label (launch/app-store-listing.md section 6):
1. "Tracking" is now YES. Remove "no IDFA, no ad SDK, no ATT prompt".
2. "Data Used to Track You": Identifiers > Device ID (IDFA, when allowed);
   Purchases > Purchase History; Usage Data > Product Interaction (install,
   onboarding finished, trial, subscription) - all for Third-Party Advertising /
   ad measurement (Developer's Advertising or Marketing).
3. Data linked to you (Amplitude, unchanged): User ID, Device ID, Product
   Interaction, Purchase History, Diagnostics - Analytics.
4. Meta SDK also collects coarse device data and IP at Meta: check Meta's
   current "App Store privacy details" guidance for FBSDKCoreKit 19 and add
   anything it lists (e.g. Coarse Location if Meta derives it from IP).
5. App Review: ATT prompt text must match what the app does; the listing and
   review notes should say the app requests tracking permission for ad
   measurement only.

Vendor check (launch/vendor-terms-check.md): add a Meta section (Business
Tools Terms, data use for ads, retention, EU data transfer).

In-app text already changed in this build: Settings > Privacy > "What happens
to your audio" now has a "Usage analytics" section naming Amplitude and Meta,
and "What we never do" no longer says "no tracking SDKs".
