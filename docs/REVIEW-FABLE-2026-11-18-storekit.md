# Review: real App Store billing (StoreKit 2) on v1-build

Reviewer: Claude Fable 5.1, 2026-11-18. Read-only review of the uncommitted
working tree. Files read: ios/Runner/AppDelegate.swift (StorePlugin),
lib/core/billing/{storekit_billing_service,billing_service,paywall_gate,
trial_reminder}.dart, lib/app_services.dart, lib/features/paywall/{paywall_screen,
trial_copy,trial_started_screen}.dart, lib/features/settings/{plan_screen,
settings_home_screen,settings_screen}.dart, lib/features/common/links.dart,
test/storekit_billing_test.dart, integration_test/qa_6_store_test.dart,
tools/qa/run_sim_qa.sh, launch/SUBSCRIPTIONS.md, project.pbxproj (Swift 5 mode,
iOS 16.0).

## Verdict: APPROVED WITH FIXES

Nothing in this change can charge the wrong amount or unlock without a verified
App Store transaction: the only entitlement source is `Transaction.currentEntitlements`
filtered to `.verified`, non-revoked, auto-renewable; every transaction returned
by `purchase()` and every one on `Transaction.updates` is finished; the listener
starts at engine init; `AppStore.sync()` runs only on an explicit Restore tap.
The Swift reads as compilable against the iOS 16+ StoreKit 2 API in Swift 5
language mode (notes in 10). What needs fixing is entitlement *freshness* and
honesty around cancel/expiry/eligibility, plus the review-facing items in 8-9.
Fix 1-4 before the owner's TestFlight purchase test; 8-9 before submission.

## Findings

### 1. major — an expired or cancelled subscription keeps access until the next cold launch
`lib/core/billing/storekit_billing_service.dart:67-83`, `lib/core/billing/paywall_gate.dart:27`.
The Dart entitlement is re-read only at `init()`, on a native `changed`, after
purchase, or after Restore. Expiry is not a transaction, so `Transaction.updates`
never fires for it; auto-renew-off is not a transaction either. Scenario: trial
ends Fri 10:00, user had cancelled; the app was suspended, not killed (iOS keeps
it for days). Fri 11:00 they open it: `entitlement.isActive` is still true,
`canStartRecording` passes, they record for free; the Plan screen still says
"Your trial ends Fri... Apple charges Rs 5,900". Reverse case for honesty: user
cancels in iPhone Settings, comes back, Plan screen still says "If you don't
cancel, Apple charges" for days (`willRenew` is only fetched inside `_apply`).
Fix: (a) in `AppServices` add a `WidgetsBindingObserver`; on
`AppLifecycleState.resumed` call `billing.refresh()` (StoreKit side is local
and cheap); (b) in `canStartRecording`, if `renewsAt != null && renewsAt.isBefore(now)`,
`await refresh()` before deciding; (c) `PlanScreen` build/initState also calls
`refresh()`. Keep `refresh` idempotent (it is).

### 2. major — stale local eligibility suppresses the trial flow and its reminder
`lib/core/billing/storekit_billing_service.dart:179,201`, `lib/features/paywall/paywall_screen.dart:81,89`.
`startedTrial = wasEligible && status == trial`, and the paywall gates A2 again on
its own `trial` snapshot. `_eligible` is a persisted guess (kv `store_trial_eligible`,
also forced false by any `trialUsed`). Scenario: a second Apple ID on the same
phone, or the first `products` answer said ineligible while StoreKit had not
yet synced history on a new device. Apple grants the free trial (the sheet said
so), the store status says `isTrial: true`, but `startedTrial` is false: no A2,
no reminder permission ask, no 26 h reminder, and the paywall had said "charged
today". The reminder promise breaks exactly for the user who is on a trial.
Fix: `startedTrial: e.status == EntitlementStatus.trial` (drop `wasEligible`);
in `_buy` use `res.startedTrial` alone. Also re-run eligibility after
`restore()` and after a successful purchase (`loadPlans` again, or a cheap
`eligible` native method) so the kv value tracks Apple, not history.

