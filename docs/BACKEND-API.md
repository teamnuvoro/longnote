# Longnote backend API (v1, 16 Nov 2026; review-B fixes applied the same day)

This is the contract the Flutter app is built against. Server code: `supabase/`
(migrations + edge functions). End-to-end test: `tools/e2e/`.

- Project: Supabase "Longnote" (Pro plan, us-east-1). `<ref>` = the subdomain of `SUPABASE_URL`.
- The app holds only `SUPABASE_URL` and the anon key. Every AI/transcription key is a server secret.
- All times are milliseconds (`*_ms`) or seconds (`*_seconds`). Days for limits are **UTC** days.

## 1. Sign-in

Anonymous sign-in, once per install; keep and refresh the session (supabase_flutter does this).

```dart
await Supabase.instance.client.auth.signInAnonymously();
```

Raw HTTP: `POST {SUPABASE_URL}/auth/v1/signup` with header `apikey: <anon>` and body `{}`
→ `{access_token, refresh_token, expires_in: 3600, user: {id, is_anonymous: true}}`.

Every function call below sends:

```
Authorization: Bearer <user access_token>     (NOT the anon key: the anon key alone gets 401 unauthorized)
apikey: <anon key>
Content-Type: application/json
```

Access tokens last 1 hour. Refresh before long uploads and before each call.
Supabase limits anonymous sign-ups to **10 per hour per IP** (lowered from the default 30 on 16 Nov).

**Refresh failures:** only a 400/401/403 whose `error_code` says the refresh token is dead (`refresh_token_not_found`,
`refresh_token_already_used`, `session_not_found`, `session_expired`, `user_not_found`, `user_banned`) means "sign up again".
Real reply: `400 {"code":400,"error_code":"refresh_token_not_found","msg":"Invalid Refresh Token: Refresh Token Not Found"}`.
Anything else (5xx, 429, network) is temporary: retry later with the same user. A new user cannot see the old user's
jobs or uploads (`not_found`), so the app uploads those notes again under the new user.

## 2. Upload the audio

- Bucket: `uploads` (private). Path: **`<user_id>/<client_note_id>.m4a`**.
- `client_note_id`: the phone's note id, 1-64 chars of `A-Z a-z 0-9 _ -`. One note = one path = one job.
- Format: AAC-LC in m4a, mono, 16 kHz, ~32 kbps (≈14.4 MB per hour). Content type **`audio/mp4`**
  (also allowed: `audio/m4a`, `audio/x-m4a`, `audio/aac`; anything else is rejected).
- A user can upload/read/overwrite/delete only inside their own `<user_id>/` folder (storage RLS).
  Another folder → HTTP 403.
- File size cap: **100 MB** per file (bucket limit; 5 h at 32 kbps is ~72 MB). Not the binding limit; see section 7.
- At most **25 objects** per user in the bucket at a time (a 26th new path → HTTP 400). Each object is deleted as soon as
  its transcription ends, so a real user has 1-3; overwriting an existing path (upsert, TUS resume) is not counted.

### Resumable upload (TUS), the default

- Endpoint: **`POST https://<ref>.storage.supabase.co/storage/v1/upload/resumable`**
  (the direct storage host; `{SUPABASE_URL}/storage/v1/upload/resumable` also works but is slower for big files).
- Headers on every TUS request:
  ```
  Authorization: Bearer <user access_token>
  apikey: <anon key>
  Tus-Resumable: 1.0.0
  x-upsert: true            (so a retry of the same note overwrites a half-finished or old object)
  ```
- Create (POST) also sends `Upload-Length: <bytes>` and
  `Upload-Metadata: bucketName <b64("uploads")>,objectName <b64(path)>,contentType <b64("audio/mp4")>,cacheControl <b64("3600")>`
  → `201`, header `Location` = the upload URL. Store it with the note.
- Then `PATCH <Location>` with `Upload-Offset: <offset>`, `Content-Type: application/offset+octet-stream`,
  body = next chunk → `204` with the new `Upload-Offset`.
- **Chunk size: exactly 6 MB (6,291,456 bytes)** for every chunk except the last. Supabase requires this.
- Resume after a crash / network loss: `HEAD <Location>` → `Upload-Offset`, continue from there.
  An upload URL is valid for 24 hours; after that start a new upload (POST) for the same path.
- If the access token expires during a long upload, refresh it and send the new token on the next PATCH.
- Dart: the `tus_client_dart` package (or a 40-line hand-rolled client like `tools/e2e/e2e.py: tus_upload`).

### Standard upload (small files, fallback)

`POST {SUPABASE_URL}/storage/v1/object/uploads/<path>` with the two auth headers,
`Content-Type: audio/mp4`, `x-upsert: true`, body = the file → `200 {"Key": "uploads/<path>", "Id": ...}`.

## 3. Job state machine

```
            transcribe-start                Soniox webhook / status fallback        app fetches          ack or 24 h  
 (upload) ─────────────────> transcribing ─────────────────────────────────> done ─────────────> fetched ───────────> fetched (result cleared)
     │                            │
     │ Soniox refused 3 times     │ Soniox error / 6 h timeout
     ▼                            ▼
   failed  <──────────────────────┘          failed/fetched + a NEW upload + transcribe-start → transcribing again
```

