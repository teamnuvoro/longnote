# Review: Meta SDK 18.0.3 pin + links (commit 5b06d12) — 18 Nov 2026

Reviewer: Fable. Scope: diff-only, short. Analytics design already approved in
REVIEW-FABLE-2026-11-18-analytics.md.

## Verdict: APPROVED

CI compile-only build was still running at review time; this verdict is on the
code and the claims, not on the build result.

## What I checked

**Vendored copy vs pub.dev 0.34.0** (`diff -r` against
`~/.pub-cache/hosted/pub.dev/facebook_app_events-0.34.0`): only three changes,
all intended.
- `ios/facebook_app_events/Package.swift`: `"19.0.0"..<"20.0.0"` -> `exact: "18.0.3"`.
- `ios/facebook_app_events.podspec`: `'~> 19.0'` -> `'18.0.3'`.
- `FacebookAppEventsPlugin.swift` line 386: `Settings.shared.isMetaDataCollectionEnabled = enabled` -> no-op.
- Omitted dirs: `example/`, `test/` (fine).

**Claims, checked against facebook-ios-sdk tag v18.0.3** (sparse clone,
commit 8c90832, dated 2026-02-10) and the main-branch CHANGELOG:
- "SDK 18 has no metadata collection": TRUE. No `isMetaDataCollectionEnabled`,
  `MetaDataCollection`, `AutoLogMetaData` or `screenTitle` symbol anywhere in
  the 18.0.3 FBSDKCoreKit tree. The changelog introduces "Screen Title and
  AppLink URL ... opt-out via `FBSDKAutoLogMetaDataEnabled`" in **19.0.0**
  (2026-09-24). The 18.x client has no collector code, so Meta's 31 Oct 2026
  server-side switch cannot turn it on for this build.
- "18.1.0-19.0.1 ship an arm64e slice that can fail to launch on iOS 17/18":
  TRUE. The main CHANGELOG "Unreleased" entry removes the arm64e slice and
  cites launch failures in 18.1.0 through 19.0.1 (issue #3997). 18.0.3
  predates it (18.0.1 is named as the last arm64-only release; 18.0.2/18.0.3
  carry no such note, and the fix entry says the slice appeared in 18.1.0).

**Every SDK call in FacebookAppEventsPlugin.swift exists in 18.0.3:**

| Plugin call | 18.0.3 location |
|---|---|
| `Settings.shared.graphAPIVersion` (set) | Settings.swift |
| `Settings.shared.appID` (get) | Settings.swift:249 |
| `Settings.shared.isAutoLogAppEventsEnabled` | Settings.swift:83 |
| `Settings.shared.isAdvertiserTrackingEnabled` (set) | Settings.swift:355; setter deprecated, reads ATT status; same in 19 |
| `Settings.shared.isAdvertiserIDCollectionEnabled` | Settings.swift:155 |
| `Settings.shared.isEventDataUsageLimited` | Settings.swift:210 |
| `Settings.shared.setDataProcessingOptions(_:country:state:)` | Settings.swift:495 (Int32, Int32) |
| `Settings.shared.enable/disableLoggingBehavior` | Settings.swift:544/554 |
| `AppEvents.shared.loggingOverrideAppID` | FBSDKAppEvents.h:116 |
| `AppEvents.shared.activateApp()` | FBSDKAppEvents.h:383 |
| `AppEvents.shared.clearUserData()` / `clearUserData(forType:)` | .h:479 / 494 |
| `AppEvents.shared.setUserData(_:forType:)` / `getUserData()` | .h:490 / 476 |
| `AppEvents.shared.userID` / `anonymousID` | .h:123 / 126 |
| `AppEvents.shared.flush()` / `flushBehavior` | .h:415 / 103 |
| `AppEvents.shared.logEvent(_:parameters:)` / `(_:valueToSum:parameters:)` | .h:164 / 182 |
| `AppEvents.shared.logPurchase(amount:currency:parameters:)` | .h:249 |
| `AppEvents.shared.logPushNotificationOpen(payload:)` / `(payload:action:)` | .h:308 / 319 |
| `AppEvents.shared.logProductItem(...)` | .h:351 |
| `AppEvents.shared.setPushNotificationsDeviceToken` | .h:397 |
| `AppEvents.Name`, `.ParameterName`, `.FlushBehavior`, `.ProductAvailability`, `.ProductCondition` | include/FBSDKAppEventName.h, FBSDKAppEventParameterName.h, FBSDKAppEventsFlushBehavior.h, FBSDKProductAvailability.h, FBSDKProductCondition.h |
| `ApplicationDelegate.shared.initializeSDK()` | ApplicationDelegate.swift:61 |
| `ApplicationDelegate.shared.application(_:open:options:)` | ApplicationDelegate.swift:241 |
| `ApplicationDelegate.shared.application(_:didFinishLaunchingWithOptions:)` | ApplicationDelegate.swift:327 |
| `import FBSDKCoreKit_Basics` | FBSDKCoreKit_Basics.podspec present |

Nothing else was removed from the plugin; the one removed line was the only
19-only API.

**Privacy promise "metadata off" on SDK 18.** What 18.0.3 sends on its own
when the app calls `activateApp`:
- `fb_mobile_launch_source` = `"AppLink(<source bundle id>)"` or
  `"Unclassified(<source bundle id>)"` (FBSDKTimeSpentData.m:263-271). Only a
  flag + the opening app's bundle id, not the URL and not a screen title.
- `AEMReporter.handle(url)` runs only when an opened URL carries
  `al_applink_data` (a Meta ad deep link). Longnote does not use Meta app
  links, so this path is dormant.
- The usual activity parameters (anon id, app version, URL schemes from
  Info.plist, IDFA only when ATT allowed and `FacebookAdvertiserIDCollectionEnabled`).
No screen titles and no AppLink URLs are collected in 18.0.3. The promise holds.

**links.dart**: App Store id `6835017154` -> `https://apps.apple.com/app/id6835017154`,
correct form; `support`/`website` constants are not read anywhere yet (fine as
the single source for later use). `appStoreUrl` fallback now reads `website`.

**pubspec/lock/analyzer**: path dependency, lock shows `source: path`,
`third_party/**` excluded from analysis. Fine.

## Non-blocking notes

1. Stale "v19" wording now that the app ships 18: `lib/core/analytics/meta_sink.dart:89`
   ("SDK v19 attaches screen titles / URLs to every event: off.") and
   `docs/ANALYTICS.md:75-76`. Both are still true as defence-in-depth (the
   Info.plist key and the call are harmless on 18); suggest a one-line
   "(no-op on the pinned 18.0.3)" so the next reader does not hunt for the
   collector.
2. The vendored Dart docstring for `setAutoLogMetaDataEnabled` still
   describes persisting/clearing behaviour that the iOS side no longer has.
   Cosmetic.
3. 18.0.3 is also shipped as prebuilt XCFrameworks (`vendored_frameworks` in
   FBSDKCoreKit.podspec), so the Xcode 26.3 swiftinterface problem is a
   CI question, not something this review can settle. The parallel CI
   build is the gate.
4. When Meta ships the arm64e-fixed release (the "Unreleased" entry), the
   pin should be revisited; until then it is the right call. Note Meta's
   changelog also says the repo moved and SPM users should update the
   package URL (19.0.1 note); the old URL still resolves today (the sparse
   clone used it).
5. No `ios/Podfile.lock` in the repo; with an exact pin in both SPM and the
   podspec that is acceptable.
