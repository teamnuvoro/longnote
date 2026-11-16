# Plan: build Longnote v1 from the Figma (16 Nov 2026)

Status: PLAN ONLY. Nothing is built until the owner says go.
Design: https://www.figma.com/design/lGFjCA8QrgEbWcjVk6CP19 (28 screens, see DESIGN-FIGMA-V1.md).

## What I checked (16 Nov)
- Supabase project used by Serial Stories (keys in story-app/.env.local). DB login works.
  It holds 34 public tables, 38 test users, 2 storage buckets (236 files), 4 cron jobs, 3 edge functions (ai-reply, delete-account, media-url), 81 MB.
- The saved Supabase **access token is expired** (Management API returns 401). Needed to deploy functions, set secrets and rename the project.
- No Soniox key and no Anthropic key on the server. An OpenAI key exists (Kahani Ghar's).

## Step 0. Clean the Supabase project (after go)
1. Back up first: pg_dump of the whole database + download of both buckets → encrypted to the Storage Box, one line in /root/WHERE-IS-EVERYTHING.md. (Owner rule: "remove" = archive.)
2. Then wipe: the 4 cron jobs, the 3 edge functions, both buckets, all public tables/functions/types, the 38 test users.
3. Rename the project to "Longnote" (needs the new access token).
4. Note: the Serial Stories TestFlight build will stop working after this. It is paused, so that is expected.

## Step 1. Backend (Supabase), Opus writes it
- **Sign-in:** Supabase anonymous sign-in. No account screen; each phone gets a hidden user id.
- **Tables:** `jobs` (one per note: status, language, style, error, tries), `usage` (audio minutes per user per day, for limits and cost tracking). Row-level security: a user sees only their own rows. The transcript and summary are **not** stored on the server; they go back to the phone.
- **Storage:** private bucket `uploads`. The phone uploads one compressed audio file (AAC, about 15 MB per hour) with resumable upload.
- **Edge functions** (keys only in Supabase secrets, never in the app):
  - `transcribe-start`: checks limits → gives Soniox a short-lived signed link to the audio → starts async transcription with speaker labels and the chosen language (or auto) → returns a job id.
  - `soniox-webhook`: when Soniox is done, saves the result for pickup, then **deletes the audio from Soniox and from our bucket**.
  - `transcribe-result`: the phone fetches the transcript once, then the server copy is deleted.
  - `summarize`: Claude Haiku with the chosen style (9 templates or the user's own instructions). Replaces the old undeployed function.
  - `ask`: Claude Haiku answers from one transcript and returns the speaker+time of each source.
- **Abuse limits (TestFlight):** per-user hourly and daily caps (for example 6 hours of audio a day, 60 Ask messages a day), plus a global daily cost cap. App Attest comes before the App Store.
- **Cost:** Soniox about $0.10 per audio hour; Haiku summary + chat a few cents per note.

## Step 2. App foundations (Flutter)
- Theme from the Figma: colours, Newsreader / Geist / Geist Mono fonts (bundled), spacing, components (record pill, tab bar, cards, sheets, buttons).
- New navigation: 4 tabs (Notes, Ask, Import, Settings) + floating Record pill; dark recording screen.
- Data model changes in SQLite: speakers + names per note, transcript turns with speaker and time, summary style, chat messages, marked moments, language settings, upload state. Migration keeps existing notes.

## Step 3. Screens and features (in this order)
1. Recording C1–C4: waveform, Saved pill, Mark moment, language chip, phone-call banner, discard confirm (reuses today's crash-safe recorder).
2. Cloud pipeline in the existing job queue: join WAV parts → compress to AAC on the phone (native iOS) → resumable upload → start → wait → fetch → summary. Every step retries; audio on the phone is never deleted. Fallback: on-device Whisper.
3. Notes B1–B4: list with the "Waiting & needs attention" retry list, processing row, search over titles/summaries/transcripts (SQLite full-text), long-press actions.
4. Note D1–D8: processing steps, summary, transcript with speakers, rename/merge speakers, share menu (PDF / summary / transcript / audio), summary style sheet, full player with speed, failed state.
5. Ask E1–E3, Import F1–F3 (Files, Photos video sound, Voice Memos via share), Settings G1–G4 (languages, transcription choice + where audio goes, plan & billing).
6. Paywall A1–A2 restyled. Billing stays **simulated** in this build (real App Store purchases are the next step after this one).

## Step 4. Check
- Unit tests for the new parts (pipeline states, retries, speaker merge, search, limits). Existing 76 tests must still pass.
- One full Opus review of the backend, privacy and money code; small fixes by me.
- Server test with real audio: a 5-min clip, a 1-hour clip, and a Hindi-English clip through Soniox.

## Step 5. Ship to TestFlight
- `gh workflow run ios-testflight.yml -R teamnuvoro/longnote -f upload=true`.
- Write a short device-test list for the owner (record 3 h with screen locked, phone call, force-quit, speakers, share, Ask).

## Needs from the owner
1. New Supabase access token (Account → Access Tokens). The old one is expired.
2. Soniox API key (soniox.com → console → API keys; add a little credit).
3. Anthropic API key for summaries and Ask (console.anthropic.com). Or say "use the OpenAI key" instead.
4. Optional: an Apple Push (APNs) key, so we can send "your note is ready" when the app is closed. Without it, the app checks when you open it.
All keys go in through a secure prompt; none are typed in chat or put in the app.

## Not in this round
Onboarding/login, real App Store purchases, widget / Control Center, App Attest, dark mode outside recording.
