#!/usr/bin/env python3
"""Concurrency tests against the real project (review findings 2 and 4).

  python3 tools/e2e/race_cap.py /tmp/longnote-e2e

1. Start race: one upload, 5 parallel transcribe-start calls for the same
   note -> one job id for all, ONE Soniox transcription (by
   client_reference_id and by "created since the test started").
2. Cost cap: a temporary, self-expiring test override (ln_test_overrides,
   expires in 10 min, deleted at the end) lowers the global LLM pool
   (cost_daily.llm_usd, key global_llm_usd_cap) to "today's LLM spend +
   room for one call". 5 parallel summarize (then 5 ask) -> exactly one 200,
   four limit_reached/global_day, and the pool never goes over the cap.
   Each request is unique (the summarize cache would answer a repeat).
Reads .env.local; never prints secrets. The service-role key is used only
for the override and the checks (job row, cost_daily).
"""
import datetime as dt
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import requests

sys.path.insert(0, os.path.dirname(__file__))
from e2e import E, URL, call, check, fails, sign_in, std_upload  # noqa: E402

SR = E["SUPABASE_SERVICE_ROLE_KEY"]
REST = f"{URL}/rest/v1"
H_SR = {"apikey": SR, "Authorization": f"Bearer {SR}", "Content-Type": "application/json"}
SONIOX = {"Authorization": f"Bearer {E['SONIOX_API_KEY']}"}


def parallel(n, fn):
    with ThreadPoolExecutor(n) as ex:
        return list(ex.map(lambda _: fn(), range(n)))


def soniox_transcriptions():
    r = requests.get("https://api.soniox.com/v1/transcriptions?limit=100", headers=SONIOX, timeout=30)
    r.raise_for_status()
    return r.json().get("transcriptions", [])


def cost_today(col="llm_usd"):
    day = dt.datetime.now(dt.timezone.utc).date().isoformat()
    r = requests.get(f"{REST}/cost_daily?day=eq.{day}&select={col}", headers=H_SR, timeout=30)
    rows = r.json()
    return float(rows[0][col]) if rows else 0.0


def set_override(key, value, minutes=10):
    exp = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=minutes)).isoformat()
    r = requests.post(f"{REST}/ln_test_overrides", headers={**H_SR, "Prefer": "resolution=merge-duplicates"},
                      json={"key": key, "value": value, "expires_at": exp}, timeout=30)
    r.raise_for_status()


def clear_override(key):
    requests.delete(f"{REST}/ln_test_overrides?key=eq.{requests.utils.quote(key, safe='')}", headers=H_SR,
                    timeout=30)


def set_cap_override(value):
    set_override("global_llm_usd_cap", value)


def clear_cap_override():
    clear_override("global_llm_usd_cap")


def start_race(token, uid, audio):
    print("start race: 5 parallel transcribe-start for one note")
    note = f"e2e-race-{int(time.time())}"
    path = f"{uid}/{note}.m4a"
    code = std_upload(token, path, open(audio, "rb").read())
    check(code == 200, f"upload -> {code}")
    since = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=5)
    body = {"client_note_id": note, "audio_path": path, "audio_seconds": 60.2, "language": "en"}
    res = parallel(5, lambda: call(token, "transcribe-start", body))
    ids = {d.get("job_id") for c, d, _ in res}
    codes = sorted(c for c, _, _ in res)
    print("    replies:", [(c, d.get("status")) for c, d, _ in res])
    check(codes == [200] * 5 and len(ids) == 1, f"5 replies 200 with one job_id (codes {codes}, ids {len(ids)})")
    job = ids.pop()
    # Let any loser that is still inside Soniox finish (there should be none).
    time.sleep(3)
    ts = soniox_transcriptions()
    mine = [t for t in ts if t.get("client_reference_id") == job]
    new = [t for t in ts if t.get("created_at", "") >= since.isoformat().replace("+00:00", "Z")]
    r = requests.get(f"{REST}/jobs?id=eq.{job}&select=status,tries,charged_seconds,soniox_deleted",
                     headers=H_SR, timeout=30).json()[0]
    # A short clip can finish (webhook) and be deleted at Soniox within the
    # 3 s wait; then 0 listed is right if the job row says it was deleted.
    check(len(mine) == 1 or (len(mine) == 0 and r["soniox_deleted"]),
          f"exactly one Soniox transcription for the job (listed {len(mine)}, deleted={r['soniox_deleted']})")
    check(len(new) <= 1, f"at most one Soniox transcription created during the race (got {len(new)})")
    check(r["tries"] == 1, f"job row: tries=1, status {r['status']}, charged {r['charged_seconds']} s")
    # Finish it so Soniox + storage are cleaned up.
    for _ in range(60):
        c, d, _ = call(token, "transcribe-status", {"job_id": job})
        if d.get("status") in ("done", "failed"):
            break
        time.sleep(3)
    check(d.get("status") == "done", "race job finished")
    call(token, "transcribe-status", {"job_id": job, "ack": True})
    return {"replies": [(c, d.get("status")) for c, d, _ in res], "soniox_transcriptions": len(mine),
            "charged_seconds": r["charged_seconds"]}


def cap_race(token, fn, body, room):
    base = cost_today()
    cap = round(base + room, 4)
    set_cap_override(cap)
    try:
        n = iter(range(5))
        res = parallel(5, lambda: call(token, fn, body(next(n))))
        during = cost_today()
    finally:
        clear_cap_override()
    ok = [x for x in res if x[0] == 200]
    capped = [x for x in res if x[0] == 429 and x[1].get("error", {}).get("detail", {}).get("scope") == "global_day"]
    after = cost_today()
    print(f"    {fn}: base ${base:.4f}, cap ${cap:.4f}, after ${after:.4f}; replies", sorted(x[0] for x in res))
    check(len(ok) == 1 and len(capped) == 4, f"{fn}: exactly 1 ok + 4 global_day ({len(ok)} ok, {len(capped)} capped)")
    check(during <= cap + 1e-9 and after <= cap + 1e-9, f"{fn}: cost_daily stayed within the cap")
    check(after > base, f"{fn}: settled to the real cost (+${after - base:.4f})")
    return {"base": base, "cap": cap, "after": after, "ok": len(ok), "capped": len(capped)}


def main():
    audio_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/longnote-e2e"
    token, uid = sign_in()
    out = {"start_race": start_race(token, uid, f"{audio_dir}/meeting.m4a")}

    print("cost cap: 5 parallel summarize with room for one")
    transcript = "Speaker 1: We will ship on Monday.\nSpeaker 2: Priya sends the budget on Friday."
    # One summarize reserves ~$0.055; unique per call (the cache would answer a repeat).
    stamp = time.time()
    out["summarize_cap"] = cap_race(
        token, "summarize", lambda i: {"transcript": f"{transcript}\nSpeaker 1: Run {stamp} call {i}.", "style": "meeting"},
        0.08)
    print("cost cap: 5 parallel ask with room for one")
    turns = [{"speaker": "Speaker 1", "start_ms": 0, "text": "We will ship on Monday."},
             {"speaker": "Speaker 2", "start_ms": 4000, "text": "Priya sends the budget on Friday."}]
    # One ask reserves ~$0.019 (4k output tokens budget).
    out["ask_cap"] = cap_race(token, "ask", lambda i: {"transcript_turns": turns, "question": f"When do we ship? ({i})"},
                              0.03)
    print(out)
    print("FAILED:" if fails else "ALL PASSED", *fails, sep="\n  ")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
