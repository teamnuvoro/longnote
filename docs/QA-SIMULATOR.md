# Simulator QA (automated, real app, real backend)

The real Longnote app runs in an iPhone simulator on a GitHub macOS runner, talks to
the real Supabase backend (Soniox + OpenAI), and is driven like a person by an
`integration_test` suite. Every check is PASS / FAIL / SKIP with screenshots; the
report is a phone-sized PDF in `docs/qa/`.

## Run it

- **Now (until v1-build is merged):** change `tools/qa/run-request.txt` in a v1-build
  commit and push. That starts `.github/workflows/ios-sim-qa.yml` (GitHub only lets
  you start a manual workflow once it is on `master`).
- **After the merge:** Actions → "iOS simulator QA" → Run workflow (or
  `gh workflow run ios-sim-qa.yml -R teamnuvoro/longnote --ref <branch>`).
  Input `only` = e.g. `1-main` to run one launch.
- Takes ~25-35 min. Cost: macOS minutes + ~60 s of audio through Soniox/OpenAI
  (a few cents). No secrets: the backend URL and anon key are the committed
  defaults in `lib/core/cloud/backend_config.dart`.
- Output: artifact `ios-sim-qa-<run id>` (screenshots, logs, `RESULTS.md`,
  `summary.json`); `RESULTS.md` is also on the run page. The job fails if any check
  failed, was skipped, hung or crashed.
- PDF: download the artifact, then
  `python3 tools/qa/make_report.py <artifact dir> docs/qa/<name>.pdf [--bugs bugs.json]`.
- On your own Mac: `tools/qa/run_sim_qa.sh` (Xcode + Flutter 3.44.1; output in
  `build/qa_out`; run 4 needs sudo to block the backend).

## How it works

| Part | What |
|---|---|
| `integration_test/qa_1_main_test.dart` … `qa_4_offline_test.dart` | One file = one app launch. Data stays between launches (`flutter drive --keep-app-running`; the app is uninstalled only before launch 1) |
| `integration_test/support/file_pcm_source.dart` | The microphone stand-in: plays a 16 kHz mono WAV from the Mac's disk into the real recorder, in real time, with levels. Only in `integration_test/`: no test code or audio in the App Store build |
| `lib/main.dart` `launchApp(sourceFactory:)`, `AppServices.boot(sourceFactory:)` | The only app hooks. The app passes nothing (= real microphone) |
| `integration_test/support/qa_harness.dart` | Checks, screenshots (`takeScreenshot`), results written to the Mac after every check, error capture (any FlutterError incl. overflow, uncaught error = FAIL), frame-freeze probe, Dart heartbeat |
| `tools/qa/watcher.py` | On the Mac: if the heartbeat stops for 45 s (a microtask livelock like build 105's freeze stops every Dart timer) it records a HANG with a simulator screenshot and a native `sample` of the app, then stops the launch. Also does the app's requests (unblock the backend) |
| `tools/qa/net_block.sh` | Server unreachable: `/etc/hosts` sends the Supabase hosts to 127.0.0.1 and a pf rule rejects their IPs; `off` undoes it |
| `tools/qa/run_sim_qa.sh` | Boots a simulator, makes the WAVs (`afconvert`), streams the app's log (`log stream`), runs the 4 launches, collects crash reports + the app's own diagnostics, writes `summary.json`/`RESULTS.md` (`summarize.py`) |
| `integration_test/fixtures/*.m4a` | Cut from the 2-voice TTS meeting (`tools/e2e/make_audio.py`): 34.6 s + 10.5 s + 10.7 s + 6 s ≈ 62 s of paid audio per full run |

## Known build quirk

`whisper_ggml` pulls in `ffmpeg_kit_flutter_new_min`, whose iOS frameworks have no
arm64-simulator slice (its podspec excludes arm64 for the simulator). Flutter
only notices when `ios/Pods` already exists, and then builds the simulator app for
x86_64. On a clean checkout the first build links arm64 and fails ("Building for
'iOS-simulator', but linking in dylib ... built for 'iOS'"). `run_sim_qa.sh`
runs `flutter build ios --simulator --debug --config-only` first (pod install),
and retries a launch once if its build still fails. The App Store build is not
affected.

## What is checked

**Launch 1 (fresh install)**
- A1-A4 Onboarding → paywall (price line has a price and a date) → Start free trial →
  "trial is on" → Skip → empty Notes with the trial chip.
- B1 Record: recording screen, timer and mic level move. B2 Mark moment (saved).
  B3 Pause stops the timer, Resume continues. B4 Stop & save → note screen →
  "Tell you when it’s ready?" sheet → Not now (time to the note screen is logged).
- C1 Back to Notes and re-open the note up to 14 times while it processes (the build
  105 freeze); every screen change must come within 4 s. C2 The note reaches a
  summary that is on screen (status steps and time logged).
- D1 Transcript tab: ≥ 2 speakers. D2 Tapping a line moves the player there.
  D3 Edit names → both renamed. D4 Ask a question → answer with a source chip → the
  chip opens the transcript at that line (highlighted) → back, back.
  D5 Share: PDF, Summary, Transcript, Audio (M4A and WAV), Copy summary. D6 Notes
  lists the note. D7 Search "screenshots" (said in the audio) finds the note.

**Launch 2:** E1 reopens on Notes; E2 records ~10 s and the app is force-quit
(SIGKILL, like swiping it away).

**Launch 3:** F1 "The app closed while recording / We kept what was saved"; F2 that note
processes to a summary. G1-G7 Settings: audio language (Hindi), summary language,
summary style (Lecture), transcription, "What happens to your audio", Plan & billing,
speaker labels toggle, privacy policy / terms / contact links. H1 every tab tapped fast
3 rounds; H2 double-tap search / trial chip / a note opens each once; H3 double-tap
Record opens one recording screen, Discard keeps no note. I1-I2 Import → Files → details
→ Import and transcribe → the imported note reaches a summary.

**Launch 4 (backend blocked before launch):** J2 a recorded note waits in "Waiting &
needs attention"; J3 the host unblocks and the note uploads and finishes with no tap.

## Not covered (needs the iPhone: docs/DEVICE-TEST-V1.md)

- Lock screen while recording, a real phone call, battery/heat, 1-3 h recordings, feel.
- The real microphone (the file source feeds the same recorder, disk writer and pipeline).
- iOS permission alerts (mic, notifications): a Flutter test cannot tap system alerts;
  the runs take "Skip" / "Not now". "Allow the reminder" / "Notify me" are not tapped.
- The iOS share sheet UI: the share_plus channel is answered by the test, which checks
  the files/texts the app hands to iOS (PDF built, M4A encoded natively, WAV joined).
- The iOS Files picker UI: the test hands the import a file from the Mac; copying,
  length reading (real iOS player), native compression and processing are real.
- Real App Store billing (simulated in v1).
- The app's own crash upload: during a run the test takes over Flutter's error
  handlers (errors go into the report instead of the `report` function).
