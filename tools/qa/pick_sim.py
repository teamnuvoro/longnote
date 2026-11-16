#!/usr/bin/env python3
"""Prints the UDID of an available iPhone simulator (newest iOS; iPhone 16
family first). Used by run_sim_qa.sh."""
import json
import re
import subprocess

data = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "available", "-j"],
                                 check=True, capture_output=True, text=True).stdout)
best = None
for runtime, devices in data["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    ver = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        name = d["name"]
        if not name.startswith("iPhone") or "SE" in name:
            continue
        pref = 2 if re.match(r"iPhone 16( Pro)?$", name) else (1 if re.match(r"iPhone \d+$", name) else 0)
        key = (ver, pref)
        if best is None or key > best[0]:
            best = (key, d["udid"], name, runtime)
if best is None:
    raise SystemExit("no iPhone simulator available")
print(best[1])
