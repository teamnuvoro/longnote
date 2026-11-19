# Review: Onboarding v2 + longer paywall (commit 9ae202a)

Reviewer: Claude Fable 5.1, 20 Nov 2026. Scope: `git show 9ae202a -- lib integration_test test/flows test/analytics_test.dart test/screens_golden_test.dart`, read against docs/ONBOARDING-PAYWALL-V2.md and the rest of the app. `flutter analyze lib/features/onboarding lib/features/paywall`: no issues. Test run: see the end.

## Findings, ranked

### Major

**M1. Paywall FAQ "your first recording is free" is shown to users whose free recording is already used.**
`lib/features/paywall/paywall_more.dart:198-202` ("Close this screen and your first recording is free, with its full transcript and summary.") is rendered by `PaywallMore`, which `paywall_screen.dart:271` adds for every placement. The paywall at placement `second_recording` (`lib/app/router.dart:83`) opens exactly when `PaywallGate.canStart` is false, i.e. the free recording is spent (`lib/core/billing/paywall_gate.dart:28-30`). For that user the sentence is false: closing the screen does not let them record. Guideline 3.1.2 reviewers also test this placement.
Fix: give `PaywallMore` a `firstRun` (or `freeRecordingLeft`) flag from `PaywallScreen.placement == 'first_run'` and drop the `free` FAQ (or reword it to "Your first recording was free; after that Longnote Pro is needed to record") when false.

**M2. "Your Longnote is ready / Set up for the way you record / Summaries made for lectures and talks" promises personalisation that does not exist yet.**
`lib/features/onboarding/onboarding_screen.dart:209-215` ticks "Summaries made for <answers>" in `SetupChecklist`. The answers are only stored (`kvUses`, `kvLength`, lines 71-72); nothing reads them: `grep -rn "kvUses\|onboarding_uses\|kvLength" lib` finds only onboarding_screen.dart. The default summary style stays `SummaryStyle.meeting` (`lib/core/summary/summary_style.dart:21-22`). The doc itself says the answers are "for a later default summary style". On the honest-billing brand this is an overstatement a user can test on their first note.
Fix (either): (a) actually set the default summary style from `_uses.first` in `_finish` (meetings→meeting, lectures→lecture, interviews→interview, calls→client_call, talks→sermon, doctor→doctor_visit, other→meeting) and keep the line; or (b) reword the checklist to things that are true now ("9 summary styles, including lectures and sermons", "Recording with no time limit", ...) and change the subtitle "Set up for the way you record." to "Everything is ready."

**M3. `_finish` can hang with the button busy and Back disabled (no timeout on analytics).**
`onboarding_screen.dart:77-83` awaits `s.analytics.log(onboardingCompleted)`, which awaits each remote sink (`lib/core/analytics/analytics.dart:132-135`); `AmplitudeSink.track` (`amplitude_sink.dart:77-83`) and `MetaSink.track` (`meta_sink.dart`, which may call `initializeSdk` here for the first time) have no timeout. During this `_finishing` is true, so the CTA is `busy` (disabled: `buttons.dart:31`) and `onBack` is null (line 234); `kvOnboardingDone` is already true (line 70). A stuck native SDK call leaves the user on the mic page with a spinner and no way out until they kill the app. The paywall already guards against exactly this (`paywall_screen.dart:120-123`, "Never let analytics hold up a paid user").
Fix: `await s.analytics.log(...).timeout(const Duration(seconds: 2), onTimeout: () {})`. Optionally also the `billing.refresh()` on line 75 is fine (StoreKit refresh has its own `statusTimeout`, `storekit_billing_service.dart:125-131`).

### Minor

**m1. `paywall_faq_opened` loses its only property remotely.**
`paywall_screen.dart:273-275` logs `{'question': id}`; `question` is in `piiKeyDenylist` (`lib/core/analytics/remote_analytics.dart:36`), so `remoteSafeProps` drops it and Amplitude receives a bare `paywall_faq_opened`. The funnel question "which FAQ do people open" cannot be answered. (The local DB row keeps it.)
Fix: rename the prop to `faq` or `item` (the values are short ids: `length`, `locked`, ...); update the doc line "`paywall_faq_opened` {question}".

**m2. `_askMic` has no re-entry guard; a double tap on "Allow microphone" can call `_finish` twice.**
`onboarding_screen.dart:97-115`: the button is not busy while the permission call is in flight (only `_finish` sets `_finishing`). Two quick taps when the permission is already decided (so `hasPermission` returns at once) give two `_askMic` futures; the second reaches `_finish` after the first has navigated away and reset `_finishing` (line 86), so `_s` runs `context.read` on a disposed element (ProviderNotFoundException logged in release, assertion in debug). Not user-visible in release, but noisy and racy.
Fix: add `bool _asking` set true at the start of `_askMic` (and show it as `busy`), and start `_finish` with `if (_finishing || !mounted) return;`.

