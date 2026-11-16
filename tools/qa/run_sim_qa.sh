#!/usr/bin/env bash
# Simulator QA: runs the REAL Longnote app in an iOS Simulator against the real
# backend, in 4 launches that share the app's data (docs/QA-SIMULATOR.md):
#   1-main     fresh install: first run, record, process, note screens, share, search
#   2-kill     record, then force-quit (SIGKILL) mid-recording
#   3-recover  "app closed while recording" + processing, settings, fast taps, import
#   4-offline  backend blocked before launch: note waits; unblocked: uploads itself
#   5-extra    simulated phone calls, 10 min in the background while recording,
#              a 60 min recording (fed at 12x) end to end
# Output: $QA_OUT (default build/qa_out): results/, shots/, logs/, crash/,
# summary.json, RESULTS.md. Exit 1 if any check failed, hung or crashed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="${QA_OUT:-$ROOT/build/qa_out}"
BUNDLE=com.novaralabs.longnote
RUNS=(
  "1-main integration_test/qa_1_main_test.dart"
  "2-kill integration_test/qa_2_kill_test.dart"
  "3-recover integration_test/qa_3_recover_test.dart"
  "4-offline integration_test/qa_4_offline_test.dart"
  "5-extra integration_test/qa_5_extra_test.dart"
)
ONLY="${QA_ONLY:-}"   # e.g. QA_ONLY="1-main" to run one launch

rm -rf "$OUT"
mkdir -p "$OUT"/{results,shots,logs,requests,state,audio,crash}
START_TS=$(date +%s)

UDID="${QA_UDID:-$(python3 tools/qa/pick_sim.py)}"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl list devices | grep "$UDID" | sed 's/^ *//' > "$OUT/logs/device.txt"
echo "Simulator: $(cat "$OUT/logs/device.txt")"
{ xcodebuild -version; flutter --version; } > "$OUT/logs/versions.txt" 2>&1

# Test audio: 16 kHz mono PCM16 WAV for the file microphone; the import clip as is.
for f in main_2voices killed offline; do
  afconvert -f WAVE -d LEI16@16000 -c 1 "integration_test/fixtures/$f.m4a" "$OUT/audio/$f.wav"
done
cp integration_test/fixtures/import_clip.m4a "$OUT/audio/"
# 60 min for the long-recording check: the 2-voice meeting looped with 2 s of
# silence between copies.
python3 - "$OUT/audio/main_2voices.wav" "$OUT/audio/long_60min.wav" <<'PY'
import sys, wave
src, dst = sys.argv[1], sys.argv[2]
with wave.open(src) as w:
    params, pcm = w.getparams(), w.readframes(w.getnframes())
gap = b"\0\0" * params.framerate * 2
target = params.framerate * 2 * 3600
with wave.open(dst, "wb") as o:
    o.setparams(params)
    n = 0
    while n < target:
        chunk = (pcm + gap)[: target - n]
        o.writeframes(chunk)
        n += len(chunk)
PY

# Simulator log of the app process for the whole session.
xcrun simctl spawn "$UDID" log stream --style compact --level debug \
  --predicate 'process == "Runner"' > "$OUT/logs/simulator-app.log" 2>&1 &
LOG_PID=$!
python3 tools/qa/watcher.py --out "$OUT" --udid "$UDID" > "$OUT/logs/watcher.log" 2>&1 &
WATCH_PID=$!
cleanup() {
  tools/qa/net_block.sh off "$OUT" >/dev/null 2>&1 || true
  kill "$LOG_PID" "$WATCH_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Generate ios/Pods before the first build: flutter only notices a plugin
# without an arm64-simulator slice (ffmpeg_kit_flutter_new_min, via
# whisper_ggml) when Pods exists, and then builds the simulator app for x86_64.
# Without this the first build links arm64 and fails.
flutter build ios --simulator --debug --config-only --no-pub \
  -t integration_test/qa_1_main_test.dart > "$OUT/logs/config-only.log" 2>&1 || true

# Fresh install for run 1.
xcrun simctl uninstall "$UDID" "$BUNDLE" 2>/dev/null || true

run() {
  local name=$1 target=$2
  rm -f "$OUT/heartbeat"
  echo "=== $name: $target ($(date -u +%T))"
  QA_OUT="$OUT" QA_RUN="$name" flutter drive -d "$UDID" \
    --driver test_driver/integration_test.dart --target "$target" \
    --keep-app-running --no-pub \
    --dart-define=QA_OUT="$OUT" --dart-define=QA_RUN="$name" \
    --dart-define=QA_AUDIO="$OUT/audio" > "$OUT/logs/$name.log" 2>&1 &
  local pid=$!
  echo "$name $pid" > "$OUT/state/current-run"
  # Last resort if a run never ends (the watcher handles app hangs).
  local limit=1200
  [ "$name" = 1-main ] && limit=2400
  [ "$name" = 5-extra ] && limit=5400
  ( sleep "$limit"; echo "run $name over ${limit}s: stopping it" >> "$OUT/logs/watcher.log"; kill "$pid" 2>/dev/null ) &
  local guard=$!
  wait "$pid"
  local rc=$?
  kill "$guard" 2>/dev/null || true
  rm -f "$OUT/state/current-run"
  echo "$rc" > "$OUT/results/$name.exit"
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  sleep 3
  echo "=== $name: flutter drive exit $rc ($(date -u +%T))"
  grep -F '[QA ' "$OUT/logs/$name.log" | grep -E ' (PASS|FAIL|SKIP) |APP ERROR|finished' | tail -n 60 || true
}

for r in "${RUNS[@]}"; do
  set -- $r
  if [ -n "$ONLY" ] && [[ " $ONLY " != *" $1 "* ]]; then continue; fi
  if [ "$1" = 4-offline ]; then
    echo "--- blocking the backend before launch 4"
    tools/qa/net_block.sh on "$OUT"
  fi
  run "$1" "$2"
  if grep -q "Could not build the application" "$OUT/logs/$1.log" 2>/dev/null; then
    echo "--- $1: build failed, trying once more"
    mv "$OUT/logs/$1.log" "$OUT/logs/$1.build-failed.log"
    run "$1" "$2"
  fi
  if [ "$1" = 4-offline ]; then tools/qa/net_block.sh off "$OUT"; fi
done

# Evidence: app diagnostics + database from the simulator, crash reports.
C=$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data 2>/dev/null || true)
if [ -n "$C" ]; then
  cp -R "$C/Library/Application Support/diagnostics" "$OUT/app-diagnostics" 2>/dev/null || true
fi
python3 - "$START_TS" "$OUT/crash" <<'PY'
import glob, os, re, shutil, sys
since, dest = float(sys.argv[1]), sys.argv[2]
for d in [os.path.expanduser("~/Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports"]:
    for f in glob.glob(os.path.join(d, "**", "*"), recursive=True):
        n = os.path.basename(f)
        if os.path.isfile(f) and os.path.getmtime(f) >= since and (re.match(r"Runner[-_.]", n) or "longnote" in n.lower()):
            shutil.copy2(f, dest)
            print("crash report:", n)
PY

python3 tools/qa/summarize.py "$OUT"
