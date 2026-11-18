# Privacy, terms and support: changes vs launch/ drafts (19 Nov 2026)

New public texts: `docs/store/website/privacy.md`, `terms.md`, `support.md`.
Compared with `launch/privacy-policy.md`, `launch/terms.md` and `launch/site/longnote/support/index.html` (16 Nov drafts).
The launch session should copy these changes into its own files and the HTML pages.

## Privacy policy

1. Date: "Effective date: 16 November 2026" -> "Last updated: 19 November 2026".
2. **Meta added everywhere.** Removed "No ads. No ad tracking. No selling or sharing...", "We do not track you ... never shows Apple's 'Allow tracking?' prompt", "we do not 'share' it for cross-context behavioural advertising".
   - Section 2: Meta bullet; one-switch bullet; "No ads inside the app. We do not sell your data."
   - Section 3 table: rows for ad measurement events (Meta) and IDFA (only if tracking allowed); Meta added to technical data and subscription rows.
   - New section 7 "Ad measurement (Meta)": the 4 events (install/open, onboarding completed, trial started with currency, subscription bought with price and currency); SDK technical data; what is never sent; automatic event logging off; ATT prompt once after welcome screens; allow -> IDFA, linking with Meta data = tracking; deny -> no IDFA, events still sent, SKAdNetwork / aggregated measurement; iPhone Settings > Privacy & Security > Tracking; Meta independent controller for its own uses; link to https://www.facebook.com/privacy/policy; "Delete my data" cannot reach Meta.
   - Section 8 processors table: Meta row (Meta Platforms, Inc. and Meta Platforms Ireland Limited); Apple row adds SKAdNetwork. Note that Supabase/Soniox/OpenAI/Amplitude are processors, Meta is not only a processor.
   - Section 5 retention: Meta "as set out in Meta's Privacy Policy".
   - Section 9 subscriptions: trial/buy events go to Meta.
   - Section 10 rights: "Share usage analytics" turns off Amplitude AND Meta; iPhone tracking setting; GDPR legal bases now include consent (IDFA) and ad measurement under legitimate interest; joint-controller sentence for collection/sending to Meta; CCPA now says IDFA + events to Meta may count as "sharing", with opt-out routes; DPDP withdrawal examples include tracking and the switch.
   - Section 13 transfers: Meta processes in the US and other countries.
3. **Amplitude** section: event list matched to the code (`lib/core/analytics/analytics.dart`): added onboarding completed, interrupted, transcript/summary viewed, export, tracking-prompt answer, restore tapped. Switch path is "Settings > Share usage analytics" (it sits in the Privacy group of Settings).
4. **Retention matched to the backend** (`docs/BACKEND-API.md` section 6), all shorter than or equal to the draft:
   - audio leftovers: 7 days -> **24 hours**;
   - server transcript: on ack, else **24 h after first download**, else 7 days unfetched;
   - job records **30 days**; usage counts **90 days**; inactive anonymous ID **90 days** (draft said 12 months);
   - new rows: **hashed IP, 2 days** (abuse limits) and **crash/error reports, 30 days** (our own crash reporter + MetricKit, `lib/core/diagnostics/crash_reporter.dart`);
   - summary idempotency cache up to 30 minutes on our server (draft said "we do not keep the summary").
5. **On-device mode**: summaries are now made on the phone (Apple Intelligence or basic offline summary, `lib/core/summary/summary_service.dart`); only Ask sends text to OpenAI. The draft said summaries and Ask both go to OpenAI.
6. Recording starts only when the user taps Start (section 4 step 1).
7. iCloud backup line added: notes are in the user's own iCloud device backup if turned on; Apple's storage, not ours.
8. OpenAI row: also receives the summary language; transcript text includes speaker names the user added.
9. Security: hashed IP bullet; "secret API keys" (the Amplitude/Meta client keys are public by design).
10. Section numbers shifted by one from section 7 on (new Meta section).

## Terms

1. Date -> "Last updated: 19 November 2026".
2. Section 2: "Recording starts only when you tap Start".
3. Section 3: trial reminder "if you allow notifications"; cancel path written without brackets ("iPhone Settings > your name (Apple ID) > Subscriptions > Longnote", or Settings > Plan & billing in the app); new Restore bullet.
4. Section 3 Fair use: rewritten to the owner's 16 Nov decision (no daily limits for normal use; anti-abuse limits far above normal use). The draft still mentioned "hours of audio per day" limits.
5. Section 4: "we never send it to our analytics or advertising partners".
6. Section 8: Meta (ad measurement) added; Apple also "ad measurement"; Meta uses some data under its own terms.
7. Privacy link without trailing slash (matches `lib/features/common/links.dart`).

