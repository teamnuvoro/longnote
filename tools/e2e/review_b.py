#!/usr/bin/env python3
"""Checks for the review-B backend fixes against the real project.

  python3 tools/e2e/review_b.py /tmp/longnote-e2e

1. summarize idempotency (A5/L6): the same request twice -> the second is
   `cached`, no second charge; 3 parallel identical requests -> one OpenAI
   call (summary_calls +1, LLM spend +1 call).
2. Dollar caps (B1): per-user LLM USD cap -> user_day; per-IP LLM USD cap ->
   ip_day; audio pool full -> transcribe-start global_day while summarize
   still works (separate pools). All via self-expiring test overrides scoped
   to this test user / this IP / 2 minutes, deleted at the end.
3. Lost Soniox reply (B3): a job marked start_unknown with a transcription
   already at Soniox -> transcribe-start adopts it (one transcription), job
   finishes; the IP audio charge is settled to the real duration (B6).
4. Orphan webhook (B3): a Soniox transcription for a finished job that the
   job does not point to -> the webhook deletes it at Soniox.
5. report (B5): duplicate -> stored false; per-user cap under 6 parallel
   calls -> exactly the cap stored; per-IP cap -> ip_day.
6. Upload guards (B4): 26th object for one user refused; a 105 MB TUS
   upload refused at creation.
Costs about $0.002. Reads .env.local; never prints secrets. The service-role
key is used only for overrides, job-row setup and checks.
"""
import base64
import datetime as dt
import os
import sys
import time
import uuid
from concurrent.futures import ThreadPoolExecutor

import requests

sys.path.insert(0, os.path.dirname(__file__))
from e2e import ANON, E, TUS, URL, b64, call, check, fails, sign_in, std_upload  # noqa: E402
from race_cap import H_SR, REST, SONIOX, clear_override, cost_today, set_override  # noqa: E402

SONIOX_API = "https://api.soniox.com/v1/transcriptions"
TODAY = dt.datetime.now(dt.timezone.utc).date().isoformat()
_overrides = []


def override(key, value):
    set_override(key, value, minutes=2)
    _overrides.append(key)


def usage(uid):
    r = requests.get(f"{REST}/usage_daily?user_id=eq.{uid}&day=eq.{TODAY}&select=summary_calls,ask_calls,llm_usd,"
                     "audio_seconds", headers=H_SR, timeout=30).json()
    return r[0] if r else {"summary_calls": 0, "ask_calls": 0, "llm_usd": 0, "audio_seconds": 0}


def ip_rows(kind):
    r = requests.get(f"{REST}/ip_daily?day=eq.{TODAY}&kind=eq.{kind}&select=ip_hash,used,usd", headers=H_SR,
                     timeout=30).json()
    return {x["ip_hash"]: x for x in r}


def my_ip_hash(before, after):
    """The IP row that moved between two snapshots (this machine's IP)."""
    moved = [h for h, x in after.items() if h not in before or x["used"] != before[h]["used"]]
    return moved[0] if len(moved) == 1 else None


def job_by_note(uid, note):
    r = requests.get(f"{REST}/jobs?user_id=eq.{uid}&client_note_id=eq.{note}&select=*", headers=H_SR,
                     timeout=30).json()
    return r[0] if r else None


def wait_done(token, job, limit=120):
    d = {}
    for _ in range(limit):
        _, d, _ = call(token, "transcribe-status", {"job_id": job})
        if d.get("status") in ("done", "failed"):
            break
        time.sleep(3)
    return d


