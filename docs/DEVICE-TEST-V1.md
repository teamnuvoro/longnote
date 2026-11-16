# Longnote v1 — what to test on your iPhone (TestFlight)

Open TestFlight → Longnote → Install. Billing is simulated (no real charge).

## 1. First run (2 min)
- Onboarding → paywall → Start free trial → "Allow the reminder" → empty Notes screen.
- Check the paywall dates and prices make sense.

## 2. A short meeting (5 min)
- Tap Record. Talk with one other person for 2–3 minutes (or play a podcast with 2 voices).
- Tap Mark moment once. Pause, then Resume. Stop & save.
- Watch the note go: compressing → uploading → transcribing → summary. Expect under 1 minute.
- Open it: Summary (decisions, action items), Transcript (2 speakers, colours). Edit names. Tap a line → audio jumps there.
- Ask tab: "What did we decide?" → tap a source chip → it opens the transcript at that moment.
- Share: PDF, summary, transcript, audio — each opens the iOS share sheet.

## 3. Reliability (most important)
- **Lock screen:** start recording, lock the phone for 10 minutes, unlock. The timer and audio should be continuous.
- **Phone call:** during a recording, get a call (ask someone to ring you). Expect the amber "Paused for a phone call" banner, then it resumes by itself; the transcript shows the gap.
- **Force-quit:** record 2 minutes, swipe the app away, reopen. Expect "Interrupted — saved 2 min" and the note processes.
- **No internet:** turn on Airplane mode, record 1 minute, stop. The note waits in "Waiting & needs attention". Turn Airplane mode off → it uploads by itself.
- **Long one:** record a real 1–3 hour lecture/meeting with the screen locked. Note the battery used and how long processing takes.

## 4. Other screens
- Import: Files → pick an audio file → name it → Import and transcribe.
- Settings: audio language (try Hindi or Hinglish), summary style, "What happens to your audio", Plan & billing.
- Search on Notes for a word that was said.

## Tell me
Anything that felt slow, jumpy, confusing or wrong — a screenshot + one line is perfect.
