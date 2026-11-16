#!/usr/bin/env python3
"""Merges the simulator QA output into summary.json + RESULTS.md and exits 1
when anything failed. Usage: summarize.py QA_OUT"""
import glob
import json
import os
import re
import sys

OUT = sys.argv[1]
RUNS = [
    ("1-main", "First run, recording, processing, note screens", True),
    ("2-kill", "Force-quit while recording", False),  # ends by SIGKILL: drive exit != 0 expected
    ("3-recover", "Recovery, settings, fast taps, import", True),
    ("4-offline", "Server unreachable, then back", True),
    ("5-extra", "Phone calls, background, 1-hour recording", True),
]


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def tail(path, n=40):
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        return []
    keep = [l for l in lines if not l.startswith("[QA")]
    return keep[-n:]


runs = []
for name, title, needs_exit0 in RUNS:
    res = load(os.path.join(OUT, "results", f"{name}.json"))
    exit_txt = None
    try:
        exit_txt = open(os.path.join(OUT, "results", f"{name}.exit")).read().strip()
    except OSError:
        pass
    if res is None and exit_txt is None:
        continue  # not run (QA_ONLY)
    hang = load(os.path.join(OUT, "results", f"{name}.hang.json"))
    checks = (res or {}).get("checks", [])
    problems = []
    if res is None:
        problems.append("the app never wrote results (build or launch failed): see logs/%s.log" % name)
    elif not res.get("finished"):
        problems.append("the run stopped before its last check")
    if hang:
        problems.append("%s: heartbeat stopped %ss during check %s" % (
            hang["verdict"], hang["heartbeat_age_s"], (hang.get("last_heartbeat") or {}).get("check")))
    if needs_exit0 and exit_txt not in (None, "0") and not any(c["status"] == "FAIL" for c in checks):
        problems.append("flutter drive exit %s with no failed check (see logs/%s.log)" % (exit_txt, name))
    if not needs_exit0 and res is not None:
        if not any(c["id"] == "E2" and c["status"] == "PASS" for c in checks):
            problems.append("the force-quit did not happen while recording")
    runs.append({
        "name": name,
        "title": title,
        "drive_exit": exit_txt,
        "checks": checks,
        "app_errors": (res or {}).get("app_errors", []),
        "audio_seconds_sent": (res or {}).get("audio_seconds_sent"),
        "hang": hang,
        "problems": problems,
        "log_tail": tail(os.path.join(OUT, "logs", f"{name}.log")) if problems else [],
    })

crashes = sorted(os.path.basename(p) for p in glob.glob(os.path.join(OUT, "crash", "*")))
diag = sorted(os.path.basename(p) for p in glob.glob(os.path.join(OUT, "app-diagnostics", "*")))
allc = [c for r in runs for c in r["checks"]]
count = {s: sum(1 for c in allc if c["status"] == s) for s in ("PASS", "FAIL", "SKIP")}
problems = [f'{r["name"]}: {p}' for r in runs for p in r["problems"]]
problems += [f"crash report: {c}" for c in crashes]
ok = count["FAIL"] == 0 and count["SKIP"] == 0 and not problems and bool(runs)
summary = {
    "verdict": "PASS" if ok else "FAIL",
    "counts": count,
    "problems": problems,
    "runs": runs,
    "crash_reports": crashes,
    "app_diagnostics": diag,
    "device": open(os.path.join(OUT, "logs", "device.txt")).read().strip()
    if os.path.exists(os.path.join(OUT, "logs", "device.txt")) else None,
    "run_url": "%s/%s/actions/runs/%s" % (os.environ.get("GITHUB_SERVER_URL", ""),
                                         os.environ.get("GITHUB_REPOSITORY", ""),
                                         os.environ.get("GITHUB_RUN_ID", ""))
    if os.environ.get("GITHUB_RUN_ID") else None,
    "commit": os.environ.get("GITHUB_SHA"),
}
with open(os.path.join(OUT, "summary.json"), "w") as f:
    json.dump(summary, f, indent=1)

md = [f"# Longnote simulator QA: {summary['verdict']}", "",
      f"{count['PASS']} pass, {count['FAIL']} fail, {count['SKIP']} skip. Device: {summary['device']}", ""]
if problems:
    md += ["## Problems", ""] + [f"- {p}" for p in problems] + [""]
for r in runs:
    md += [f"## {r['name']}: {r['title']} (drive exit {r['drive_exit']}, audio {r['audio_seconds_sent']} s)", "",
           "| Check | Result | Time | Detail |", "|---|---|---|---|"]
    for c in r["checks"]:
        detail = c.get("error") or "; ".join(c.get("notes", []))
        detail = re.sub(r"\s+", " ", detail).replace("|", "/")[:300]
        md.append(f"| {c['id']} {c['title']} | {c['status']} | {c['ms'] / 1000:.1f} s | {detail} |")
    md.append("")
    for e in r["app_errors"]:
        md.append(f"- app error in {e.get('check')}: {e.get('kind')}: {e.get('text', '')[:300]}")
    if r["log_tail"]:
        md += ["", "```", *r["log_tail"][-25:], "```"]
    md.append("")
with open(os.path.join(OUT, "RESULTS.md"), "w") as f:
    f.write("\n".join(md))
print("\n".join(md))
sys.exit(0 if ok else 1)