def summarize_checks(token, uid):
    print("1. summarize idempotency")
    body = {"transcript": f"Speaker 1: Idempotency check {uuid.uuid4()}. We ship on Monday.\n"
                          "Speaker 2: Priya sends the budget on Friday.", "style": "meeting"}
    ip0 = ip_rows("summary")
    u0, c0 = usage(uid), cost_today()
    c1_, d1, t1 = call(token, "summarize", body)
    ip1 = ip_rows("summary")
    u1, c1 = usage(uid), cost_today()
    c2_, d2, t2 = call(token, "summarize", body)
    u2, c2 = usage(uid), cost_today()
    check(c1_ == 200 and d1.get("cached") is False, f"first call 200, cached=false ({t1:.1f}s)")
    check(c2_ == 200 and d2.get("cached") is True and d2.get("summary") == d1.get("summary"),
          f"re-send 200, cached=true, same summary ({t2:.1f}s)")
    check(u2["summary_calls"] == u1["summary_calls"] == u0["summary_calls"] + 1,
          f"summary_calls +1 only ({u0['summary_calls']} -> {u2['summary_calls']})")
    check(abs(c2 - c1) < 1e-9 and c1 > c0, f"LLM pool charged once (+${c1 - c0:.4f}, re-send +${c2 - c1:.4f})")
    check(float(u1["llm_usd"]) > float(u0["llm_usd"]), f"user llm_usd settled to real cost ({u1['llm_usd']})")

    body3 = {**body, "transcript": body["transcript"] + f"\nSpeaker 1: parallel {uuid.uuid4()}"}
    ua = usage(uid)
    with ThreadPoolExecutor(3) as ex:
        res = list(ex.map(lambda _: call(token, "summarize", body3), range(3)))
    ub = usage(uid)
    flags = sorted(str(d.get("cached")) for _, d, _ in res)
    check(all(c == 200 for c, _, _ in res) and flags == ["False", "True", "True"],
          f"3 parallel identical -> 3x200, one computed ({flags})")
    check(ub["summary_calls"] == ua["summary_calls"] + 1, "parallel: summary_calls +1 only")
    return my_ip_hash(ip0, ip1)


def dollar_cap_checks(token, uid, iph, audio_dir):
    print("2. dollar caps")
    override(f"user_llm_usd_cap:{uid}", 0.0001)
    c, d, _ = call(token, "summarize", {"transcript": f"Speaker 1: user cap {uuid.uuid4()}", "style": "meeting"})
    check(c == 429 and d["error"]["detail"]["scope"] == "user_day", f"user USD cap -> {c} {d.get('error', {}).get('detail')}")
    clear_override(f"user_llm_usd_cap:{uid}")
    if iph:
        override(f"ip_llm_usd_cap:{iph}", 0.0001)
        u0 = usage(uid)
        c, d, _ = call(token, "ask", {"transcript_turns": [{"speaker": "A", "start_ms": 0, "text": "We ship Monday."}],
                                      "question": f"When? {uuid.uuid4()}"})
        check(c == 429 and d["error"]["detail"]["scope"] == "ip_day", f"IP USD cap -> {c} {d.get('error', {}).get('detail')}")
        check(usage(uid)["ask_calls"] == u0["ask_calls"], "refused call charged nothing to the user (L1)")
        clear_override(f"ip_llm_usd_cap:{iph}")
    else:
        check(False, "could not identify this machine's IP row")

    # Audio pool full -> transcription refused, LLM still served.
    note = f"e2e-pool-{int(time.time())}"
    path = f"{uid}/{note}.m4a"
    check(std_upload(token, path, open(f"{audio_dir}/hinglish.m4a", "rb").read()) == 200, "upload for pool test")
    override("global_audio_usd_cap", max(cost_today("audio_usd"), 0.0001))
    body = {"client_note_id": note, "audio_path": path, "audio_seconds": 22.9, "language": "auto"}
    c, d, _ = call(token, "transcribe-start", body)
    check(c == 429 and d["error"]["detail"]["scope"] == "global_day", f"audio pool full -> {c} global_day")
    c2, d2, _ = call(token, "summarize", {"transcript": f"Speaker 1: pool split {uuid.uuid4()}", "style": "meeting"})
    check(c2 == 200, f"summarize still works while the audio pool is full ({c2})")
    clear_override("global_audio_usd_cap")
    c, d, _ = call(token, "transcribe-start", body)
    check(c == 200 and d.get("status") == "transcribing", f"after the pool frees: start -> {d.get('status')}")
    d = wait_done(token, d.get("job_id"))
    check(d.get("status") == "done", "pool-test job done")
    call(token, "transcribe-status", {"job_id": d.get("job_id"), "ack": True})
    row = job_by_note(uid, note)
    check(row["started_at"] is not None, "started_at set by the start claim (B2)")


