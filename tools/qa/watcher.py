#!/usr/bin/env python3
"""Host watcher for the simulator QA runs (started by run_sim_qa.sh).

1. Hang detector. The app writes QA_OUT/heartbeat every second from a Dart
   timer. A microtask livelock or a stuck UI isolate stops every Dart timer,
   so if the heartbeat of the current run is older than HANG_SECS while the
   run says "running", this records a hang: a simulator screenshot, a native
   `sample` of the app process, the last check id, then stops that run.
2. Requests from the app: QA_OUT/requests/<name> -> do it -> <name>.done
   (`unblock` / `block` = tools/qa/net_block.sh off / on).
"""
import argparse
import json
import os
import signal
import subprocess
import time

HANG_SECS = 45

ap = argparse.ArgumentParser()
ap.add_argument("--out", required=True)
ap.add_argument("--udid", required=True)
args = ap.parse_args()
OUT = args.out
HERE = os.path.dirname(os.path.abspath(__file__))
REQ = os.path.join(OUT, "requests")
reported = set()


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=120, **kw)


def current_run():
    try:
        name, pid = open(os.path.join(OUT, "state", "current-run")).read().split()
        return name, int(pid)
    except (OSError, ValueError):
        return None, None


def app_pids():
    r = sh(["pgrep", "-f", "Runner.app/Runner"])
    return [int(x) for x in r.stdout.split()] if r.returncode == 0 else []


def on_hang(run, drive_pid, hb, age):
    log(f"HANG in {run}: heartbeat {age:.0f}s old, last check {hb.get('check')}")
    shots = os.path.join(OUT, "shots", run)
    os.makedirs(shots, exist_ok=True)
    sh(["xcrun", "simctl", "io", args.udid, "screenshot", os.path.join(shots, "99-HANG-simulator.png")])
    pids = app_pids()
    sample = None
    if pids:
        sample = os.path.join(OUT, "logs", f"{run}-hang-sample.txt")
        sh(["sample", str(pids[0]), "5", "-file", sample])
    report = {
        "run": run,
        "heartbeat_age_s": round(age),
        "last_heartbeat": hb,
        "app_process_alive": bool(pids),
        "sample": os.path.basename(sample) if sample else None,
        "verdict": "HANG (Dart UI isolate stopped: no timer has run)" if pids
        else "APP PROCESS GONE (crash?) while the run was going",
    }
    with open(os.path.join(OUT, "results", f"{run}.hang.json"), "w") as f:
        json.dump(report, f, indent=1)
    # Stop the run: the app first (flutter drive then fails fast), then drive.
    sh(["xcrun", "simctl", "terminate", args.udid, "com.novaralabs.longnote"])
    time.sleep(10)
    try:
        os.kill(drive_pid, signal.SIGTERM)
    except OSError:
        pass


def handle_requests():
    if not os.path.isdir(REQ):
        return
    for name in os.listdir(REQ):
        if name.endswith(".done") or name == "blocked-state":
            continue
        path = os.path.join(REQ, name)
        if name in ("unblock", "block"):
            r = sh([os.path.join(HERE, "net_block.sh"), "off" if name == "unblock" else "on", OUT])
            msg = (r.stdout.strip().splitlines() or [r.stderr.strip()])[-1]
        else:
            msg = f"unknown request {name}"
        log(f"request {name}: {msg}")
        with open(path + ".done", "w") as f:
            f.write(msg + "\n")
        os.remove(path)


log(f"watching {OUT}")
while True:
    try:
        handle_requests()
        run, drive_pid = current_run()
        hb_path = os.path.join(OUT, "heartbeat")
        if run and run not in reported and os.path.exists(hb_path):
            try:
                hb = json.load(open(hb_path))
            except (OSError, ValueError):
                hb = {}
            age = time.time() - os.path.getmtime(hb_path)
            if hb.get("run") == run and hb.get("state") == "running" and age > HANG_SECS:
                reported.add(run)
                on_hang(run, drive_pid, hb, age)
    except Exception as e:  # keep watching whatever happens
        log(f"watcher error: {e!r}")
    time.sleep(1)