### 3. major — the scheduled trial reminder is never cancelled
`lib/core/billing/trial_reminder.dart:57-70` (only `onTrialStarted` cancels), no
listener on the entitlement anywhere. Scenario: user starts the trial, allows the
reminder, cancels the next day in Settings (or gets a refund, or upgrades to the
yearly which starts a new transaction). 26 h before the old end, iOS shows
"Your free trial ends soon. On ... you will be charged Rs 5,900 unless you
cancel." The brand promise is the honest reminder; this one is wrong.
Fix: in `AppServices` listen to `billing.entitlement`; when `status != trial`,
or `willRenew == false`, or `trialEndsAt` changed, call
`reminders.scheduler.cancel(TrialReminderService.notificationId)` and clear
`kvScheduledAt`. Reschedule when a new trial starts with a different end.

### 4. major — wrong currency/price shown before products load or offline
`lib/features/paywall/trial_copy.dart:34-37`, `lib/features/settings/plan_screen.dart:104`,
`settings_home_screen.dart:~260`. `planForId` falls back to the hard-coded
`$59.99 / $9.99` whenever `storePlans` is empty. `storePlans` is filled only by a
successful `products` call this launch; it is not cached. Scenario: an Indian
subscriber opens Settings on the train with no signal: the plan card says
"Renews Dec 17 . $9.99 a month" and the Plan screen "Next charge Dec 17: $9.99".
Same for the first second of every online launch. The trial reminder body is
built at schedule time (plans loaded by then), so that one is right.
Fix: persist the loaded plans to kv (id, displayPrice, price, currency, period,
trialDays) and seed `storePlans` in `init()` before the first frame; while no
store price is known show no number ("your plan price" / omit the amount)
rather than USD.

### 5. minor — Restore says "No purchase found" when the real reason is no network / cancelled sign-in
`storekit_billing_service.dart:228-239`, `paywall_screen.dart:107`, `plan_screen.dart:40`,
`settings_home_screen.dart:95`. `AppStore.sync()` throws offline or when the
user dismisses Apple's sign-in; the service swallows it and the screens report
"No purchase found to restore on this Apple ID", which tells a paying user
their purchase is gone. Fix: `restore()` returns an enum/bool
(`restored | none | failed`) or rethrows; screens say "Couldn't reach the App
Store. Check your connection and try again." on failure.

### 6. minor — downgrade yearly -> monthly shows the wrong next charge
`AppDelegate.swift` `willAutoRenew`, `plan_screen.dart:126`. Only
`renewalInfo.willAutoRenew` is read. After a downgrade in Apple's page the
current transaction is still the yearly, `willAutoRenew` is true, and the Plan
screen says "Next charge Nov 17 2027: Rs 5,900. It renews every year" when
Apple will charge Rs 999 monthly. Fix: return `autoRenewPreference` (product
id) from `renewal`; when it differs from `productId`, show "Switches to Monthly
(Rs 999) on <date>". Also iterate statuses and match `currentProductID` instead
of taking the first entry.

### 7. minor — `changed` handler and refresh errors are unhandled
`storekit_billing_service.dart:67-69`. `refresh()` inside `setMethodCallHandler`
has no try/catch; a `PlatformException` becomes an unhandled async error in
the platform-channel path (logged, not fatal). Fix: wrap in try/catch with
`debugPrint`. Same for `_apply`'s `_fetchRenewal` (already caught) - fine.

### 8. major (submission, outside the diff) — Terms/Privacy URLs are placeholders
`lib/features/common/links.dart:8-11` still carries the TODO; the paywall's
"Terms" and "Privacy" links (3.1.2 requires a functional EULA/Terms of Use and
privacy policy link in the app AND in the App Store metadata) must resolve
before review. Also add the Terms of Use link to the ASC description or set a
custom EULA, and replace the PLACEHOLDER review screenshot named in
`launch/SUBSCRIPTIONS.md`.

### 9. minor (3.1.2 clarity) — the paywall never names the subscription
`paywall_screen.dart:158-170, 189-215`. Cards say "Yearly / Monthly"; nowhere
does it say what is being bought ("Longnote Pro"). Reviewers want title,
length, price per period on the purchase screen. Fix: one line such as
"Longnote Pro . Yearly . Rs 5,900 / year" near the plan cards (the price line
already covers period and trial terms). Also show the first-run paywall only
when `!entitlement.isActive` (a reinstalling subscriber currently sees "Start
free trial"; Apple's sheet then says already subscribed, so no charge, but it
looks wrong).

