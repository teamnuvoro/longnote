# Decisions (v0.1, built overnight 15 Nov 2026)

One line each: the decision, then why. "Lead" = set in the brief. "Build" = made during the build.

## Product and scope
- ~~**No Supabase, no account, no sign-in in v1**~~ **SUPERSEDED 16 Nov:** v1 uses Supabase with a hidden anonymous sign-in (see "Backend (16 Nov)"). Still no account screen.
- **App name "Longnote", bundle id `com.novaralabs.longnote`, iOS 16+** (lead). Placeholder; ASO later.
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

## Backend (16 Nov)
Contract: `docs/BACKEND-API.md`. Code: `supabase/`. Test: `tools/e2e/`.
- **Cloud transcription = Soniox async `stt-async-v6`, diarization + language ID on** (owner go 16 Nov). $0.10/audio hour with speaker labels; what Summary AI uses (R4).
- **Supabase anonymous sign-in, one hidden user per install** (owner go). Per-user limits and RLS need a user id; no account screen.
- **Soniox fetches our audio from a 3-h signed URL, not via its Files API** (build). No 40 MB pass-through in an edge function; one less copy to delete. 3 h covers Soniox queue time.
- **Upload: TUS resumable to the private `uploads` bucket, `<uid>/<note>.m4a`, 6 MB chunks, x-upsert** (build). Survives network loss on 40-70 MB files; one path per note makes retries idempotent.
- **Bucket/project file cap 500 MB; real cap is Soniox's fixed 300 min per file** (build). The app splits >5 h recordings.
- **Webhook first, poll fallback** (build). Webhook has a secret header; if it does not arrive 2 min after Soniox finishes, `transcribe-status` pulls the result; hourly cleanup catches the rest.
- **Audio deleted from our bucket and Soniox as soon as a job ends; any object >24 h swept hourly** (lead). "Audio does not linger" is the privacy promise.
- **Transcript held only until the app acks it (else 15-30 min after fetch, else 7 days)** (build; the brief said "cleared once fetched"). A lost reply must not lose the transcript; the ack keeps the window near zero.
- **Turns = same-speaker tokens merged, split at a sentence end after 30 s and anyway after 90 s** (build). Lectures would otherwise be one giant turn; Ask sources need fine timestamps.
- **Limits: 8 h audio/day, 4 h/rolling hour, 5 h/file, 40 summaries/day, 60 asks/day, $20/day global estimated spend; all env secrets** (lead). TestFlight abuse guard until App Attest. Charged on start (max of claimed length and bytes/12 kB), corrected to Soniox's duration, refunded on failure.
- **Summary + Ask on OpenAI `gpt-5.4-mini` (Structured Outputs, `reasoning_effort: low`); Anthropic removed** (owner: use the OpenAI key). Picked from `GET /v1/models` on 16 Nov: current small model, 400k context, $0.75/$4.50 per M tokens. Override with `OPENAI_MODEL`.
- **Summary JSON keeps the old keys + adds `in_short`; 9 styles; user `custom_instructions` are preferences inside the user message, never system rules** (lead). Old Dart parser keeps working; prompt injection cannot lift the anti-invention rules. Note: `summarizer.dart`'s Apple prompt no longer matches the server prompt word for word.
- **Ask returns `found` + sources; sources not matching a real input `start_ms` are dropped server-side** (lead). The model cannot invent a timestamp.
- **Ask transcript cap 240k chars; above it keep the turns most related to the question + neighbours, `truncated: true`** (build). Fits ~4.5 h verbatim; simple, no embeddings.
- **Stable error codes `{error:{code,message,detail}}`** (lead). The app maps codes to plain words.
- **Function calls require a real user token; the anon key alone gets 401** (build). verify_jwt accepts the anon key, so each function checks the user with GoTrue.
- **Storage objects are deleted via the `cleanup` function (pg_cron → pg_net), not SQL** (build). Supabase blocks direct deletes from `storage.objects`.