| status | meaning | audio on server? | app action |
|---|---|---|---|
| `uploaded` | job row exists, transcription not started (limit hit or provider refused) | yes (≤24 h) | call `transcribe-start` again later |
| `transcribing` | Soniox is working | yes | poll `transcribe-status` |
| `done` | transcript ready, not yet fetched | **no** (deleted when it finished) | fetch it with `transcribe-status` |
| `fetched` | app received the transcript | no | save it, then send `ack` |
| `failed` | gave up; `error.code` says why | **no** (deleted) | re-upload, then `transcribe-start` (same `client_note_id`) |

The audio is always kept on the phone; the server copy is temporary.

## 4. Endpoints

All are `POST {SUPABASE_URL}/functions/v1/<name>` with a JSON body and JSON reply.

### Errors (every endpoint)

```json
{"error": {"code": "limit_reached", "message": "Daily limit reached. It resets at 00:00 UTC.", "detail": {"scope": "user_day"}}}
```

| code | HTTP | plain words for the app | when |
|---|---|---|---|
| `bad_request` | 400 | "Something in the request was wrong." | invalid field; `detail` may say which |
| `unauthorized` | 401 | "Please reopen the app to sign in again." | no/expired user token, or anon key used as token |
| `not_found` | 404 | "We could not find that upload/job." | `transcribe-start` before the upload finished (or its audio was swept); unknown job, or another user's job. App: upload again and start again |
| `method_not_allowed` | 405 | — | not POST |
| `payload_too_large` | 413 | "This is too long to send at once." | body/transcript over the caps below; `detail.max_*` |
| `too_long` | 422 | "Recordings over 5 hours can't be transcribed in one piece." | audio over 300 min; `detail.max_seconds` |
| `limit_reached` | 429 | depends on `detail.scope` (below) | a usage limit |
| `upstream_failed` | 502 | "The transcription/AI service had a problem. Try again." | Soniox/OpenAI error |
| `server_error` | 500 | "Something went wrong on our side. Try again." | our bug or DB trouble |

`limit_reached` scopes: `user_day` ("Daily limit reached, resets 00:00 UTC"), `user_hour`
("Too much audio in the last hour, try again later"), `global_day` ("Service is busy today, try tomorrow"),
`ip_day` ("Too much use from this network today, resets 00:00 UTC"; per-IP cap, section 5).

### 4.1 `transcribe-start`

Request:
```json
{"client_note_id": "n_2026_11_16_0930", "audio_path": "<user_id>/n_2026_11_16_0930.m4a",
 "audio_seconds": 3725.4, "language": "auto", "language_hints": ["hi", "en"]}
```
- `audio_path` must be exactly `<user_id>/<client_note_id>.m4a`.
- `audio_seconds`: length of the recording (number > 0, ≤ 18000).
- `language`: `"auto"` or a code (`"en"`, `"hi"`, `"es"`, `"pt-BR"` ...). A code is sent to Soniox as the first language hint.
- `language_hints` (optional): up to 10 codes the user expects (e.g. `["hi","en"]` for Hinglish). Language identification is always on, so each turn carries its language.

Reply `200`:
```json
{"job_id": "3d3ed4a4-44aa-4cbd-a3c2-b8dc91e1558e", "client_note_id": "n_2026_11_16_0930", "status": "transcribing"}
```
- **Idempotent** on (user, `client_note_id`): calling again returns the same job and does not start a second transcription
  while it is `transcribing`/`done`. Parallel calls are safe: an atomic claim lets exactly one of them charge and call Soniox;
  the others get `200` with the same `job_id` and `status` `uploaded` or `transcribing` (poll as usual; `uploaded` → call
  start again). Tested with 5 parallel calls: one job, one Soniox transcription. If the job is `failed` or `fetched` and a **new** upload exists at the path, it starts over
  (and is counted against limits again). If no new upload exists, it returns the job as is. A job still `uploaded` whose audio is gone → `not_found`.
- Errors: `not_found` (object missing), `bad_request`, `too_long`, `limit_reached`, `upstream_failed`
  (`detail.tries_left`; after 3 failed starts the job is `failed` and the audio is deleted: re-upload to retry).
- Server side: checks the object exists and is the user's, charges `max(audio_seconds, bytes / 4000)` seconds against limits
  (the floor = our 32 kbps format; it stops an understated length; `too_long` if bytes / 4000 > 1.05 × the max seconds),
  then in one SQL step (`ln_reserve_audio_v2`) checks and charges: the user's day and rolling hour, the client IP's day
  (IPv6: per /64), the global **audio** pool and the total cap (`limit_reached` scopes `user_day`, `user_hour`, `ip_day`,
  `global_day`; a refusal charges nothing). It makes a signed URL valid 3 h and starts Soniox `stt-async-v6` with speaker
  diarization, language identification, language hints, and our webhook. Every Soniox call has a 30 s timeout. All
  charges (user, IP, pool) are corrected to Soniox's real duration when done, and refunded if Soniox fails.
- **Lost reply:** if Soniox does not answer the create call (timeout), the outcome is unknown: the job stays `uploaded`
  with `error_code` `upstream_failed` (`tries_left` as usual) and keeps its charge. The next `transcribe-start` first looks
  for a transcription with `client_reference_id` = the job id and **adopts** it instead of creating a second one; if its
  webhook arrives first, the webhook adopts it. A transcription that no job points to is deleted at Soniox (webhook or
  hourly cleanup).

