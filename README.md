# Longnote (working name)

An iPhone app that records long conversations (meetings, lectures, talks) for hours,
makes a transcript on the phone, and writes a summary with key points, decisions,
action items and important numbers/dates. You can play the audio, rename, copy,
share, export a PDF, and share the original audio.

Brand promise: honest, reliable, private.

- No account, no sign-in, no ads, no tracking SDKs.
- Audio is written to disk every second while recording. If the app crashes or is
  force-quit, what was saved is kept and shown as "Interrupted - saved X min".
- Transcription runs on the phone (whisper.cpp).
- Billing is honest: monthly $9.99 or yearly $59.99, 3-day trial, no weekly plan,
  full price and charge date shown, reminder before the trial ends.

Status: first build (v0.1). **It has never been built or run on an iPhone.** It was
written on a Linux server with no Xcode. Dart code passes `flutter analyze` and 76
unit tests. See `docs/HANDOFF.md` for what is real, what is stubbed, and the test plan.

## Run it on a Mac + iPhone (step by step)

You need: a Mac with Xcode 26 (Xcode 16+ works, but the Apple Intelligence summary
needs the iOS 26 SDK), Flutter 3.44 or newer, CocoaPods, an iPhone on iOS 16+, and an
Apple ID (a free one is enough for running on your own phone).

1. Copy the repo to the Mac (it has no remote; zip it or `scp` the folder).
2. In Terminal, in the repo folder:
   ```
   flutter pub get
   cd ios && pod install && cd ..
   ```
   (`flutter run` also runs `pod install` for you.)
3. Open `ios/Runner.xcworkspace` in Xcode (the .xcworkspace, not the .xcodeproj).
4. Click "Runner" in the left panel > target "Runner" > "Signing & Capabilities":
   - Team: pick your Apple ID team.
   - Bundle Identifier: `in.novaralabs.longnote` (change it if Xcode says it is taken,
     e.g. add `.dev`).
   - Check that "Background Modes > Audio" is shown (it comes from Info.plist).
5. Plug in the iPhone, trust the Mac, turn on Developer Mode on the phone
   (Settings > Privacy & Security > Developer Mode).
6. Pick the iPhone as the run target in Xcode and press Run. Or from Terminal:
   `flutter run --release` (use release or profile for real speed tests;
   debug builds are slower).
7. First launch: 3 onboarding screens, then allow the microphone.
8. The first transcript downloads the speech model (base.en, 148 MB). Use Wi-Fi.
   You can also download it first in Settings.

Optional cloud summary (off by default): deploy `supabase/functions/summarize`
(see the header of that file), then build with
`--dart-define=CLOUD_SUMMARY_URL=https://PROJECT.supabase.co/functions/v1/summarize --dart-define=CLOUD_SUMMARY_PUBLIC_KEY=<anon key>`.
The Anthropic API key lives only in the Supabase secret, never in the app.

Hidden Benchmark screen: Settings > tap "Longnote / Version" 7 times.

## Develop on any machine (no iPhone)

```
flutter pub get
flutter analyze
flutter test
```

## What is real vs stubbed

| Part | State |
|---|---|
| Recording to 5-minute WAV parts, 1-second flush, crash recovery | Real code, unit-tested. Device behaviour (lock screen, calls) NOT tested |
| On-device transcription (whisper_ggml) | Real code against the package API. NOT run on a device |
| Summary: basic offline (extractive) | Real, tested |
| Summary: Apple Intelligence (Swift, FoundationModels) | Real code, NEVER compiled |
| Summary: cloud (Supabase function + Claude Haiku) | Written, NOT deployed, not called |
| Billing | FAKE (simulated, no money). Interface ready for StoreKit/RevenueCat |
| Trial reminder notification | Real code (flutter_local_notifications); date math tested; not seen on device |
| PDF / share / copy | Real; PDF builder tested; share sheet not seen on device |
| Analytics | Local SQLite table only, tested |
| Speaker labels | Not built (whisper cannot tell speakers apart). Field kept for later |

## Folder map

```
lib/
  main.dart, app_services.dart, theme.dart
  core/
    audio/        wav.dart (header, repair, concat), segment_writer.dart, pcm_source.dart (record + audio_session)
    recording/    recording_controller.dart, recovery_service.dart, recording_repository.dart
    jobs/         job_queue.dart (retry + backoff), processing_pipeline.dart
    transcription/ transcriber.dart, whisper_transcriber.dart, fake_transcriber.dart
    summary/      summarizer.dart, summary_models.dart, summary_service.dart,
                  local_extractive_summarizer.dart, cloud_summarizer.dart, apple_on_device_summarizer.dart
    billing/      billing_service.dart (fake), paywall_gate.dart, trial_reminder.dart
    export/       pdf_exporter.dart, share_service.dart, text_format.dart
    analytics/    analytics.dart
    db/           app_database.dart
  features/       onboarding, home, recording, detail, paywall, settings, benchmark
ios/Runner/AppDelegate.swift   Apple Intelligence MethodChannel (untested)
supabase/functions/summarize   Cloud summary backend (not deployed)
docs/DECISIONS.md, docs/HANDOFF.md
```