## App v1 build (16 Nov)
Foundations for the Figma v1 screens. Map: `docs/APP-ARCHITECTURE.md`.
- **Design tokens copied from the Figma foundations (2:2) into `lib/ui/tokens.dart`; derived colours (fills, tints, night) taken from the frames** (build). One source of truth; screens never use raw colours/fonts.
- **Fonts bundled as the google/fonts variable TTFs (Newsreader, Geist, Geist Mono) with OFL files; every style sets `fontVariations`** (build). No runtime download (google_fonts would fetch from the network); Flutter does not map `fontWeight` to the `wght` axis by itself.
- **Figma icons exported as SVG and drawn with flutter_svg, tinted per use** (build). Exact match to the design; one file per icon.
- **go_router with a `StatefulShellRoute` (4 tabs, each keeps its stack); detail screens, sheets and recording on the root navigator** (build). Matches the frames (no tab bar on D/C screens); named routes for every frame; sheets are routes (`SheetPage`), so they are deep-linkable and testable.
- **v0.1 detail, recording and paywall screens stay wired into the new routes until the screens session replaces them; Notes (B1) and Settings (G1) got minimal real versions** (build). The app keeps working end to end on TestFlight between sessions.
- **First run: onboarding → paywall (once) → Notes; phones that already have notes skip it** (lead: paywall first after login).
- **Plain HTTP for Supabase (auth, functions, TUS), no supabase_flutter** (build; the brief allowed either). Fewer native pods, fully unit-testable with a fake server. The session (anonymous user, refresh token) is stored in the app database; refresh 5 min before expiry; a rejected refresh token signs up a new anonymous user.
- **Supabase URL + anon key committed in `lib/core/cloud/backend_config.dart`, overridable with `--dart-define` / repo variables** (build). The anon key is public by design (role `anon`, checked); no other key is in the app.
- **AAC encode in Swift with AVMutableComposition → AVAssetReaderAudioMixOutput (16 kHz mono PCM) → AVAssetWriter (AAC-LC 32 kbps) in AppDelegate.swift** (build). Handles our WAV parts and any imported format (resamples, mixes down); no new Swift file, so no Xcode project edits.
- **Turns are the existing `transcript_lines` table (speaker = key, + language); names live in `speakers`** (build). The v0.1 transcript, export and PDF code keeps working; rename = one row; merge = rewrite keys + delete.
- **One `processing_status` column with the richer states (compressing, uploading, queuedOnServer, waitingForNetwork)** (build). One source of truth for the UI; old values still parse.
- **Waiting is not failing: polling, offline and usage limits defer the job without using a try; only real errors count toward the 4 tries** (build). A long offline period or a daily limit must not end in "failed".
- **limit_reached shows as failed (with the reason) but retries itself after the reset (00:02 UTC next day, or 15 min for the hourly limit)** (build). The user sees why; nothing to tap.
- **bad_request / too_long / payload_too_large fail at once** (build). Retrying cannot fix them.
- **Server-side transcription failure → forget the upload (the server deleted the audio) and upload again on the next try** (build; BACKEND-API 6).
- **Over 5 h: 4-h pieces (`<note>_pN`), all started before polling, turns offset by the piece start; speaker keys kept distinct per piece ("2:1") for the user to merge** (lead).
- **Cloud mode summarizes with the cloud summarizer only; a failure retries rather than silently falling back to the offline summary** (build). The offline summary is weak; the user should get the real one or a visible retry. On-device mode keeps the v0.1 engine choice.
- **Cloud summary and Ask send the user's JWT** (lead; fixes the v0.1 client, which sent the anon key and would get 401). The old cloud-summary test was updated to this contract.
- **Search: SQLite FTS5 (`unicode61`, diacritics removed, prefix per word, all words must match), external-content index on the turns kept by triggers; LIKE fallback if FTS5 is missing** (build). Fast on long transcripts; Hindi/Devanagari tokenises fine.
- **"Note ready" = local notification only when the app is in the background; no push server** (lead). Works while iOS keeps the app alive or when it is next opened. The permission is still asked only at trial start (screens session: decide whether to ask after the first recording).
- **iCloud backup: recordings stay in backups by default; a setting excludes the folder** (build; HANDOFF risk 8). A phone restore should bring recordings back; users short on iCloud space can turn it off.
- **Default transcription mode = cloud; on-device whisper stays as the fallback and as a per-note "Transcribe on this phone instead"** (owner go on Soniox, 16 Nov).
- **The compressed m4a is kept next to the WAV parts after upload** (build). Never deleting local audio is the rule; ~14 MB/h extra. Clean-up can come later with the user's consent.
- **Widget gallery lives under the hidden Benchmark screen (all builds, not only debug)** (build). TestFlight builds are release builds; the owner can still see the components.