**m3. System back during `_finishing` still moves a page back.**
`onboarding_screen.dart:223-226` `onPopInvokedWithResult` calls `_go(_page - 1)` without checking `_finishing`, while the on-screen Back is disabled (line 234). On iOS there is no system back on a root route, so this is mostly theoretical; make them consistent: `if (!didPop && _page > 0 && !_finishing) _go(_page - 1);`.

**m4. `onboarding_step` is logged again on Back, so the funnel double-counts pages.**
`_go` (line 117-123) logs every move, forwards or backwards. Amplitude funnels on `onboarding_step` by `index` will show more views of early pages than installs.
Fix: add `'dir': 'back'|'next'` to the props, or log only when `page > _maxSeen`.

**m5. Layout: "Part 1 saved / Part 2 saved / Part 3 ..." chips are in a plain `Row` (`onboarding_visuals.dart:293-317`).**
At 375 pt with the card padding (24+20 each side ≈ 287 pt available) the three chips fit at 1.0x, but the app does not clamp `textScaler` (no `TextScaler`/`textScaler` in lib) so at iOS accessibility sizes (≥ 1.5x) the Row overflows (yellow/black stripes in debug, clipped text in release). Same pattern, lower risk: `RecordingPill` (Positioned, unconstrained, paints past the card) and the speaker/time `Row` in `TranscriptVisual` (line 397-402; short strings).
Fix: `Wrap(spacing: 6, runSpacing: 6)` for the chips; `Flexible`/`Expanded` on the speaker name text.

**m6. `_Ready` wording with "Something else" picked first: "Summaries made for everything else".**
`onboarding_content.dart:13` `short: 'everything else'` reads oddly in `onboarding_screen.dart:211-212` when it is the first or only pick. Use "your recordings" for `other`.

### Checked and fine (evidence)

Navigation. `PageView` is `NeverScrollableScrollPhysics` (line 240); `_go` bounds-checks (line 118) and keeps `_page` and the controller in step; `_steps` is `_Step.values` so the CTA/title logic cannot run past the end; `_next` on the mic page branches on `_micMessage` (line 126-129); the `_finish` re-entry guard works because `_finishing` is set synchronously after the check (line 67-69). Mic denied: `hasPermission` is try/caught, the source is disposed in `finally`, the message appears and the CTA becomes "Continue" → `_finish` (lines 101-115, 133). Already subscribed: `billing.refresh()` before the decision (never throws, `storekit_billing_service.dart:125-131`), then `kvFirstPaywallSeen` and `goNamed(notes)` (lines 87-91). Killed mid-`_finish`: `kvOnboardingDone` is already true, so `initialLocation` (`router.dart:59-63`) opens `/paywall?first=1`; the user is not stuck and the paywall is not skipped. Answers: `_uses` keeps pick order (the first pick drives `DemoNote.forUse`), toggling removes; `_length` single. The `LnPressable` lesson applies to the CTA only while `busy`, which is only during `_finish` (fine) — see M3 for the one case where it bites.

Claims vs code. No time limit / saves in parts: rotating WAV segments, `recording_controller.dart:18,130-138`. Call pauses recording, earlier audio kept: `_onInterruption` → paused, segments already on disk (`recording_controller.dart:297-345`). 9 summary styles: `SummaryStyle` has 9 values. 60+ languages incl. Hinglish and auto: 64 `AudioLanguage(` entries, `hinglish` at `languages.dart:15`, `auto` detect. Import: `lib/features/import/`. Share PDF/text/audio: `share_sheet.dart:11,218,244`. Tap a transcript line to hear it: `note_screen.dart:521-524` `playFrom(line.startMs)`. Ask shows the moment: source chips "Open the transcript at …" (`ask_view.dart:585`); the demo's "Heard at 00:41:20" is a stylised version, acceptable. Reminder "a day before": `AppConfig.trialReminderLead = 26 h` (`config.dart:46`); the A2 screen uses the same words. First recording free: `PaywallGate.freeAllowance = 1` with the 30 s minimum. Speaker names: diarization plus the D4 rename sheet (`speakers_sheet.dart`); "speaker names and times" holds. On-phone mode "slower, no speaker labels": `transcription_screen.dart:62`. Audio deleted after transcript: `supabase/functions/cleanup` + soniox delete; same text as the previous onboarding. "Ready a few minutes after you stop" is not verifiable from the code (depends on Soniox/LLM latency for a 2 h file); keep an eye on it in QA, no change requested.

