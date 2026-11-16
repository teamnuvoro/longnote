# Session handoff, 16 Nov 2026: Longnote (consumer app #1)

Read this first in the next session. Then read `docs/HANDOFF.md` (device test plan + build history) and `docs/DECISIONS.md` (why things are the way they are).

## 1. What we are building (locked decisions, do not re-open)
- **Plan:** a "conveyor belt" of single-utility iOS apps that charge US/EU users. App #1 = **AI note-taker for long recordings**, working name **Longnote**. Company: Novara Labs LLP.
- **Brand:** honest billing, honest privacy, reliable capture.
- **Pricing:** $9.99/month, $59.99/year, 3-day trial. **No weekly plan.** Reminder before the trial charges; cancel in one tap.
- **Ad hook to test:** "record 3 hours. never lose a word. no limits." Audiences: students, people in meetings all day, optionally sermon listeners.
- **Reference apps:** Summary AI (Labhouse) and Minat (Namit Gupta / ForwardPath).
- **Table stakes, not differentiators:** unlimited length, never losing a recording. Speaker labels are in v1.
- **Owner's latest steer (15-16 Nov):** Minat is simpler, so launch a **Minat-sized v1** first, with our own design (see section 5).
- **Owner's goal:** ship to the US App Store by end Dec 2026; he quits his job when app income holds ~Rs 20 LPA for 2-3 months.

## 2. Research (all done, in `/root/projects/business-discovery/utility-apps/`)
| File | What it holds |
|---|---|
| `SUMMARY.md`, `A1`-`A5` | Market data: AppTweak revenue, keywords, Apple overlap, Meta ads. Note-taker job: Otter $1.76M/mo, Summary $1.74M/mo (US iPhone est.) |
| `reference-apps/R1`-`R3` | AppTweak data, Summary AI deep dive, Minat deep dive (reviews, features, timeline) |
| `reference-apps/FINAL-COMBINED.md` | Our research merged with Instinct's (the owner's friend) PDF. Has the **MVP priority table (P0/P1/Later)** |
| `reference-apps/R4-TRANSCRIPTION-STACK.md` | How both apps transcribe (section 4 below) |
| `reference-apps/ui-shots/` | All 19 App Store screenshots (`minat_1..10.jpg`, `summary_1..9.jpg`, plus `*_sheet.jpg` contact sheets) |

Key numbers:
- **Summary AI:** about $3.2M/mo worldwide (AppTweak est.), from a 50-60 person studio in Barcelona.
- **Minat:** about $1k/mo, built by one person.
- **What users hate most:** surprise charges and trials; lost recordings; recordings stuck in processing; wrong language.

## 3. The app as it stands
- **Repo:** `/root/projects/notetaker-app`, GitHub private `teamnuvoro/longnote`, branch `master`. Flutter 3.44.1 (at `/opt/flutter`), iOS-first, iOS 16 target. 76 unit tests pass.
- **Built (see README "What is real vs stubbed"):**
  - Crash-safe recording: PCM 16 kHz mono into 5-minute WAV parts, flushed every 1 s, with recovery after a crash.
  - Job queue with retry.
  - On-device Whisper transcription (`whisper_ggml`).
  - 3 summarizers: Apple FoundationModels in Swift, a cloud Supabase function (Claude Haiku, **not deployed**), and a local extractive one.
  - Fake billing with the paywall and trial-reminder logic.
  - PDF, share and copy.
  - Screens: onboarding, home, recording, detail, paywall, settings, privacy, plus a hidden benchmark screen.
- **Not built:** speaker labels, cloud transcription, real StoreKit/RevenueCat billing.
- **Apple / TestFlight, all working:**
  - Bundle ID `com.novaralabs.longnote` (registered via the API).
  - Team ID `3VF395RF2W`. ASC app id `6835017154`. SKU `longnote`.
  - **Build 104 is on TestFlight** (processed VALID, encryption flag set).
  - Internal group "Team" includes the owner (tibdewalsiddhant@novaralabs.in).