def adopt_checks(token, uid, iph, audio_dir):
    print("3. lost Soniox reply: adopt instead of a second transcription")
    note = f"e2e-adopt-{int(time.time())}"
    path = f"{uid}/{note}.m4a"
    data = open(f"{audio_dir}/hinglish.m4a", "rb").read()
    check(std_upload(token, path, data) == 200, "upload")
    # Job row as transcribe-start leaves it after a lost reply.
    r = requests.post(f"{REST}/jobs", headers={**H_SR, "Prefer": "return=representation"},
                      json={"user_id": uid, "client_note_id": note, "status": "uploaded", "audio_path": path,
                            "audio_bytes": len(data), "audio_seconds": 23, "tries": 1, "error_code": "upstream_failed",
                            "error": "start_unknown: test"}, timeout=30)
    job = r.json()[0]["id"]
    s = requests.post(f"{URL}/storage/v1/object/sign/uploads/{path}", headers=H_SR, json={"expiresIn": 3600},
                      timeout=30).json()
    signed = URL + "/storage/v1" + s["signedURL"]
    t = requests.post(SONIOX_API, headers={**SONIOX, "Content-Type": "application/json"},
                      json={"model": "stt-async-v6", "audio_url": signed, "client_reference_id": job}, timeout=30)
    check(t.status_code in (200, 201), f"pre-created Soniox transcription ({t.status_code})")
    tid = t.json().get("id")
    ip0 = ip_rows("audio").get(iph, {}).get("used", 0) if iph else 0
    c, d, _ = call(token, "transcribe-start", {"client_note_id": note, "audio_path": path, "audio_seconds": 60,
                                               "language": "auto"})
    check(c == 200 and d.get("status") == "transcribing", f"start after a lost reply -> {c} {d.get('status')}")
    row = job_by_note(uid, note)
    check(row["soniox_transcription_id"] == tid, "adopted the existing transcription (same id)")
    lst = requests.get(f"{SONIOX_API}?limit=100", headers=SONIOX, timeout=30).json().get("transcriptions", [])
    check(len([x for x in lst if x.get("client_reference_id") == job]) == 1, "one Soniox transcription for the job")
    d = wait_done(token, job)
    check(d.get("status") == "done", "adopted job done (status fallback finalised it)")
    row = job_by_note(uid, note)
    if iph:
        ip1 = ip_rows("audio").get(iph, {}).get("used", 0)
        check(row["ip_charged_seconds"] == row["charged_seconds"] and row["charged_seconds"] < 60,
              f"IP + user charge settled to real duration (claimed 60 s, now {row['charged_seconds']} s; "
              f"IP row {ip0} -> {ip1})")
    call(token, "transcribe-status", {"job_id": job, "ack": True})
    return job


def orphan_checks(uid, job, audio_dir, token):
    print("4. orphan transcription -> webhook deletes it")
    note = f"e2e-orphan-{int(time.time())}"
    path = f"{uid}/{note}.m4a"
    check(std_upload(token, path, open(f"{audio_dir}/hinglish.m4a", "rb").read()) == 200, "upload (signed URL source)")
    s = requests.post(f"{URL}/storage/v1/object/sign/uploads/{path}", headers=H_SR, json={"expiresIn": 600},
                      timeout=30).json()
    t = requests.post(SONIOX_API, headers={**SONIOX, "Content-Type": "application/json"},
                      json={"model": "stt-async-v6", "audio_url": URL + "/storage/v1" + s["signedURL"],
                            "client_reference_id": job}, timeout=30)
    tid = t.json().get("id")
    for _ in range(40):  # the real webhook comes when it has finished
        if requests.get(f"{SONIOX_API}/{tid}", headers=SONIOX, timeout=30).json().get("status") in ("completed", "error"):
            break
        time.sleep(2)
    r = requests.post(f"{URL}/functions/v1/soniox-webhook",
                      headers={"x-longnote-webhook-secret": E["SONIOX_WEBHOOK_SECRET"]},
                      json={"id": tid, "status": "completed"}, timeout=60)
    check(r.status_code == 200 and r.json().get("deleted_orphan") is True, f"webhook -> {r.status_code} {r.json()}")
    g = requests.get(f"{SONIOX_API}/{tid}", headers=SONIOX, timeout=30)
    check(g.status_code == 404, f"orphan gone at Soniox ({g.status_code})")
    requests.delete(f"{URL}/storage/v1/object/uploads",
                    headers={"Authorization": f"Bearer {token}", "apikey": ANON}, json={"prefixes": [path]}, timeout=30)