App Store 3.1.2. Product name (`paywall-product-name`), both plans with price and period, Save %, the timeline with real dates, the exact `priceLine` ("Free until <date>, then <price> per <period>. Cancel any time…") fixed above the fold in the footer, Start/Subscribe button, Restore / Terms / Privacy links — all still present and the price line stays on screen regardless of scroll (`paywall_screen.dart:289-324`). Close X is immediate (line 192-199). Moving the plans above the timeline improves price prominence. The footer shadow is cosmetic. No weekly plan, no fake reviews, no delayed X. Only the M1 FAQ sentence is a risk.

Analytics privacy. `onboarding_step` props: `step` = enum name, `index` = int. `onboarding_completed` adds bools `use_*`, `first_use` and `length` ids (`under_30`, `30_60`, `1_2h`, `over_2h`) — all match `_safeToken` (`remote_analytics.dart:55`); no free text anywhere. `MetaSink.forwarded` is unchanged (`onboarding_completed` only), still `logCompletedRegistration()` with no props. The flow test asserts both.

Animations. Every controller is a single `forward()` with a fixed duration and is disposed (`Reveal`, `WaveBars`, `CountingTimer`, `SetupChecklist`); `TweenAnimationBuilder`, `AnimatedSize`, `AnimatedRotation` are finite; the checklist spinner is determinate (`value: 0.7`), the progress bar determinate. Nothing repeats, so `pumpAndSettle` terminates (the golden and flow tests rely on it and pass locally, see below). The delay is folded into the controller (no `Timer`), good.

Tests. `passOnboardingPages` (qa_harness) taps `use-meetings`/`length-1_2h` when visible and the keyed CTA until "Allow microphone" is hit-testable, with a 14-iteration cap and a `TestFailure` — it tests the full path, and A2/N2 then tap "Allow microphone" and assert the paywall / the Settings explanation as before. `passFirstRunIfShown` now detects by `OnboardingScreen` type, more robust than text. `app_flow_test`: 7 taps from welcome land on privacy (welcome→uses→length→hours→summary→speakers→ask→privacy), the privacy text assertions are kept, Back is exercised, the skipped-answer kv values are asserted ('' and null, matching `join` and `set(key, null)`), and the second test asserts exactly 10 `onboarding_step`, the full `onboarding_completed` props and that Meta saw only CompleteRegistration. The golden test covers all 10 pages and the two new paywall states. `fb.calls.where((c) => c.contains('step'))` is a weak assertion (FakeMetaEvents never records event names) but harmless.

## Test run

See the last line of this file.
`flutter test test/flows/app_flow_test.dart test/analytics_test.dart`: all passed (20 Nov 2026). `flutter analyze` on the two feature folders: no issues.

VERDICT: CHANGES REQUESTED

## Re-check (ec221e1)

Scope: `git show ec221e1 -- lib test` only.

- M1 fixed. `PaywallMore(firstRun:)` → `_Faq._qs` drops the `free` item unless `firstRun`; `paywall_screen.dart` passes `widget.placement == 'first_run'`, which is exactly the router's distinction. `test/paywall_more_test.dart` covers both placements.
- M2 fixed, honestly. `RecordUse.style` maps the first answer to a real `SummaryStyle` (`other` → null); `_finish` calls `AppSettings.setDefaultStyle` (`app_settings.dart:30`). The ready screen says "Summaries set up for <first answer>" only when a style was set, otherwise "9 summary styles, from meetings to lectures" (true: 9 enum values); the subtitle's "Change it any time in Settings" is true (settings_home_screen uses `SummaryStyle`). Flow test asserts `lecture` with answers and `meeting` without.
- M3 fixed. `billing.refresh()` 8 s timeout and `analytics.log` 2 s timeout, both with `catchError`; `_finishing` can no longer stay true.
- m1 fixed (`faq`, not on the denylist; ids are safe tokens). m2 fixed (`_asking` guard, reset in `finally`, `!mounted` before `_finish`). m3 fixed (`_go` and PopScope both ignore while `_finishing`). m4 fixed (`dir` forward/back). m5 fixed (`Wrap`). m6 covered by the M2 wording.

Nits, no change needed: the CTA does not show `busy` while the iOS mic question is open (the guard makes it harmless); "Something else" first + "Lectures" second keeps Meeting notes (documented choice).

`flutter analyze` (onboarding, paywall, the new test): no issues. `flutter test test/paywall_more_test.dart test/flows/app_flow_test.dart`: all passed.

VERDICT: APPROVED
