#!/usr/bin/env python3
"""Long-audio test on the real server (~60 min, two speakers).

  python3 tools/e2e/long_audio.py /tmp/longnote-long [minutes]   (default 60)

Makes ~3.5 min of unique two-voice dialogue with OpenAI TTS (cost ~$0.05),
loops it with short gaps to the target length, encodes like the app
(AAC-LC m4a, mono, 16 kHz, 32 kbps), then: TUS upload -> transcribe-start ->
poll -> summarize (100k-char parts, like the app) -> ask -> ack. Records wall
times, size, speakers, cost and that the audio is gone. Reads .env.local;
never prints secrets. Soniox cost ~$0.10 per hour.
"""
import datetime as dt
import json
import os
import subprocess
import sys
import tempfile
import time

import requests

sys.path.insert(0, os.path.dirname(__file__))
from e2e import E, URL, call, check, fails, job_row, object_exists, sign_in, soniox_gone, tus_upload  # noqa: E402
from make_audio import tts  # noqa: E402

DIALOGUE = [
    ("alloy", "Thanks for joining. This is the quarterly planning review for the Nagpur warehouse project. We have three topics: the lease, hiring, and the delivery software."),
    ("onyx", "On the lease, the landlord came back yesterday. He wants eighty-five rupees per square foot per month, and a three year lock in. Our budget was seventy-five."),
    ("alloy", "That's a big gap. What did he say about the loading dock repairs? Last time he promised to fix both docks before we move in."),
    ("onyx", "He agreed to fix the docks, but only if we sign by the thirtieth of this month. I think we can push him to eighty if we accept the three year lock in."),
    ("alloy", "Okay. Let's make that the decision: offer eighty rupees with a three year lock in, docks fixed before move in. Meera will send the offer letter by Friday."),
    ("onyx", "Good. Next, hiring. We need twelve pickers and two shift supervisors before the Diwali rush. So far we have hired five pickers and no supervisors."),
    ("alloy", "Why is the supervisor role so slow? We posted it three weeks ago."),
    ("onyx", "The salary band is too low. Similar warehouses in Butibori pay thirty-two thousand a month for supervisors. We offer twenty-six thousand."),
    ("alloy", "Then we raise it to thirty thousand and add a night shift allowance. I don't want to lose the Diwali season over six thousand rupees."),
    ("onyx", "Agreed. I'll update the job post today and ask Rakesh from the agency to send candidates by Wednesday."),
    ("alloy", "Last topic, the delivery software. The trial of RouteKart ends next Tuesday. What did the drivers think?"),
    ("onyx", "Mixed. The route planning is good and saved about forty minutes per driver per day. But the app crashes on older Android phones, and half our drivers use those."),
    ("alloy", "Can RouteKart fix the crashes before we pay? If not, we should look at the other vendor, ShipSaathi."),
    ("onyx", "They promised a fix in two weeks. I suggest we extend the trial by two weeks instead of paying now. The price is forty-five thousand a year either way."),
    ("alloy", "Fine. Extend the trial, no payment until the crash is fixed. One open question: who owns the driver training if we switch vendors?"),
    ("onyx", "Let's leave that open until we know the vendor. Thanks everyone, we meet again on the fifth."),
]


def build(key, out_dir, minutes):
    unique = os.path.join(out_dir, "unique.wav")
    with tempfile.TemporaryDirectory() as td:
        parts = []
        for i, (voice, text) in enumerate(DIALOGUE):
            p = os.path.join(td, f"{i:02d}.wav")
            tts(key, voice, text, p)
            parts.append(p)
        inputs, filt = [], []
        for i, p in enumerate(parts):
            inputs += ["-i", p]
            filt.append(f"[{i}:a]aresample=16000,aformat=channel_layouts=mono,apad=pad_dur=0.7[a{i}]")
        concat = "".join(f"[a{i}]" for i in range(len(parts))) + f"concat=n={len(parts)}:v=0:a=1,apad=pad_dur=2[out]"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", ";".join(filt + [concat]),
                        "-map", "[out]", "-ar", "16000", "-ac", "1", unique], check=True)
    unique_s = duration(unique)
    out = os.path.join(out_dir, f"long_{minutes}min.m4a")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-stream_loop", "-1", "-i", unique, "-t", str(minutes * 60),
                    "-c:a", "aac", "-profile:a", "aac_low", "-b:a", "32k", "-ar", "16000", "-ac", "1",
                    "-movflags", "+faststart", out], check=True)
    return out, unique_s


def duration(path):
    return float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                                capture_output=True, text=True).stdout)