def report_checks(token, uid, iph):
    print("5. report caps")
    rep = {"kind": "flutter_error", "error_type": "StateError", "stack": f"#0 test {uuid.uuid4()}"}
    c1, d1, _ = call(token, "report", rep)
    c2, d2, _ = call(token, "report", rep)
    check(d1.get("stored") is True and d2.get("stored") is False, f"duplicate ignored ({d1}, {d2})")
    override(f"report_user:{uid}", 3)  # 1 stored so far -> room for 2
    with ThreadPoolExecutor(6) as ex:
        res = list(ex.map(lambda i: call(token, "report", {**rep, "stack": f"#0 par {i} {uuid.uuid4()}"}), range(6)))
    stored = sum(1 for _, d, _ in res if d.get("stored"))
    check(stored == 2 and all(c == 200 for c, _, _ in res), f"6 parallel with room for 2 -> {stored} stored")
    clear_override(f"report_user:{uid}")
    if iph:
        used = ip_rows("report").get(iph, {}).get("used", 0)
        override(f"report_ip:{iph}", used)
        c, d, _ = call(token, "report", {**rep, "stack": f"#0 ip {uuid.uuid4()}"})
        check(d.get("stored") is False and d.get("reason") == "ip_day", f"IP report cap -> {d}")
        clear_override(f"report_ip:{iph}")
    requests.delete(f"{REST}/client_reports?user_id=eq.{uid}", headers=H_SR, timeout=30)


def upload_guard_checks(token, uid):
    print("6. upload guards")
    paths = []
    codes = []
    for i in range(26):
        p = f"{uid}/e2e-cnt-{i}.m4a"
        codes.append(std_upload(token, p, b"\x00" * 64))
        paths.append(p)
    check(all(c == 200 for c in codes[:25]) and codes[25] in (400, 403),
          f"25 objects ok, 26th refused ({codes[25]})")
    h = {"Authorization": f"Bearer {token}", "apikey": ANON, "Tus-Resumable": "1.0.0", "x-upsert": "true"}
    meta = f"bucketName {b64('uploads')},objectName {b64(uid + '/e2e-big.m4a')},contentType {b64('audio/mp4')}"
    requests.delete(f"{URL}/storage/v1/object/uploads", headers={"Authorization": f"Bearer {token}", "apikey": ANON},
                    json={"prefixes": paths}, timeout=60)
    r = requests.post(TUS, headers={**h, "Upload-Length": str(105 * 1024 * 1024), "Upload-Metadata": meta}, timeout=60)
    check(r.status_code == 413, f"105 MB TUS upload refused at creation ({r.status_code})")


def main():
    audio_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/longnote-e2e"
    token, uid = sign_in()
    try:
        iph = summarize_checks(token, uid)
        print("    ip row found:", bool(iph))
        dollar_cap_checks(token, uid, iph, audio_dir)
        job = adopt_checks(token, uid, iph, audio_dir)
        orphan_checks(uid, job, audio_dir, token)
        report_checks(token, uid, iph)
        upload_guard_checks(token, uid)
    finally:
        for k in _overrides:
            clear_override(k)
    print("FAILED:" if fails else "ALL PASSED", *fails, sep="\n  ")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
