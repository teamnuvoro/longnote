#!/usr/bin/env python3
"""End-to-end test of the Longnote backend against the real Supabase project.

  python3 tools/e2e/make_audio.py /tmp/longnote-e2e   # once
  python3 tools/e2e/e2e.py /tmp/longnote-e2e
  python3 tools/e2e/e2e.py /tmp/longnote-e2e --webhook-off   # after
      `supabase secrets set SONIOX_WEBHOOKS=off`; meeting only, checks the
      status-poll fallback finalised it (unset the secret afterwards)

Signs in anonymously (like the app), uploads with TUS (meeting) and with the
standard upload (Hinglish), runs transcribe-start / transcribe-status /
summarize / ask, and checks that the audio is gone from storage and the
transcription is gone at Soniox. Reads .env.local; never prints secrets.
The service-role key is used ONLY for checks the app cannot do (job row).
"""
import base64
import json
import os
import sys
import time

import requests

sys.path.insert(0, os.path.dirname(__file__))
from envfile import load_env  # noqa: E402

E = load_env()
URL = E["SUPABASE_URL"].rstrip("/")
REF = URL.split("//")[1].split(".")[0]
ANON = E["SUPABASE_ANON_KEY"]
FN = f"{URL}/functions/v1"
TUS = f"https://{REF}.storage.supabase.co/storage/v1/upload/resumable"
CHUNK = 6 * 1024 * 1024  # Supabase TUS requires exactly 6 MB chunks

results = {}
fails = []


def check(cond, what):
    print(("  PASS " if cond else "  FAIL ") + what)
    if not cond:
        fails.append(what)


def sign_in():
    r = requests.post(f"{URL}/auth/v1/signup", headers={"apikey": ANON, "Content-Type": "application/json"},
                      json={}, timeout=30)
    r.raise_for_status()
    d = r.json()
    return d["access_token"], d["user"]["id"]


def call(token, fn, body):
    t = time.time()
    r = requests.post(f"{FN}/{fn}", headers={"Authorization": f"Bearer {token}", "apikey": ANON},
                      json=body, timeout=180)
    try:
        data = r.json()
    except Exception:
        data = {"raw": r.text[:200]}
    return r.status_code, data, time.time() - t


def b64(s):
    return base64.b64encode(s.encode()).decode()


def tus_upload(token, path, data):
    h = {"Authorization": f"Bearer {token}", "apikey": ANON, "Tus-Resumable": "1.0.0", "x-upsert": "true"}
    meta = f"bucketName {b64('uploads')},objectName {b64(path)},contentType {b64('audio/mp4')},cacheControl {b64('3600')}"
    r = requests.post(TUS, headers={**h, "Upload-Length": str(len(data)), "Upload-Metadata": meta}, timeout=60)
    if r.status_code != 201:
        return r.status_code
    loc = r.headers["Location"]
    off = 0
    while off < len(data):
        chunk = data[off:off + CHUNK]
        r = requests.patch(loc, headers={**h, "Upload-Offset": str(off), "Content-Type": "application/offset+octet-stream"},
                           data=chunk, timeout=300)
        if r.status_code != 204:
            return r.status_code
        off = int(r.headers["Upload-Offset"])
    # HEAD reports the final offset (what the app uses to resume).
    r = requests.head(loc, headers=h, timeout=30)
    return 204 if r.headers.get("Upload-Offset") == str(len(data)) else r.status_code


def std_upload(token, path, data):
    r = requests.post(f"{URL}/storage/v1/object/uploads/{path}",
                      headers={"Authorization": f"Bearer {token}", "apikey": ANON, "Content-Type": "audio/mp4",
                               "x-upsert": "true"}, data=data, timeout=120)
    return r.status_code


def object_exists(token, path):
    r = requests.get(f"{URL}/storage/v1/object/info/authenticated/uploads/{path}",
                     headers={"Authorization": f"Bearer {token}", "apikey": ANON}, timeout=30)
    return r.status_code == 200


