# Handoff - Longnote v0.1 (overnight build, 15 Nov 2026)

Read this first. Plain summary: the Dart app is written, it analyzes clean, and 76 unit
tests pass on Linux. **Nothing has been built or run on an iPhone.** The parts that only
a real iPhone can prove (background recording, phone calls, whisper speed, the Swift
Apple Intelligence code) are untested.

Labels: **DONE** = code written and unit-tested. **PARTIAL** = some of it done.
**STUB** = fake on purpose. **UNTESTED** = written but never compiled or run where it matters.

## P0 status

| # | P0 item | Status | Notes |
|---|---|---|---|
| 1a | One big record button, Recording screen (timer, level, pause/resume, stop, "Saved on this phone", interruption banner) | DONE (UI) / UNTESTED on device | |
| 1b | Keeps recording with screen locked | UNTESTED | `UIBackgroundModes=audio` + `NSMicrophoneUsageDescription` set in Info.plist. Needs device test |
| 1c | Crash-safe capture: 5-min WAV parts, write per chunk, fsync + header update every 1 s, heartbeat 5 s | DONE | Unit-tested incl. simulated kill |
| 1d | Recovery on next launch, "Interrupted - saved X min" | DONE | Unit-tested (partial header, missing DB row, empty file, open gap) |
| 1e | Phone call: pause, mark gap, resume, honest banner | PARTIAL / UNTESTED | Logic unit-tested with a fake source; real `record` + `audio_session` behaviour unknown |
| 2a | On-device transcript (whisper.cpp) with model download + progress | UNTESTED | `whisper_ggml` 2.9.0. iOS build not verified |
| 2b | Summary (key points, decisions, action items w/ owner/due only when stated, numbers/dates, open questions) | PARTIAL | Local extractive: DONE + tested. Apple: UNTESTED (never compiled). Cloud: written, NOT deployed |
| 2c | Original audio always playable; failures never delete audio; retry | DONE (logic) / UNTESTED (playback) | Queue tested: backoff, final fail, manual retry, audio unchanged after failures, per-part resume. Playback uses just_audio, not run |
| 3 | Rename, playback + seek, copy/share transcript and summary, PDF, share audio | DONE (code) / UNTESTED on device | PDF builder tested (Unicode fonts). Share sheet not seen |
| 4 | Honest billing UI, $9.99 / $59.99, 3-day trial, no weekly, renewal price + date, how-to-cancel before buy, trial reminder, first recording free / paywall on 2nd | DONE with FAKE billing | Gate rule + reminder date math tested. **No StoreKit yet** |
| 5 | Onboarding: 3 screens, privacy promise, mic permission; no account | DONE (UI) | |
| 6 | Local analytics events (all 11) | DONE | Tested; viewable in Settings > Usage log |
| - | Settings: privacy explainer, engine choice, model choice/download, plan status, hidden Benchmark | DONE (UI) | Benchmark UNTESTED on device |
| - | Speaker labels | NOT BUILT (by decision) | `speaker` field kept, always empty |

## Verification done here

- `flutter analyze`: No issues found.
- `flutter test`: 76 tests, all pass.
- No `flutter build` of any kind (not allowed on this box; no Xcode).

### What the tests cover
- `wav_test.dart`: header fields; writer updates header on flush/close; repair after kill (header 0), odd byte, header bigger than file, file shorter than header, healthy file no-op, missing file; concat.
- `segment_writer_test.dart`: 5-min size constant; exact rotation and byte-exact content; odd chunks never split a sample; flush at most every 1 s; numbering.
- `recovery_test.dart`: stuck "recording" with a partial last part and missing DB row -> interrupted, correct duration, gap closed, events; paused recovered; completed untouched; empty file; missing file.
- `recording_controller_test.dart`: start/stop, interruption gap + banner text, pause/resume, no permission, simulated kill then recovery.
- `job_queue_test.dart`: backoff; retry then success; final failure + manual retry; failure never changes audio; resume per part with correct timestamps; reset of interrupted jobs.
- `summary_parse_test.dart`: valid, fenced, embedded, partial, loose shapes, garbage, round trip; merge de-dup and owner fill; chunking; plain text; prompt rules.
- `local_extractive_test.dart`: decisions incl. vote; owner/due only when said; numbers; questions; extractive-only; empty; 20k lines < 5 s.
- `summary_service_test.dart`: auto -> local; unavailable engine -> local + note; garbage -> fallback; long transcript chunk + merge; cloud client request/headers/errors (mock HTTP).
- `billing_test.dart`: gate rule; free then gated; <30 s does not count; subscribed does not count; reminder time (26 h before, across year end, never in the past); reminder text has price/date; fake billing plans and trial -> active.
- `analytics_test.dart`: all 11 names; filter/count; never throws.
- `pdf_export_test.dart`: PDF with ₹ and Hindi; transcript text format.

## Known risks (biggest first)

