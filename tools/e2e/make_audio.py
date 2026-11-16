#!/usr/bin/env python3
"""Make the e2e test audio with OpenAI TTS (two voices), then encode to the
format the app uploads: AAC-LC m4a, mono, 16 kHz, ~32 kbps.

Usage: python3 tools/e2e/make_audio.py [outdir]   (default /tmp/longnote-e2e)
Reads OPENAI_API_KEY from .env.local; never prints it. Cost: well under $0.05.
"""
import os
import subprocess
import sys
import tempfile

import requests

sys.path.insert(0, os.path.dirname(__file__))
from envfile import load_env  # noqa: E402

MEETING = [
    ("alloy", "Okay, let's start. This is the weekly launch sync for Longnote. Priya, where are we on the App Store listing?"),
    ("onyx", "The screenshots are done. I still need the final description and the privacy answers. I can finish both by Thursday the twentieth of November."),
    ("alloy", "Good. The other open point is pricing. We said nine ninety-nine a month and fifty-nine ninety-nine a year, with a three day trial. Any objections?"),
    ("onyx", "No objection from me. I'd keep the weekly plan out. Users hate surprise charges."),
    ("alloy", "Agreed. So the decision is: no weekly plan, monthly and yearly only. Rahul will set up the products in App Store Connect."),
    ("onyx", "And who sends the build to TestFlight?"),
    ("alloy", "I will send the TestFlight build on Monday. One question we have not settled is whether to support Android this year."),
    ("onyx", "Let's park Android until after the first month of sales data. Thanks everyone."),
]

HINGLISH = [
    ("nova", "Hello Arjun, kal ki meeting ke baare mein baat karni thi. Client ne budget fifty thousand rupees confirm kar diya hai."),
    ("echo", "Achha, great. Toh hum design ka kaam Monday se start kar dete hain. Main team ko aaj shaam tak bata dunga."),
    ("nova", "Perfect. Aur invoice Friday tak bhej dena, please."),
]


def tts(key: str, voice: str, text: str, path: str) -> None:
    r = requests.post(
        "https://api.openai.com/v1/audio/speech",
        headers={"Authorization": f"Bearer {key}"},
        json={"model": "gpt-4o-mini-tts", "voice": voice, "input": text, "response_format": "wav"},
        timeout=120,
    )
    if r.status_code != 200:
        raise SystemExit(f"TTS failed: HTTP {r.status_code}")
    with open(path, "wb") as f:
        f.write(r.content)


def build(key: str, lines, out_m4a: str) -> None:
    with tempfile.TemporaryDirectory() as td:
        parts = []
        for i, (voice, text) in enumerate(lines):
            p = os.path.join(td, f"{i:02d}.wav")
            tts(key, voice, text, p)
            parts.append(p)
        # 0.6 s of silence between turns, then encode like the app does.
        inputs, filt = [], []
        for i, p in enumerate(parts):
            inputs += ["-i", p]
            filt.append(f"[{i}:a]aresample=16000,aformat=channel_layouts=mono,apad=pad_dur=0.6[a{i}]")
        concat = "".join(f"[a{i}]" for i in range(len(parts))) + f"concat=n={len(parts)}:v=0:a=1[out]"
        cmd = ["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", ";".join(filt + [concat]),
               "-map", "[out]", "-c:a", "aac", "-profile:a", "aac_low", "-b:a", "32k", "-ar", "16000", "-ac", "1",
               "-movflags", "+faststart", out_m4a]
        subprocess.run(cmd, check=True)


def main() -> None:
    out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/longnote-e2e"
    os.makedirs(out, exist_ok=True)
    key = load_env()["OPENAI_API_KEY"]
    for name, lines in (("meeting", MEETING), ("hinglish", HINGLISH)):
        path = os.path.join(out, f"{name}.m4a")
        build(key, lines, path)
        dur = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", path],
                             capture_output=True, text=True).stdout.strip()
        print(f"{path}: {os.path.getsize(path)} bytes, {float(dur):.1f} s")


if __name__ == "__main__":
    main()