### 10. Swift: no compile errors found; notes
`ios/Runner/AppDelegate.swift:60-222`.
- API use checked: `Product.products(for:)`, `product.subscription?.subscriptionPeriod`,
  `introductoryOffer?.paymentMode == .freeTrial`, `isEligibleForIntroOffer`
  (async get, awaited), `priceFormatStyle.currencyCode` (iOS 16+), `purchase()`
  result cases incl. `@unknown default`, `VerificationResult.unverified(_, error)`,
  `Transaction.currentEntitlements` / `.updates` (non-throwing `for await`),
  `productType == .autoRenewable`, `revocationDate`, `expirationDate`,
  `originalID: UInt64`, `offerType == .introductory`, `subscription?.status`
  (`try? await` through optional chain), `renewalInfo` / `willAutoRenew`,
  `AppStore.sync()`. All exist at iOS 16.
- Expect warnings only: `offerType` deprecated in iOS 17.2 (use
  `offer?.type` when the target is 17.2+); non-Sendable captures of `self`,
  `call`, `result` in `Task`/`Task.detached` (Swift 5 mode, same pattern as
  `AudioEncoderPlugin` which already builds). If the project ever moves to
  Swift 6 mode this needs `@preconcurrency`/`nonisolated(unsafe)` work.
- `Transaction` is StoreKit's here (no SwiftUI import in this file). Write
  `StoreKit.Transaction` once to make that robust against a future import.
- `FlutterResult` is called on the main actor in every path (good: Flutter
  requires the platform thread). `changed` is sent via `MainActor.run` (good).
- Semantics: `status()` picks the longest-expiring entitlement, so after a
  monthly -> yearly upgrade the yearly wins (correct). Unverified transactions
  are ignored but still trigger `changed` (harmless).
- Sandbox/TestFlight: a 3-day trial runs 2 minutes; the 26 h reminder is then
  null and A2 shows "Continue" - expected, not a bug.

### 11. Edge cases reviewed (no change needed, record for the device test)
- Offline launch with cache: `currentEntitlements` is local; fine. Offline
  launch after reinstall: empty until online; first recording stays free,
  Restore fails (see 5 for the message).
- Slow StoreKit: 5 s status timeout, cached entitlement shown, late answer
  still applied (`refresh()` keeps running after `.timeout`). Good.
- Ask to Buy: `pending` message, unlock on `changed` after approval, also at
  the next launch via `currentEntitlements`. Good.
- Refund/revocation: `updates` delivers the revoked transaction -> `changed`
  -> locked. Good.
- Billing grace period (if enabled in ASC): entitlement persists past
  `expirationDate`; Plan screen would show a past "Next charge". Cosmetic.
- Family Sharing is off; `ownershipType` unchecked - fine.
- Jailbreak editing the kv cache unlocks until the next status read; no
  server validation. Accepted for v1 (StoreKit 2 local verification).
- Suffix-currency locales ("59,99 EUR"): `monthlyEquivalent` loses the symbol
  and uses "." decimals. Minor; format `price/12` with `priceFormatStyle` in
  Swift and send `monthlyEquivalentLabel`.

### 12. Test gaps
`test/storekit_billing_test.dart` covers the happy paths. Missing:
- status active -> `changed` -> `{active:false}` locks and keeps
  `trialEligible == false` (refund path).
- store says trial while local eligibility is false -> `startedTrial` true
  (fails today; documents fix 2).
- `willRenew` carried across refreshes and flipped by a later `renewal`
  answer; downgrade preference (fix 6).
- reminder cancelled when the entitlement leaves trial / `willRenew` false
  (fix 3).
- expiry while the app is alive: `canStartRecording` refreshes and denies
  (fix 1).
- restore throwing offline -> result distinguishes failure from none (fix 5).
- `PaywallScreen` widget test with `StoreKitBillingService`: no "simulated"
  chip, store currency in the price line, button flips from "Start free
  trial" to "Subscribe" after a late ineligible `products` answer.
- late status answer after `statusTimeout` still applied.
- Swift: add `ios/Runner/Longnote.storekit` (two products, 3-day intro) and
  an XCTest with `SKTestSession` for purchase/refund/Ask to Buy, or at least
  run `xcodebuild build` in ios-build-check with the StoreKit config; then
  the owner's TestFlight sandbox checklist: buy trial -> A2 -> reminder
  scheduled; cancel in sandbox Settings -> relaunch -> "You cancelled";
  refund via sandbox -> locked; second device Restore; airplane-mode launch.