- **How to ship a new build:** run `gh workflow run ios-testflight.yml -R teamnuvoro/longnote -f upload=true`. It takes about 10 min on a GitHub macOS runner; Apple processing adds 5-20 min.
  - `ios-build-check.yml` = unsigned compile + tests only.
  - Repo secrets set: ASC_KEY_ID, ASC_ISSUER_ID, APPLE_TEAM_ID, ASC_KEY_P8_BASE64.
- **App Store Connect API from the server:** `/root/projects/openalgo-v2/.venv/bin/python tools/asc.py GET /v1/apps`. It reads the key from story-app and never prints secrets.
- **Device testing: NOT done yet.** Nothing has been checked on a real iPhone. The tests are listed in `docs/HANDOFF.md`: short record, 30-min lock screen, force-quit recovery, phone-call interruption, then 3 hours.

## 4. Transcription finding (15 Nov), changes the plan
- **Summary AI** uses cloud transcription, **not on-device**:
  - Its Android app has Soniox's realtime websocket address built in, along with a speaker-diarization setting.
  - Its privacy policy names Soniox, Gladia and Replicate (Whisper).
  - Summaries are done by Gemini and OpenAI.
- **Minat** (per Namit's 2024 Devpost post) used the OpenAI Whisper API on a server, after FFmpeg chunking, with GPT-4o-mini summaries. Its current stack is unknown.
- **Recommendation (not yet approved by the owner):**
  - Cloud transcription by default via **Soniox async**: about $0.10 per audio hour, speaker labels included, 3.0% WER on Artificial Analysis.
  - ElevenLabs Scribe is the best-quality alternative: 1.9% WER, about $0.20/hr.
  - Keep on-device Whisper as an "offline / private mode".
  - Run the API through the Supabase edge function so **no API key ships in the app**.
  - First run a bake-off on 5-10 real recordings: Soniox vs Scribe vs on-device Whisper, including a noisy room and Indian-English speakers.
- Avoid OpenAI `gpt-4o-transcribe` / `whisper-1`: per R4 they shut down on 2027-02-26.
- **Privacy message changes to:** "we tell you exactly where your audio goes and delete it after transcription", instead of "everything stays on your phone".

## 5. Next work: the Minat-sized v1 (proposed, waiting for the owner's go)
From Minat's screenshots, its core is:
- a recordings list with search and a big record button
- a recording screen with waveform, timer, cancel/stop/pause
- a detail screen with an editable title and Summary / Transcript tabs
- a speakers toggle with "Edit names"
- share as PDF, audio, summary or transcript
- a "Pending uploads" list with retry and delete

Our build already covers most of this. To add for v1:
1. Cloud transcription (Soniox via the Supabase function), with speaker labels.
2. A share menu: PDF, audio, summary, transcript.
3. Rename speakers in the transcript.
4. A visible "waiting to process / retry" list.
5. A language picker.

**Later:** templates, AI chat, widgets / Control Center, translation, YouTube import.

**Rule:** copy the flow and features, never Minat's look. Use our own colours, layout and name. Apple rejects copycat apps (guideline 4.1), and we don't clone another app's design.

The owner will paste more Minat screenshots in the next session.

## 6. Standing rules (from the owner)
- Answer in simple, short English. Detail goes in files, not chat.
- Delete nothing. "Remove" means archive to the Storage Box and add a line to `/root/WHERE-IS-EVERYTHING.md`.
- Never touch live trading, OpenAlgo or Kahani Ghar. Never place orders.
- Never put API keys in the app. Never print secrets.
- The Serial Stories Supabase tables may be dropped if Longnote needs that Supabase project (owner said so); prefer not to unless needed.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Once the owner approves a piece of work, carry all its steps through and report once.
- In discussion, answer and ask; don't start big work without his go.
- Model policy: Sonnet for research/extraction, Opus for design and money/billing code.