def job_row(job_id):
    sr = E["SUPABASE_SERVICE_ROLE_KEY"]
    r = requests.get(f"{URL}/rest/v1/jobs?id=eq.{job_id}&select=status,soniox_transcription_id,soniox_deleted,"
                     "audio_deleted,webhook_received_at,audio_duration_ms,result",
                     headers={"apikey": sr, "Authorization": f"Bearer {sr}"}, timeout=30)
    return r.json()[0]


def soniox_gone(tid):
    r = requests.get(f"https://api.soniox.com/v1/transcriptions/{tid}",
                     headers={"Authorization": f"Bearer {E['SONIOX_API_KEY']}"}, timeout=30)
    return r.status_code == 404


def run_transcription(token, uid, note_id, audio_file, language, upload, hints=None):
    data = open(audio_file, "rb").read()
    path = f"{uid}/{note_id}.m4a"
    import subprocess
    secs = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0",
                                 audio_file], capture_output=True, text=True).stdout)
    t0 = time.time()
    code = upload(token, path, data)
    t_up = time.time() - t0
    check(code in (200, 201, 204), f"{upload.__name__} {len(data)} bytes -> HTTP {code} in {t_up:.1f}s")

    body = {"client_note_id": note_id, "audio_path": path, "audio_seconds": round(secs, 1), "language": language}
    if hints:
        body["language_hints"] = hints
    c, d, dt = call(token, "transcribe-start", body)
    check(c == 200 and d.get("status") == "transcribing", f"transcribe-start -> {c} {d} ({dt:.1f}s)")
    job = d.get("job_id")
    c2, d2, _ = call(token, "transcribe-start", body)
    check(c2 == 200 and d2.get("job_id") == job, "transcribe-start is idempotent (same job_id)")

    t1 = time.time()
    polls = 0
    while True:
        polls += 1
        c, d, _ = call(token, "transcribe-status", {"job_id": job})
        if d.get("status") in ("done", "failed") or time.time() - t1 > 600:
            break
        time.sleep(3)
    t_tx = time.time() - t1
    check(d.get("status") == "done", f"status done after {t_tx:.1f}s ({polls} polls)")
    res = d.get("result") or {}
    turns = res.get("turns", [])
    row = job_row(job)
    out = {"audio_s": round(secs, 1), "bytes": len(data), "upload_s": round(t_up, 1), "transcribe_s": round(t_tx, 1),
           "turns": len(turns), "speakers": res.get("speakers"), "languages": res.get("languages"),
           "webhook_arrived": bool(row["webhook_received_at"]), "audio_duration_ms": row["audio_duration_ms"]}
    for t in turns[:4]:
        print(f"    [{t['start_ms']/1000:6.1f}s] S{t['speaker']} ({t.get('language')}): {t['text'][:110]}")

    # Deleted everywhere?
    time.sleep(1)
    check(not object_exists(token, path), "audio object deleted from storage")
    check(row["audio_deleted"] and row["soniox_deleted"], "job row: audio_deleted and soniox_deleted")
    check(soniox_gone(row["soniox_transcription_id"]), "Soniox transcription deleted (GET -> 404)")
    # Ack clears the server copy.
    c, d, _ = call(token, "transcribe-status", {"job_id": job, "ack": True})
    row = job_row(job)
    check(d.get("status") == "fetched" and row["result"] is None, "ack -> fetched, result cleared on server")
    return job, turns, out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    audio_dir = args[0] if args else "/tmp/longnote-e2e"
    token, uid = sign_in()
    print("signed in anonymously")

    if "--webhook-off" in sys.argv:
        print("webhook off: meeting only, status-poll fallback")
        _, _, out = run_transcription(token, uid, f"e2e-nohook-{int(time.time())}", f"{audio_dir}/meeting.m4a",
                                      "en", tus_upload)
        check(not out["webhook_arrived"], "no webhook arrived: the status poll finalised the job")
        print(json.dumps(out, indent=1))
        print("FAILED:" if fails else "ALL PASSED", *fails, sep="\n  ")
        sys.exit(1 if fails else 0)

    # Negative checks.
    print("negative checks")
    code = tus_upload(token, f"00000000-0000-0000-0000-000000000000/x.m4a", b"x" * 100)
    check(code in (400, 401, 403), f"upload into another user's folder refused (HTTP {code})")
    c, d, _ = call(token, "transcribe-start", {"client_note_id": "nope", "audio_path": f"{uid}/nope.m4a",
                                               "audio_seconds": 10, "language": "auto"})
    check(c == 404 and d["error"]["code"] == "not_found", f"start without upload -> {c} {d['error']['code']}")
    c, d, _ = call(token, "transcribe-start", {"client_note_id": "x", "audio_path": "other/x.m4a",
                                               "audio_seconds": 10})
    check(c == 400 and d["error"]["code"] == "bad_request", "start with wrong path -> bad_request")
    c, d, _ = call(token, "transcribe-start", {"client_note_id": "x", "audio_path": f"{uid}/x.m4a",
                                               "audio_seconds": 6 * 3600})
    check(c == 422 and d["error"]["code"] == "too_long", "start with 6 h audio -> too_long")
    c, d, _ = call(token, "summarize", {"transcript": "hi", "style": "poetry"})
    check(c == 400 and d["error"]["code"] == "bad_request", "summarize with unknown style -> bad_request")

    note = f"e2e-meeting-{int(time.time())}"
    print("meeting (TUS upload, language en)")
    job, turns, out = run_transcription(token, uid, note, f"{audio_dir}/meeting.m4a", "en", tus_upload)
    results["meeting"] = out
    check((out["speakers"] or 0) >= 2, f"≥2 distinct speakers (got {out['speakers']})")

    print("summarize (style meeting)")
    lines = "\n".join(f"Speaker {t['speaker']}: {t['text']}" for t in turns)
    c, d, dt = call(token, "summarize", {"transcript": lines, "style": "meeting", "output_language": "same"})
    s = d.get("summary", {})
    check(c == 200 and isinstance(s.get("in_short"), str) and s["in_short"], f"summarize -> {c} in {dt:.1f}s")
    print("    in_short:", s.get("in_short"))
    print("    decisions:", s.get("decisions"))
    print("    action_items:", s.get("action_items"))
    results["summary"] = {"seconds": round(dt, 1), "in_short": s.get("in_short"), "decisions": s.get("decisions"),
                          "action_items": s.get("action_items")}

    print("ask")
    ask_turns = [{"speaker": f"Speaker {t['speaker']}", "start_ms": t["start_ms"], "text": t["text"]} for t in turns]
    c, d, dt = call(token, "ask", {"transcript_turns": ask_turns, "question": "Who sends the TestFlight build, and when?",
                                   "history": []})
    starts = {t["start_ms"] for t in turns}
    check(c == 200 and d.get("found") and d.get("sources") and all(x["start_ms"] in starts for x in d["sources"]),
          f"ask (in transcript) -> {c} in {dt:.1f}s, {len(d.get('sources', []))} valid sources")
    print("    answer:", d.get("answer"), d.get("sources"))
    results["ask_found"] = {"seconds": round(dt, 1), "answer": d.get("answer"), "sources": d.get("sources")}
    c, d, dt = call(token, "ask", {"transcript_turns": ask_turns, "question": "What is the marketing budget for Germany?",
                                   "history": [{"role": "user", "content": "Who sends the TestFlight build?"},
                                               {"role": "assistant", "content": results["ask_found"]["answer"] or ""}]})
    check(c == 200 and d.get("found") is False and not d.get("sources"), f"ask (not in transcript) -> found=false")
    print("    answer:", d.get("answer"))
    results["ask_not_found"] = {"answer": d.get("answer")}

    print("hinglish (standard upload, language auto)")
    _, hturns, hout = run_transcription(token, uid, f"e2e-hinglish-{int(time.time())}", f"{audio_dir}/hinglish.m4a",
                                        "auto", std_upload, hints=["hi", "en"])
    results["hinglish"] = hout
    results["hinglish"]["sample"] = [t["text"] for t in hturns[:3]]

    print(json.dumps(results, indent=1, ensure_ascii=False))
    print("FAILED:" if fails else "ALL PASSED", *fails, sep="\n  ")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