def cost_today():
    sr = E["SUPABASE_SERVICE_ROLE_KEY"]
    day = dt.datetime.now(dt.timezone.utc).date().isoformat()
    r = requests.get(f"{URL}/rest/v1/cost_daily?day=eq.{day}&select=est_usd",
                     headers={"apikey": sr, "Authorization": f"Bearer {sr}"}, timeout=30).json()
    return float(r[0]["est_usd"]) if r else 0.0


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/longnote-long"
    minutes = int(sys.argv[2]) if len(sys.argv) > 2 else 60
    os.makedirs(out_dir, exist_ok=True)
    audio = os.path.join(out_dir, f"long_{minutes}min.m4a")
    if not os.path.exists(audio):
        audio, unique_s = build(E["OPENAI_API_KEY"], out_dir, minutes)
        print(f"unique dialogue {unique_s:.0f} s, looped to {minutes} min")
    data = open(audio, "rb").read()
    secs = duration(audio)
    print(f"{audio}: {len(data):,} bytes, {secs:.1f} s ({len(data) * 8 / secs / 1000:.1f} kbps)")
    res = {"audio_s": round(secs, 1), "bytes": len(data)}
    cost0 = cost_today()

    token, uid = sign_in()
    note = f"e2e-long-{int(time.time())}"
    path = f"{uid}/{note}.m4a"
    t0 = time.time()
    code = tus_upload(token, path, data)
    res["upload_s"] = round(time.time() - t0, 1)
    check(code == 204, f"TUS upload -> {code} in {res['upload_s']} s")

    body = {"client_note_id": note, "audio_path": path, "audio_seconds": round(secs, 1), "language": "en"}
    c, d, dt_start = call(token, "transcribe-start", body)
    check(c == 200 and d.get("status") == "transcribing", f"transcribe-start -> {c} {d} ({dt_start:.1f}s)")
    job = d["job_id"]
    t1 = time.time()
    polls = 0
    while True:
        polls += 1
        c, d, _ = call(token, "transcribe-status", {"job_id": job})
        if d.get("status") in ("done", "failed") or time.time() - t1 > 3600:
            break
        time.sleep(15 if time.time() - t1 > 60 else 5)
    res["transcribe_s"] = round(time.time() - t1, 1)
    check(d.get("status") == "done", f"done after {res['transcribe_s']} s ({polls} polls)")
    result = d.get("result") or {}
    turns = result.get("turns", [])
    row = job_row(job)
    res.update({"turns": len(turns), "speakers": result.get("speakers"), "languages": result.get("languages"),
                "audio_duration_ms": result.get("audio_duration_ms"), "webhook_arrived": bool(row["webhook_received_at"]),
                "longest_turn_s": round(max((t["end_ms"] - t["start_ms"] for t in turns), default=0) / 1000, 1)})
    check((result.get("speakers") or 0) >= 2, f"speakers: {result.get('speakers')}")
    check(not object_exists(token, path), "audio deleted from storage")
    check(row["audio_deleted"] and row["soniox_deleted"] and soniox_gone(row["soniox_transcription_id"]),
          "audio + Soniox transcription deleted")

    # Summary, chunked at 100k chars like the app.
    lines = [f"Speaker {t['speaker']}: {t['text']}" for t in turns]
    chunks, cur = [], ""
    for ln in lines:
        if len(cur) + len(ln) + 1 > 100_000 and cur:
            chunks.append(cur)
            cur = ""
        cur += ln + "\n"
    if cur:
        chunks.append(cur)
    res["transcript_chars"] = sum(len(x) for x in chunks)
    t2 = time.time()
    sums = []
    for i, ch in enumerate(chunks):
        c, d, _ = call(token, "summarize", {"transcript": ch, "part": i + 1, "parts": len(chunks), "style": "meeting"})
        check(c == 200, f"summarize part {i + 1}/{len(chunks)} -> {c}")
        sums.append(d.get("summary", {}))
    res["summary_s"] = round(time.time() - t2, 1)
    res["summary_parts"] = len(chunks)
    res["in_short"] = sums[0].get("in_short") if sums else None
    res["decisions"] = sums[0].get("decisions") if sums else None

    ask_turns = [{"speaker": f"Speaker {t['speaker']}", "start_ms": t["start_ms"], "text": t["text"]} for t in turns]
    c, d, dt_ask = call(token, "ask", {"transcript_turns": ask_turns, "question": "What rent did we decide to offer for the lease?"})
    check(c == 200 and d.get("found"), f"ask -> {c} in {dt_ask:.1f}s")
    res["ask"] = {"s": round(dt_ask, 1), "answer": d.get("answer"), "sources": len(d.get("sources", [])),
                  "truncated": d.get("truncated")}
    call(token, "transcribe-status", {"job_id": job, "ack": True})
    time.sleep(1)
    res["cost_usd_delta"] = round(cost_today() - cost0, 4)
    print(json.dumps(res, indent=1, ensure_ascii=False))
    print("FAILED:" if fails else "ALL PASSED", *fails, sep="\n  ")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