### 4.2 `transcribe-status`

Request: `{"job_id": "<uuid>"}` or `{"client_note_id": "<id>"}`. To confirm the transcript is saved: add `"ack": true`.

Replies `200`:
```json
{"job_id": "...", "client_note_id": "...", "audio_seconds": 61, "status": "transcribing", "provider_status": "processing"}
```
```json
{"job_id": "...", "client_note_id": "...", "audio_seconds": 61, "status": "done",
 "result": {
   "turns": [
     {"speaker": "1", "start_ms": 60, "end_ms": 6940, "text": "Okay, let's start. This is the weekly launch sync for Longnote.", "language": "en"},
     {"speaker": "2", "start_ms": 7200, "end_ms": 15880, "text": "The screenshots are done. ...", "language": "en"}
   ],
   "audio_duration_ms": 60288, "speakers": 2, "languages": ["en"]}}
```
```json
{"job_id": "...", "client_note_id": "...", "audio_seconds": 61, "status": "failed",
 "error": {"code": "upstream_failed", "message": "Transcription failed. Upload the audio again to retry."}}
```
```json
{"job_id": "...", "status": "uploaded", "error": {"code": "limit_reached", "message": "Not started yet. Call transcribe-start again."}}
```
```json
{"job_id": "...", "status": "fetched"}                      // after ack, or when the server copy is gone
```
- `provider_status` (`queued` | `processing` | `completed` | `error`) appears only on polls that asked Soniox.
- **Fetch once, then ack.** The first reply with `status: "done"` includes `result`; the job becomes `fetched`.
  Repeat calls return the result again until it is acked (in case the reply was lost or the app was suspended before it
  saved the turns). After the app has saved the turns, send `{"job_id": ..., "ack": true}` → `{"status": "fetched"}`; the
  server copy is deleted at once. Without an ack it is deleted 24 h after the first fetch (pg_cron, every 15 min). Once
  the server copy is gone (that, or 7 days with no fetch) the reply is `{"status": "fetched"}` without `result`.