## Support page

1. Support ID path: Settings > Privacy.
2. Cancel: also via Longnote > Settings > Plan & billing; deleting the app does not cancel.
3. Restore: Settings > Restore purchases (and the paywall button).
4. Stuck note: button is "Try again" in the app (draft said "Retry").
5. New lines: analytics/ad switch and iPhone tracking setting; privacy and terms links.
6. Footer keeps no postal address (owner decision: address only in the privacy policy).

## App Store privacy label (replaces app-store-listing.md section 6)

Apple's definitions used:
- **Tracking** = linking data collected from this app about a user or device with data from other companies' apps or websites for targeted advertising or **advertising measurement**, or sharing it with a data broker. Sending events plus the IDFA to Meta, which links them with its own data to measure ads, is tracking. Declare a data type as "used to track" if it is used for tracking at all, even if only for users who allow it.
- **Third-Party Advertising** = displaying third-party ads, or sharing data with entities who display third-party ads. Meta uses the data to improve its ad systems generally.
- **Developer's Advertising or Marketing** = displaying first-party ads, or sharing data with entities who will display **your** ads. Meta shows our Longnote ads.
- **Linked to you** = tied to identity via account, device ID or other identifier. Our anonymous ID and Meta's IDFA/SDK ID both count.

| Data type | Collected | Linked | Used to track you | Purposes | Why |
|---|---|---|---|---|---|
| Audio Data | Yes | Yes | No | App Functionality | Uploaded to our backend and Soniox for transcription (unchanged) |
| Other User Content | Yes | Yes | No | App Functionality | Transcript text and Ask questions to OpenAI (unchanged) |
| User ID | Yes | Yes | No | App Functionality, Analytics | Anonymous ID; Amplitude. Meta never gets it |
| **Device ID** | Yes | Yes | **Yes** | App Functionality, Analytics, **Developer's Advertising or Marketing**, **Third-Party Advertising** | Push token (functionality); Amplitude device ID (analytics); **IDFA when the user allows tracking**, plus the Meta SDK's own app ID (ads) |
| **Purchase History** | Yes | Yes | **Yes** | Analytics, **Developer's Advertising or Marketing**, **Third-Party Advertising** | Revenue events to Amplitude; StartTrial and Subscribe (price, currency) to Meta |
| **Product Interaction** | Yes | Yes | **Yes** | Analytics, **Developer's Advertising or Marketing**, **Third-Party Advertising** | Amplitude events; app activation and CompleteRegistration (onboarding) to Meta |
| Other Usage Data | Yes | Yes | No | Analytics, App Functionality | Audio minutes on our server (cost control), Amplitude measures. Not sent to Meta |
| **Crash Data** (new) | Yes | Yes | No | App Functionality | Our crash reporter + MetricKit crashes, stored 30 days on our backend |
| **Performance Data** (new) | Yes | Yes | No | App Functionality | MetricKit hangs and CPU/disk exceptions in the same reports |
| Other Diagnostic Data | Yes | Yes | No | Analytics, App Functionality | Processing failed/retried, job records (unchanged) |

Summary to select in ASC:
- Data Used to Track You: **Device ID, Purchase History, Product Interaction**.
- Data Linked to You: all the other types above.
- Data Not Linked to You: none.
- The app now uses the IDFA and shows the ATT prompt (`NSUserTrackingUsageDescription` is in Info.plist). Tracking domains: Meta's, declared by the Meta SDK's own privacy manifest (`NSPrivacyTracking` true).

To check before saving the label:
- **Coarse Location.** Meta receives the IP address and may derive a location from it. Open Xcode > Product > Archive > Generate Privacy Report and see what the Meta SDK's privacy manifest declares. If it lists Coarse Location (or any other type not above), declare it too, with the same tracking answer the manifest gives.
- Crash Data / Performance Data were missing from the 16 Nov label because the crash reporter did not exist then. Declare them now.
- Advertising Data (ads the user has seen): not collected by us; Meta knows which ad was clicked on its own side. Do not declare unless the Meta manifest does.
