# Submission steps for the owner (evening 20 Nov 2026)

Nothing here sends the app to Apple. "Submit for Review" is the last step and happens only on the owner's go.

## A. Before the App Store Connect forms
1. Install TestFlight 118 (VALID 20 Nov; sim QA 56/56 run 44680257919; Fable full review + re-check APPROVED). Quick check: onboarding, paywall, one sandbox "Start free trial", delete + reinstall + "Restore purchase", lock-screen recording 10 min, Settings > Rate Longnote opens the App Store (it says "not available" until launch; that is expected).
2. Re-publish the website in Figma Make (privacy + support pages): paste `docs/store/website/FIGMA-MAKE-PRIVACY-UPDATE.txt`, and apply the support page text from `docs/store/website/support.md`. This removes the "Settings > Account > Delete account" line (we have no accounts; a reviewer would look for it) and the old "June 4, 2026" date. While there: set the page title to "Longnote" (it says "Figma Make App") and remove the template description.

## B. App Store Connect website (appstoreconnect.apple.com > Longnote)
1. **Pricing and Availability**: Price = **Free (USD 0)**. Availability = **all countries** (the subscriptions are already priced in 175). Save.
2. **App Information > Content Rights**: "Does your app contain, show, or access third-party content?" = **No**.
3. **App Privacy > Get started**. "Do you or your third-party partners collect data from this app?" = **Yes**. Tick these data types and answer each the same way unless noted: **Linked to the user = Yes. Used for tracking = No.**

| Data type | Purposes to tick |
|---|---|
| User Content > Audio Data | App Functionality |
| User Content > Other User Content (transcripts, Ask questions) | App Functionality |
| Identifiers > User ID (random anonymous ID) | App Functionality, Analytics |
| Identifiers > Device ID (Amplitude install ID, push token, Meta install ID) | App Functionality, Analytics, Developer's Advertising or Marketing |
| Purchases > Purchase History | Analytics, Developer's Advertising or Marketing |
| Usage Data > Product Interaction | Analytics, Developer's Advertising or Marketing |
| Usage Data > Other Usage Data (minutes per day for limits) | App Functionality, Analytics |
| Diagnostics > Crash Data (our own crash reports) | App Functionality |
| Diagnostics > Other Diagnostic Data (processing failed/retried) | App Functionality, Analytics |

   Do NOT tick: Contact Info, Location, Health, Financial Info, Contacts, Photos, Browsing/Search History, Sensitive Info.
   "Developer's Advertising or Marketing" is for Meta measuring our own ads (install, trial, purchase). Tracking stays **No** because the app never reads the IDFA, has no "Allow tracking?" prompt and tells Meta advertiser tracking is off. Risk (known): a reviewer could still call Meta measurement tracking; the fix then is to switch Meta off or add the prompt.
   Privacy Policy URL is already set. Publish the label.
4. **Version 1.0 page**:
   - Build: remove 116, select **118**.
   - "In-App Purchases and Subscriptions": tick **Longnote Yearly** and **Longnote Monthly**.
   - Review notes: DONE by Claude 20 Nov (describe the new onboarding).
   - Screenshots: the 8 uploaded are from the older design; fine to submit, refresh later.
5. Claude checks everything once more through the API and reports.
6. Owner says go → "Add for Review" → "Submit to App Review". Release is set to "automatically after approval"; change to "Manually release" first if you want to pick the day.

## C. After submission (not blocking)
- Supabase Pro ($25/month) before ad spend (free projects pause after a week of no use and have small limits).
- OpenAI and Soniox billing alerts.
- Recordings longer than 5 hours: split into parts (today the app says "up to 5 hours").
- Login + "Delete account" (then update the privacy label: Contact Info).
- 1.0.1: a native crash during processing re-runs the same job on every launch (resetInterrupted keeps attempts; Fable 20 Nov). Add a separate "interrupted while running" counter with a higher cap so normal iOS background kills don't fail notes. Also consider running sim QA on an arm64 simulator (CI simulator runs under Rosetta; AAC encoder crash in run 44752027594 is a Rosetta/x86 codec artefact per Fable).