- **Turns:** consecutive tokens of the same speaker are merged. A single speaker's turn is also split at a sentence end once it is
  ≥30 s long, and at any word boundary once it is ≥90 s long (so a lecture is not one giant turn). `speaker` is Soniox's label
  `"1"`, `"2"` ... (names are the app's job). `language` = the most common language in the turn (ISO code). No turns = silent audio.
- **Webhook fallback:** if Soniox's webhook does not arrive, a poll asks Soniox directly (at most every 20 s per job); once
  Soniox has reported "finished" for 2 minutes without a webhook, the poll fetches and finalises the transcript itself.
  Hourly cleanup also finalises jobs still `transcribing` 30 min after their start, and fails them 6 h after it. The clock
  is `started_at` (set by every successful start), not the row's creation, so a job started late (after a daily limit)
  is not killed early.

**Polling:** every **5 s** for the first minute, then every **15 s**; stop after 2 h (show "still processing, we'll keep trying"
and check when the app next opens). Soniox took 2-5 s for 23-60 s clips in the e2e test; a 60-min file took 61 s (measured 16 Nov, section 9).
On app start, poll every job that is `transcribing` or `done`.

### 4.3 `summarize`

Request:
```json
{"transcript": "Speaker 1: ...\nSpeaker 2: ...", "part": 1, "parts": 1,
 "style": "meeting", "custom_instructions": "Use bullet points under 12 words.", "output_language": "same",
 "client_note_id": "n_2026_11_16_0930"}
```
- `transcript`: text, ≤ **120,000 chars** per call (the app chunks at 100,000 and merges, as today).
- `style` (default `meeting`): `meeting`, `lecture`, `one_on_one`, `interview`, `client_call`, `brainstorm`, `sermon`,
  `doctor_visit`, `voice_memo_todos`.
- `custom_instructions` (optional): ≤ 1,000 chars, treated as the user's preferences (focus/format), never as rules; they cannot
  make the model add facts.
- `output_language`: `"same"` (main language of the transcript) or a language name such as `"English"`, `"Hindi"`, `"Spanish"`.
- `client_note_id` (optional): the note id; only used as part of the idempotency key below.

Reply `200`:
```json
{"summary": {
   "in_short": "The weekly launch sync covered the App Store listing, pricing and launch tasks. ...",
   "key_points": ["..."], "decisions": ["No weekly plan. Monthly and yearly only."],
   "action_items": [{"task": "Finish the App Store description and privacy answers.", "owner": "Priya", "due": "Thursday the 20th of November"},
                    {"task": "Set up the products in App Store Connect.", "owner": "Rahul", "due": null}],
   "numbers_and_dates": ["..."], "open_questions": ["..."]},
 "model": "gpt-5.4-mini", "style": "meeting", "cached": false}
```
Same keys as `MeetingSummary` in `lib/core/summary/summary_models.dart`, plus the new `in_short` (2-3 sentences).
`owner`/`due` are `null` unless said. For multi-part transcripts each part has its own `in_short`; the app should merge
(e.g. show part 1's, or join them). Counts 1 `summary_calls`. Before calling OpenAI it reserves an upper-bound cost
(12k output tokens + input at 2.5 chars/token: **~$0.06 for a 1-h part, ~$0.09 for a full 120k-char part**) against the
user's, the IP's and the global LLM caps in one atomic step, then settles to the real cost (~$0.02 per 1-h part). If OpenAI
refuses (HTTP error) the call and the money are given back; if the connection is lost or times out (110 s budget) the
reservation is kept (OpenAI may have billed). Errors: `bad_request`, `payload_too_large`, `limit_reached`, `upstream_failed`.

**Idempotent for 15 min:** the same user sending the same request again (same transcript part, style, part/parts,
custom instructions, output language, `client_note_id`) within `SUMMARY_CACHE_SECONDS` (900) gets the stored result with
`"cached": true`: no OpenAI call, no limit charge. So a re-send after a client timeout, or a retry of a long note whose
part 1 already succeeded, costs nothing. A re-send while the first call is still running waits for it (up to 100 s; after
that `upstream_failed` with `detail.in_progress: true, retry_after_seconds: 30`). The cached summary is kept server-side
only for that window (deleted by pg_cron 15-30 min after it was written).

### 4.4 `ask`

Request:
```json
{"transcript_turns": [{"speaker": "Priya", "start_ms": 7200, "text": "..."}, ...],
 "question": "Who sends the TestFlight build, and when?",
 "history": [{"role": "user", "content": "..."}, {"role": "assistant", "content": "..."}]}
```
- `transcript_turns`: the note's turns with the user's speaker names; `start_ms` must be an integer. ≤ 20,000 turns, body ≤ 2 MB.
- `question`: ≤ 1,000 chars. `history`: only the last 6 messages are used, each cut to 4,000 chars.

Reply `200`:
```json
{"answer": "Speaker 1 will send the TestFlight build on Monday.", "found": true,
 "sources": [{"speaker": "Speaker 1", "start_ms": 47370}], "truncated": false, "model": "gpt-5.4-mini"}
```
- Answers only from the transcript. If it is not there: `found: false`, `sources: []`, and an answer saying the recording does not cover it.
- `sources` are checked on the server: only `start_ms` values that exist in the sent turns survive (speaker is taken from that turn).
  Use them as tap-to-seek chips.
- **Size cap:** the transcript sent to the model is at most **240,000 chars** (~60k tokens, ~4.5 h of speech). Above that the
  server keeps the turns sharing the most words with the question (and recent user messages), plus each one's neighbours,
  in time order, with `[...]` at the gaps, and returns `truncated: true`. The app need not trim.
- Limits: **60 asks per user per UTC day** plus the user's/IP's daily LLM dollars (section 5). Reserves an upper-bound cost
  before the model call (**~$0.02 for a short note, up to ~$0.10** for a 240k-char transcript with full history), settled
  to the real cost after (~$0.01 first ask on a 1-h note, ~$0.002 with the prompt cache). Same refund/keep rule as summarize.

### 4.5 `report`

Crash / error reports from the app. Request: `{"kind": "flutter_error" | "uncaught" | "metrickit", "app": {...}, ...}`,
body ≤ 260 KB. Reply `200 {"ok": true, "stored": true}`; `"stored": false` for a duplicate (same body as an earlier report
of this user) or over a cap (`"reason": "user_day" | "ip_day"`): the app should drop it, not retry. Caps: 50 per user per
24 h and 200 per IP (/64) per UTC day, checked and inserted in one SQL step (`ln_report_insert`, safe under parallel calls).
Stored in `client_reports` (service role only), deleted after 30 days.

### 4.6 `appstore-notifications` (called by Apple, not the app)

App Store Server Notifications **V2**. URL (Production and Sandbox, set in App Store Connect through the API on 18 Nov):
`https://<ref>.supabase.co/functions/v1/appstore-notifications`. `verify_jwt` off: Apple sends no Supabase token; the
body is authenticated by Apple's signature instead.

Request (Apple): `{"signedPayload": "<JWS>"}`. Steps:
1. Verify the JWS (`_shared/appstore_jws.ts`): `alg` ES256; `x5c` = leaf, intermediate, root; root byte-equal to the
   embedded **Apple Root CA - G3** (SHA-256 `63:34:3A:...:91:79`); leaf signed by intermediate, intermediate by root, each
   valid at the payload's `signedDate`; intermediate is a CA with OID 1.2.840.113635.100.6.2.1, leaf has OID
   1.2.840.113635.100.6.11.1; signature checks with the leaf key. Same for `signedTransactionInfo` and
   `signedRenewalInfo`. No OCSP (as Apple's library with online checks off). Failure -> `400`.
2. `bundleId` must be `com.novaralabs.longnote` (`APPLE_BUNDLE_ID`), environment `Production` or `Sandbox`, and for
   Production `appAppleId` = `APPLE_APP_ID` (secret). Otherwise `200 {"ignored": ...}` so Apple stops retrying.
3. `ln_appstore_claim` stores the notification once per `notificationUUID` (a repeat -> `200 {"duplicate": true}`).
4. User = the subscription's linked user (`subscriptions.user_id`), else the transaction's `appAccountToken` (the app
   sets it to the Supabase user id). Plans the events (docs/ANALYTICS.md "Server events"), stores the plan and the new
   subscription state, replies **`200 {"ok": true}`**, then sends to Amplitude / Meta in the background
   (`EdgeRuntime.waitUntil`, 10 s timeout, one retry on 429/5xx/network, never more). Results go to
   `appstore_notifications.meta_result` / `amplitude_result`.
5. An error before the plan is stored -> `500` (Apple retries after 1, 12, 24, 48, 72 h; the claim lets a retry
   continue a run that died: `processing` older than 2 min is re-run, `planned` is re-sent from the stored plan).

Verified live 18 Nov: Apple's "Request a Test Notification" (sandbox) -> Apple `sendAttemptResult: SUCCESS`, row
`TEST / Sandbox / done`. The signed payload is the fixture in `_shared/testdata/` (a real Apple chain).

### 4.7 `tracking-profile`

What the server needs to send this user's subscription events, and whether it may. User JWT required. Body ≤ 24 KB.

```json
{"share_analytics": true, "att_enabled": false, "meta_anon_id": "XZ8F...-...", "app_version": "1.0.0",
 "os_version": "18.1", "device_model": "iPhone15,2", "locale": "en_IN",
 "extinfo": ["i2","com.novaralabs.longnote","1.0.0","112","18.1","iPhone15,2","en_IN","IST","","393","852","3.00","6","","","Asia/Kolkata"],
 "transaction_jws": "<StoreKit Transaction.jwsRepresentation, optional>"}
```
- `share_analytics: false` -> only that is stored; every other column is set to null; no events are sent for this user.
- Strings: short codes only (`[A-Za-z0-9_.,:+- ()]`, length caps); `extinfo` exactly 16 strings ≤ 64 chars; `currency`
  optional ISO code. Anything else -> `400 bad_request`.
- `transaction_jws`: verified like 4.6; if it is ours, its `originalTransactionId` is linked to this user in
  `subscriptions` (a reinstall keeps its renewals), or seeded from it if new. Not stored in the profile. A bad one is
  ignored (`"linked": false`).
- Reply `200 {"ok": true, "linked": bool}`. One row per user (upsert).
- The app sends it only when it changed (checked once per launch, and on the analytics switch, the ATT answer, the
  start of a purchase and entitlement changes); before the first sign-in it sends nothing, except right before a
  purchase.

### Tables (migration 00008)

| table | key | who can access | kept |
|---|---|---|---|
| `tracking_profiles` | `user_id` (→ auth.users, cascade) | RLS: a user may select / insert / update only their own row; service role all | while the user exists |
| `appstore_notifications` | `notification_uuid` | service role only | 13 months (pg_cron `longnote-appstore-notifications-ttl`) |
| `subscriptions` | `original_transaction_id` (`user_id` → auth.users, set null) | service role only | kept (no personal data once the user is gone) |

## 5. Limits (env-configurable function secrets)

| secret | default | what |
|---|---|---|
| `LIMIT_AUDIO_SECONDS_PER_DAY` | 28800 (8 h) | audio per user per UTC day (= $0.80 at $0.10/h) |
| `LIMIT_AUDIO_SECONDS_PER_HOUR` | 14400 (4 h) | audio per user per rolling hour |
| `LIMIT_MAX_AUDIO_SECONDS` | 18000 (5 h) | one file (Soniox's fixed maximum is 300 min) |
| `LIMIT_USER_LLM_USD_PER_DAY` | 1.00 | summarize + ask spend per user per UTC day (reserved, then settled) |
| `LIMIT_ASK_PER_DAY` | 60 | ask calls per user per day (second guard) |
| `LIMIT_SUMMARY_PER_DAY` | 40 | summarize calls per user per day (a 3-h note uses 2 parts; cached re-sends are free) |
| `LIMIT_IP_AUDIO_SECONDS_PER_DAY` | 86400 (24 h) | audio per client IP per UTC day (scope `ip_day`) |
| `LIMIT_IP_LLM_USD_PER_DAY` | 2.00 | summarize + ask spend per client IP per day |
| `LIMIT_IP_SUMMARY_PER_DAY` | 300 | summarize calls per client IP per day (second guard) |
| `LIMIT_IP_ASK_PER_DAY` | 600 | ask calls per client IP per day (second guard) |
| `LIMIT_GLOBAL_AUDIO_USD_PER_DAY` | 12 | global **audio** pool (Soniox) per UTC day (~120 h) |
| `LIMIT_GLOBAL_LLM_USD_PER_DAY` | 8 | global **LLM** pool (OpenAI) per UTC day |
| `LIMIT_GLOBAL_USD_PER_DAY` | 20 | total of both pools per UTC day (outer ceiling) |
| `LIMIT_REPORTS_PER_USER_DAY` / `LIMIT_REPORTS_PER_IP_DAY` | 50 / 200 | `report` calls |

Scopes the app sees: per-user caps → `user_day` / `user_hour`; per-IP caps → `ip_day`; pools / total → `global_day`.

Everything is **reserve-then-settle in one SQL transaction**: audio (`ln_reserve_audio_v2`) and summarize/ask
(`ln_reserve_llm`) check every cap that applies and charge all of them only if all pass (a refused call charges nothing,
not even the IP count), using conditional UPDATEs under row locks, so parallel calls cannot overshoot. After the call the
charge moves to the real cost everywhere (`ln_settle_audio`, `ln_settle_llm`). The two global pools are separate, so a burst
of Ask traffic cannot stop transcription for everyone, and vice versa (`cost_daily.audio_usd` / `llm_usd`; `est_usd` = total).
The IP is stored only as HMAC-SHA256 with a server secret (`IP_HASH_SECRET`, else `CLEANUP_SECRET`) of the IPv4 address or
the **IPv6 /64** (a phone usually owns a whole /64, so the exact address would be trivial to rotate); rows kept 2 days.

What one abuser can still do (all numbers at defaults): one IP (/64) spends at most $2.40 audio + $2 LLM per day; it takes
~5 distinct IPs/prefixes to fill a pool and switch that product off until 00:00 UTC. **Open:** App Attest (or a captcha on
anonymous sign-up) before any public build (DECISIONS.md), and an alert when `global_day` trips. Per-IP caps stay generous
because Indian carriers share one IPv4 across many phones (CGNAT).

Test overrides (e2e only): rows in `ln_test_overrides` (service role) can **lower** a cap until `expires_at`: keys
`global_audio_usd_cap`, `global_llm_usd_cap`, `global_usd_cap`, `user_llm_usd_cap:<user id>`, `ip_llm_usd_cap:<ip hash>`,
`report_user:<user id>`, `report_ip:<ip hash>`. Expired rows are deleted every 15 min.

Other knobs: `OPENAI_MODEL` (default `gpt-5.4-mini`), `SONIOX_MODEL` (`stt-async-v6`), `SIGNED_URL_SECONDS` (10800),
`WEBHOOK_GRACE_SECONDS` (120), `SONIOX_CHECK_EVERY_SECONDS` (20), `ASK_MAX_TRANSCRIPT_CHARS` (240000),
`SUMMARY_CACHE_SECONDS` (900), `SUMMARY_WAIT_SECONDS` (100), `OPENAI_TIMEOUT_MS` (110000, whole call incl. retries),
`SONIOX_TIMEOUT_MS` (30000; transcript download `SONIOX_TRANSCRIPT_TIMEOUT_MS` 60000), `CLEANUP_BUDGET_MS` (45000), prices
(`SONIOX_USD_PER_HOUR` 0.10, `OPENAI_USD_PER_M_INPUT` 0.75, `..._CACHED_INPUT` 0.075, `..._OUTPUT` 4.5),
`SONIOX_WEBHOOKS=off` (ops switch: no webhooks, polls finalise at once).
Usage is readable by the app: `select * from usage_daily where day = <today UTC>` (RLS: own row only).

## 6. What is deleted when

| data | where | deleted |
|---|---|---|
| audio file | our bucket `uploads` | as soon as the job is `done` or `failed`; any object older than **24 h** is removed by the hourly cleanup (it loops until none are left, within a 45 s budget per run) |
| audio + transcript | Soniox | transcription deleted right after we fetch it (or on error); leftovers retried hourly; transcriptions no job points to (lost start reply) deleted by the webhook or the hourly cleanup. Soniox auto-deletes after 30 days anyway |
| transcript (`jobs.result`) | our DB | on `ack`; else 24 h after first fetch; else 7 days after the job finished (never fetched) |
| job row (no content: status, lengths, error) | our DB | 30 days after its last start (else creation) |
| `usage_daily` | our DB | after 90 days |
| `ip_daily` (hashed IP, counts, dollars) | our DB | after 2 days |
| summary (idempotency cache, `summary_cache`) | our DB | 15-30 min after it was written |
| crash reports (`client_reports`) | our DB | after 30 days |
| App Store notifications (`appstore_notifications`: decoded payload, transaction, what we sent) | our DB | after 13 months |
| tracking profile (`tracking_profiles`) | our DB | with the anonymous user (cascade) |
| subscription state (`subscriptions`) | our DB | kept; `user_id` set to null when the user is deleted |
| anonymous user (`auth.users`) with no session activity for 90 days | Supabase Auth | deleted by `ln_cleanup_db` (≤500 per run); its jobs/usage go with it. The app signs up again (section 1) |
| Ask answers | nowhere | never stored; OpenAI API data is not used for training (OpenAI API policy; their abuse-monitoring retention applies) |

Schedules (pg_cron): `longnote-cleanup-db` every 15 min (SQL), `longnote-cleanup-storage` at :07 every hour (calls the `cleanup`
function through pg_net; the storage API is the only way to delete objects).
Error policy: Soniox refuses to start → the app may retry; after the 3rd refusal the job fails and the audio is deleted.
Soniox reports an error → the job fails at once, audio deleted at Soniox and here, minutes refunded. In both cases the phone
still has the audio; re-upload and call `transcribe-start` with the same `client_note_id`.

## 7. Maximum recording length

- **Binding cap: 5 hours (300 min) per file**, Soniox's fixed async limit. `transcribe-start` returns `too_long` above that.
- File cap 100 MB = ~7 h at 32 kbps, so it never binds for our format (a 3-h note ≈ 43 MB; 5 h ≈ 72 MB).
- Daily cap 8 h per user.
- **Recordings over 5 h:** the app must split the audio into ≤ 5 h files (suggest 4 h pieces) with ids like
  `<note>_p1`, `<note>_p2`, transcribe each, and add the offset to `start_ms` when joining.

## 8. Cost per audio hour (estimates, list prices 16 Nov 2026)

| item | cost |
|---|---|
| Soniox async `stt-async-v6`, diarization + language ID included | **$0.10 / hour** |
| Summary of 1 h (~10k words ≈ 13k tokens in, ~1.5k out, gpt-5.4-mini at $0.75 / $4.50 per M) | ~$0.017 |
| One Ask on a 1-h note (~13k tokens in, ~150 out; repeat asks hit the prompt cache at $0.075/M) | ~$0.010 first, ~$0.002 after |
| Supabase storage / egress (≤24 h of a 14 MB file) | ~$0 |
| **Total for 1 h recorded + summary + 5 asks** | **≈ $0.13** |

A 3-hour note with summary ≈ $0.35. One e2e run below (83 s of audio, 1 summary, 2 asks) cost about $0.005.

Reservations are larger than these real costs (they assume the full output budget and 2.5 chars per token): summarize
~$0.06 per 1-h part (~$0.09 for a full 120k-char part), ask ~$0.02 on a short note up to ~$0.10 on a 4.5-h note with full
history. They are settled to the real cost after each call, so they only matter for parallel calls near a cap.

## 9. End-to-end test results (16 Nov 2026)

Script: `python3 tools/e2e/make_audio.py /tmp/longnote-e2e && python3 tools/e2e/e2e.py /tmp/longnote-e2e`
(OpenAI TTS `gpt-4o-mini-tts`, voices alloy/onyx and nova/echo; ffmpeg → AAC-LC m4a mono 16 kHz 32 kbps).

| check | result |
|---|---|
| anonymous sign-in; upload into another user's folder | OK; 403 |
| start without upload / wrong path / 6 h audio / unknown style | `not_found` / `bad_request` / `too_long` / `bad_request` |
| meeting: 60.2 s, 245,682 bytes, **TUS** upload | 1.8 s upload; start 1.7 s; **done 2.5-4.6 s** after start; 8 turns, **2 speakers**, en; webhook arrived |
| Hinglish: 22.9 s, 92,572 bytes, standard upload, `auto` + hints hi,en | done 4-5 s; 3 turns, **2 speakers**, language `hi` |
| idempotent start (same job_id) | OK (both clips) |
| audio gone from storage; Soniox transcription GET → 404; ack clears result | OK (both clips) |
| webhook switched off (`SONIOX_WEBHOOKS=off`): status-poll fallback | done in 5 s, `webhook_received_at` empty: fallback works |
| summarize (meeting) | 3.6-4.3 s. in_short: "The weekly launch sync for Long Note covered the App Store listing, pricing, and launch tasks. The group agreed to keep only monthly and yearly plans, and they also decided to defer the Android question until after the first month of sales data." Action items: Priya / "Thursday the 20th of November"; Rahul / null; Speaker 1 / Monday |
| ask "Who sends the TestFlight build, and when?" | 2.0 s: "Speaker 1 will send the TestFlight build on Monday." source start_ms 47370 (a real turn) |
| ask "What is the marketing budget for Germany?" | found=false: "The recording does not cover the marketing budget for Germany." |
| cost (3 runs incl. fallback test) | `cost_daily` $0.0131 total |

Sample Hinglish output (note: Soniox writes the Hindi parts **in Devanagari**, including English loan words):
```
[0.1s]  S1 (hi): Hello, Arjun. कल की मीटिंग के बारे में बात करनी थी। क्लाइंट ने बजट 50,000 रुपीज़ कन्फर्म कर दिया है।
[10.1s] S2 (hi): अच्छा, ग्रेट। तो हम डिज़ाइन का काम मंडे से स्टार्ट कर देते हैं। मैं टीम को आज शाम तक बता दूँगा।
[18.3s] S1 (hi): Perfect. और इनवॉइस फ्राइडे तक भेज देना, प्लीज़।
```

### Re-run after the review fixes (16 Nov, later)

- `tools/e2e/e2e.py`: all checks pass again (meeting TUS 2 speakers en; Hinglish 2 speakers hi; idempotent start; deletions;
  summarize; ask found/not found). `--webhook-off` (secret `SONIOX_WEBHOOKS=off`, unset after): done in 27 s by the
  status-poll fallback, no webhook.
- `tools/e2e/race_cap.py`: 5 parallel `transcribe-start` for one note → one `job_id` (1 reply `transcribing`, 4 `uploaded`),
  **one Soniox transcription**, `tries` 1. Global cap (test override = today's spend + room for one call): 5 parallel
  `summarize` → 1 ok, 4 `global_day`, spend stayed under the cap and settled to the real cost (+$0.0009); same for `ask`
  (+$0.0004).
- Client-sent `X-Forwarded-For` / `X-Real-IP` do not change the IP the functions see (one `ip_daily` row).

### Re-run after the review-B fixes (16 Nov, evening; migration 00007)

- `tools/e2e/e2e.py`: all checks pass (meeting TUS 2 speakers; Hinglish; idempotent start; deletions; summarize 5.6 s; ask
  found / not found).
- `tools/e2e/race_cap.py`: 5 parallel starts → one job, one Soniox transcription, `tries` 1; LLM pool (override) 5
  parallel summarize → 1 ok + 4 `global_day`, settled +$0.0013; ask → 1 + 4, +$0.0005.
- `tools/e2e/review_b.py` (new), all pass: summarize re-send → `cached: true`, charged once (`summary_calls` +1, pool
  +$0.0013, re-send +$0); 3 parallel identical → one computed, two cached; per-user LLM dollars → `user_day`; per-IP LLM
  dollars → `ip_day` and the refused call charged the user nothing; audio pool full → `transcribe-start` `global_day`
  while summarize still works; lost Soniox reply → the next start adopts the existing transcription (one at Soniox),
  job done, user + IP charge settled 60 s → 23 s; orphan transcription → webhook deletes it (Soniox 404); report duplicate
  → `stored: false`, 6 parallel with room for 2 → exactly 2 stored, IP cap → `ip_day`; 26th object refused (400);
  105 MB TUS upload refused at creation (413).
- `deno test --allow-env supabase/functions/_shared/ip_bucket_test.ts`: IPv6 /64 bucketing, 5 tests pass.
- `cleanup` called by hand: 200 in 1.2 s.

### Long audio: 60 min, two speakers (`tools/e2e/long_audio.py`)

149 s of unique two-voice TTS dialogue looped to 60 min with gaps, AAC-LC mono 16 kHz 32 kbps:

| measure | result |
|---|---|
| file | 3,600 s, **14,379,993 bytes** (32.0 kbps) |
| TUS upload (3 × 6 MB chunks, from this server) | 4.1 s |
| transcribe-start | 3.5 s |
| **Soniox: start → done** | **61 s** (webhook arrived) |
| result | 386 turns, **2 speakers**, en, `audio_duration_ms` 3,600,000, longest turn 11 s |
| summarize (51,408 chars, 1 part) | 6.8 s; decisions correct (offer 80 Rs with 3-year lock-in; extend the trial) |
| ask "What rent did we decide to offer?" | 3.9 s, found, 1 source, not truncated |
| deletion | audio gone from storage, Soniox transcription 404, result cleared on ack |
| cost (`cost_daily` delta) | **$0.1245** (Soniox $0.10 + summary + ask) |

Projected for 3 h: ~43 MB (8 TUS chunks; upload time depends on the phone's uplink: ~1-3 min on 4G), Soniox ~3 min if it
scales linearly (not measured), transcript ~155k chars → 2 summary parts, cost ≈ $0.35. Over 5 h the app splits into 4-h pieces.

Not tested yet: a 3-hour real recording (speed, turn quality), noisy rooms, Indian-English accents,
the hourly 24 h storage sweep on a real stale object (the delete call it uses is the same one the e2e verified).

## 10. Operations

- Deploy functions: `SUPABASE_ACCESS_TOKEN=... supabase functions deploy --use-api --project-ref <ref>` (verify_jwt per function in `supabase/config.toml`: off only for `soniox-webhook` and `cleanup`, which check their own secret headers, and `appstore-notifications`, which checks Apple's signature).
- Deno tests: `deno test --allow-env --allow-read supabase/functions/_shared/` (36: IP buckets, Apple JWS incl. a real
  Apple-signed fixture, notification mapping, tracking profile).
- Migration 00008 (`subscription_events`: tracking_profiles, appstore_notifications, subscriptions,
  `ln_appstore_claim`, TTL cron) applied with psql on 18 Nov and recorded; dry-run twice in a rolled-back
  transaction first (re-runnable); RLS checked (own row only; another user's row refused; service tables denied).
- Migrations: `supabase/migrations/*.sql` (00001-00007) were applied with psql and recorded in
  `supabase_migrations.schema_migrations` (00006 `client_reports` was applied earlier and recorded on 16 Nov with 00007).
  All seven are re-runnable in order (`if not exists` / `drop ... if exists` / `create or replace`; checked by running
  00001-00007 against the live DB inside a rolled-back transaction).
  - 00001 schema, 00002 storage bucket + policies, 00003 pg_cron cleanup, 00004 finalize claim, 00005 reserve/claim/IP caps,
    00006 `client_reports` (+ 30-day TTL cron), 00007 review-B fixes (cost pools, dollar caps, `started_at`, IP settle,
    report RPC, summary cache, 100 MB / 25-object upload guard, cleanup changes, `jobs.audio_path` index).
  - Old functions kept for compatibility but no longer called: `ln_reserve_audio`, `ln_reserve_call`, `ln_settle_cost`,
    `ln_ip_reserve`, `ln_ip_release` (service role only).
- Server secrets (names only): `OPENAI_API_KEY`, `SONIOX_API_KEY`, `SONIOX_WEBHOOK_SECRET`, `CLEANUP_SECRET`, `LIMIT_*`
  (set now: `LIMIT_ASK_PER_DAY`, `LIMIT_AUDIO_SECONDS_PER_DAY`, `LIMIT_AUDIO_SECONDS_PER_HOUR`, `LIMIT_GLOBAL_USD_PER_DAY`,
  `LIMIT_SUMMARY_PER_DAY`; the new pool / dollar caps run on their defaults).
  Subscription events (18 Nov): `AMPLITUDE_API_KEY`, `APPLE_APP_ID`, `META_APP_ID`, `META_DATASET_ID`,
  `META_CAPI_TOKEN`; optional `META_TEST_EVENT_CODE` (sandbox -> Meta Test Events), `META_GRAPH_VERSION` (default
  v24.0), `META_APP_SECRET` (App Events API fallback; not set), `APPLE_BUNDLE_ID`.
  The two generated secrets are also in `.env.local`. Vault (for pg_cron): `project_url`, `cleanup_secret`.
- Soniox account limits to watch: 100 pending and 2,000 stored transcriptions (we delete each one), 10 GB / 1,000 files (we use URLs, not files).
