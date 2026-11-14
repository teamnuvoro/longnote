# Decisions (v0.1, built overnight 15 Nov 2026)

One line each: the decision, then why. "Lead" = set in the brief. "Build" = made during the build.

## Product and scope
- **No Supabase, no account, no sign-in in v1** (lead). Nothing to sign up for; less to break; the privacy promise is simpler.
- **App name "Longnote", bundle id `in.novaralabs.longnote`, iOS 16+** (lead). Placeholder; ASO later.
- **Consent line in onboarding and privacy screen** (build). The research says not to copy Summary's "secretly record" hook; recording others needs consent.
- **A user can delete a recording, only with a confirmation dialog** (build). Users expect it; it is the only code path that deletes audio.
- **Portrait only** (build). Simpler layout for v1.

## Capture
- **`record` in PCM16 stream mode, 16 kHz mono, written to our own WAV files** (lead). An m4a/AAC file is unreadable if the app dies before it is finalized; a WAV is always repairable. 16 kHz mono is exactly what whisper needs (no decode step).
- **5-minute rotating segments** (lead). A crash can only damage the open part; transcription can resume per part.
- **Every chunk is written to disk immediately; header sizes updated and fsync every ~1 s** (build, refining the lead's "flush every ~1 s"). A crash of the app loses at most the chunk in flight; a phone power-off loses at most ~1 s.
- **On recovery, files on disk are the truth, not the DB** (build). A crash between "new part created" and "DB row written" must not lose that part.
- **WAV repair rewrites RIFF/data sizes from the file length and drops a half sample** (lead + build).
- **Heartbeat to SQLite every 5 s** (lead). Lets recovery report the last-alive time.
- **Honest interrupted wording: "Interrupted - saved X min"** (lead). We never claim recording continued after a force-quit; iOS stops it.
- **Phone calls: `record` pauses/resumes itself (`AudioInterruptionMode.pauseResume`); `audio_session` events mark a gap and drive the banner** (build). Let the plugin that owns the audio engine restart it; we only explain and log it.
- **Headphones plugged/unplugged: follow the new mic (`AudioRouteChangeMode.follow`)** (build). The default (pause) would silently stop a 3-hour lecture.
- **Out of storage: stop cleanly, keep what was saved, say so** (build). There is no Dart API for free space without another plugin; we react to the write error (ENOSPC).
- **Audio stored in Application Support, paths stored relative** (build). iOS container paths change between installs; Documents would also show up in the Files app. Note: Application Support is included in iCloud device backups (TODO: decide if recordings should be excluded).
- **Processing pauses while recording** (build). Keeps CPU and battery for capture. A job already running finishes.
- **No live transcription during recording in v1** (build). Saves battery and risk; can be added later (whisper_ggml supports it).

## Transcription
- **whisper.cpp on device via `whisper_ggml` 2.9.0** (lead: pick the best maintained package). Chosen over `whisper_ggml_plus` / `whisper_kit` / `whisper_flutter_new`: most used (~10k downloads/30 days), verified publisher, released 5 Nov 2026, iOS supported, whisper.cpp 1.9.5 with Accelerate. Downside: it pulls `ffmpeg_kit_flutter_new_min` (app size). We pass WAV directly so ffmpeg is never used.
- **Default model base.en (148 MB); Settings offers base, small.en, small** (lead: configurable). English-only models are more accurate for English; multilingual uses language auto-detect.
- **Our own model download with progress** (build). The package's `downloadModel` has no progress and holds the whole file in RAM.
- **`maxContext: 0`** (build). whisper_ggml's README: stops a hallucinated phrase repeating across a long recording.
- **`keepModelLoaded: true` during one recording, released after** (build). Avoids reloading the model for every 5-minute part.
- **No speaker labels (diarization) in v1** (lead). whisper cannot tell speakers apart. The `speaker` column exists and is always empty. TODO: cloud diarization later (or the tinydiarize model, which only marks turns). We do not fake labels.

## Processing queue
- **Persistent job table, one job at a time, 4 automatic tries with backoff 10 s, 20 s, 40 s (cap 10 min), then "failed" + a Retry button** (build). Retries must survive app restarts.
- **Failure never deletes audio** (lead). The queue only writes status rows; tested.
- **Resumable per segment** (build). Each part's transcript is saved as soon as it is done; a retry continues where it stopped.

## Summary
- **Three summarizers behind one interface: Apple on-device, cloud, local extractive** (lead).
- **Engine choice "Automatic" (default) = Apple Intelligence if available, else local** (build). Private by default; no network unless the user opts in.
- **If the chosen engine fails, use the local one and say so on the summary** (build). The user always gets something, and is told which engine made it.
- **Same instructions text for Apple and cloud** (build). Kept in `summarizer.dart` and copied into the Supabase function.
- **Prompt rules: keep names, numbers, dates, votes/motions; owner/due only when said; never invent** (lead).
- **Chunk sizes: Apple 6,000 chars (small context window), cloud 100,000 chars, local unlimited** (build).
- **Chunk -> summarize each -> merge with de-duplication in Dart** (lead + build). Same merge for every engine; no extra LLM call.
- **Defensive JSON parsing (fences, chatter, aliases, "unknown"/"TBD" -> no owner/date)** (build). Small on-device models are messy.
- **Cloud = Supabase Edge Function calling Anthropic `claude-haiku-5-5` with structured JSON output; key only in a server secret** (lead). Not deployed. Uses the official Anthropic TypeScript SDK via `npm:` import, `effort: low`, a JSON schema. The app sends text only, never audio.
- **The app may hold the Supabase anon (publishable) key** (build). It is public by design; it is not an AI key. TODO: App Attest / rate limit before launch.
- **Local extractive summarizer never writes new words** (build). It cannot invent owners or dates; the UI labels it "Basic offline summary".

## Billing
- **Monthly $9.99 and yearly $59.99, 3-day trial, no weekly plan** (lead).
- **Billing behind `BillingService`; v1 ships `FakeBillingService`** (lead). No StoreKit products exist yet. Swap in `in_app_purchase` or RevenueCat later; UI does not change.
- **First recording is free (any length) with full summary; paywall when starting the 2nd** (lead).
- **A recording under 30 s does not use up the free recording** (build). A mis-tap or an early crash should not burn the free try.
- **Viewing, playing, exporting old recordings is never blocked** (build). Honest: you keep what you made.
- **Trial reminder 26 h before the trial ends (brief said "1 day")** (build). Apple can charge up to 24 h before the period ends; a reminder at exactly 24 h could arrive after the charge.
- **Paywall shows: today's price, the exact charge date and amount, that it renews, and how to cancel - all above the buy button** (lead).
- **Notification permission is asked right after the trial starts** (build). That is when the reason is obvious.
- **Paywall shows a "Test build: purchases are simulated" strip** (build). Honest while billing is fake. Remove with real StoreKit.

## Analytics
- **Local-only SQLite `events` table, no third-party SDK** (lead). Viewable in Settings > Usage log.
- **`recording_interrupted` is used for both app-kill (cause `app_closed`) and phone calls (cause `audio_interruption`)** (build). One event name, cause in props.

## App structure
- **provider + ChangeNotifier, one `AppServices` container** (build). Minimal dependencies.
- **Apple summarizer Swift code lives in `AppDelegate.swift`** (build). Adding a new Swift file needs Xcode project edits that cannot be checked here; AppDelegate is already in the target.
- **Hidden Benchmark screen (tap version 7 times)** (lead: hidden). Includes dev toggles: fake transcriber, reset test billing.
- **PDF uses bundled Noto Sans (+ Devanagari fallback)** (build). The default PDF font cannot show ₹, Hindi, or many names.