1. **Background recording with the screen locked is unproven.** Depends on `record` keeping its audio engine alive in the background with `UIBackgroundModes=audio`. If iOS suspends us, the 3-hour promise fails. First thing to test.
2. **whisper_ggml iOS build and speed are unverified.** It compiles whisper.cpp from source in a pod and pulls `ffmpeg_kit_flutter_new_min` (adds app size; we never use it). Speed/battery/heat on a 3-hour recording unknown. iOS suspends background work, so long transcriptions may need the app open (the job resumes per part if cut off).
3. **The Swift Apple Intelligence code has never been compiled.** Written from memory of the FoundationModels API (`SystemLanguageModel.default.availability`, `LanguageModelSession(instructions:)`, `respond(to:options:)`). Guarded by `#if canImport(FoundationModels)` and `#available(iOS 26, *)`; any failure falls back to the offline summary. If it does not compile, delete the `AppleSummarizerPlugin` class and its 3 registration lines in `AppDelegate.swift`; the app still works.
4. **Interruptions: `record` (pauseResume) and `audio_session` both touch the audio session.** They are configured with the same category, but double handling could misbehave (e.g. not resuming after a call). Device test with a real call.
5. **Billing is fake.** The paywall says so on screen. Real StoreKit products, receipt handling, refunds, and App Store review of the paywall copy are still to do.
6. **The offline summary is weak.** It only picks sentences. Good summaries need Apple Intelligence (newer iPhones only) or the cloud function (not deployed). Most users on older iPhones would get the weak one.
7. **Privacy text about Anthropic** ("does not train on API data... may keep it for a limited time") must be checked against Anthropic's current terms before any launch.
8. **iCloud backup:** recordings in Application Support are included in device backups (115 MB per hour of audio). Decide whether to exclude them.
9. **No free-space check before recording;** we only react when a write fails.
10. **Cloud function has no abuse protection** (App Attest / rate limit) yet.

## Next steps (in order)

1. **Build on a Mac** (README steps). Fix compile errors in Swift/pods first. Expected trouble spots: whisper_ggml pod, `AppDelegate.swift`, iOS 16 deployment target in pods.
2. **iPhone test plan (week 1)** - record results in a new `docs/DEVICE-TEST-1.md`:
   - **3-hour recording**, phone on battery, screen locked most of the time. Check: duration matches the clock, 36 parts, audio plays end to end, battery used.
   - **Lock screen**: start, lock for 10 min, unlock. Timer and audio continuous?
   - **Phone call**: during a recording, receive a call and answer it for 1 min; also decline one. Check the banner, the gap note in the Audio tab, that recording resumes, and the `recording_interrupted` event.
   - **Low storage**: fill the phone to under ~200 MB free, record until it fills. Expect "Stopped: the phone is out of storage. Everything up to now is saved." and a playable recording.
   - **Force-quit**: record 3 min, swipe the app away, reopen. Expect "Interrupted - saved 3 min" (within ~1-2 s), playable audio, processing starts.
   - **Crash/kill during transcription**: kill while "Transcribing part 3 of 12"; reopen; it should continue from part 3.
   - **Benchmark** (Settings > tap version 7x): run on a 30-min and a 3-hour recording with base.en and small.en. Record audio length, wall time, real-time factor, battery before/after, phone model, phone temperature (feel). Decision rule to set with the owner: e.g. if base.en RTF > 0.5 or a 3-hour file costs > 20% battery, consider cloud transcription and model its cost.
   - **Apple Intelligence**: on an iOS 26 Apple Intelligence iPhone, set Summary engine to Apple; check a real meeting summary keeps names, numbers, decisions.
   - **Headphones/Bluetooth** plugged in and out during recording.
   - **Trial reminder**: with fake billing, start a trial; temporarily change `AppConfig.trialReminderLead` or the trial length to see the notification arrive.
3. Real billing: create the two products in App Store Connect (`com.novaralabs.longnote.monthly`, `.annual`, one subscription group, 3-day free trial intro offer), implement `BillingService` with `in_app_purchase` or RevenueCat, remove the "simulated" strip.
4. Decide cloud summary: deploy the Supabase function to a NEW project (not an existing one), add App Attest + rate limit, set `ANTHROPIC_API_KEY` as a secret, build with `--dart-define`.
5. Speaker labels: evaluate cloud diarization (and its privacy cost) or tinydiarize turn marks.
6. Import an audio file; search transcript; widget/Shortcut to start recording (P1 list in the research doc).
7. App icon, launch screen, App Store privacy labels ("Data Not Collected" is true for the offline mode; cloud mode sends user content to a processor - label accordingly).

## Where things are
- Repo: `/root/projects/notetaker-app` (git, no remote, not pushed).
- Research input: `/root/projects/business-discovery/utility-apps/reference-apps/FINAL-COMBINED.md`.
- Decisions: `docs/DECISIONS.md`.

## Update 15 Nov 2026 03:45 IST: compiles for iPhone
- GitHub Actions run 43646685117 (macOS-15, latest Xcode, unsigned): `flutter test` passed, and `flutter build ios --release --no-codesign` **built Runner.app (39.4 MB)**. The Apple Intelligence Swift code and the whisper_ggml package therefore compile. They have still never run on a device.
- Repo: private `teamnuvoro/longnote`. Workflows: `ios-build-check.yml` (unsigned compile) and `ios-testflight.yml` (signed archive + TestFlight upload; the same setup as Serial Stories; secrets copied).
- Bundle id changed to `com.novaralabs.longnote` to match the team convention.
- Blocked on the owner: (1) accept Apple's updated agreement in App Store Connect (the API currently returns 403 REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED); (2) create the app record (Apps → + → New App; the API cannot create it). Then run `ios-testflight.yml`.

## Update 15 Nov 2026 ~11:30 IST: signed build works
- Bundle ID com.novaralabs.longnote registered via the API (id X7WV526ZBU). Team ID 3VF395RF2W set as the APPLE_TEAM_ID repo secret (it was empty in story-app/.env.local).
- ios-testflight.yml: config-only step now uses --no-codesign. Run 43683003177 (upload=false) archived, signed and exported the IPA.
- Apple agreement now accepted (API no longer returns 403). Remaining: the owner creates the app record in App Store Connect, then run the workflow with upload=true.
