#!/usr/bin/env python3
"""Phone-sized PDF of a simulator QA run (the ios-sim-qa artifact).

Usage: python3 tools/qa/make_report.py QA_OUT_DIR OUT.pdf [--bugs BUGS.json]
BUGS.json (optional): [{"title": ..., "evidence": ..., "status": ...}] for app
bugs found while building the suite.
"""
import argparse
import io
import json
import os
import re
import tempfile
from datetime import datetime

from PIL import Image as PILImage
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.platypus import (Image, KeepTogether, PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table,
                                TableStyle)

W, H = 105 * mm, 190 * mm  # phone-shaped page (same as docs/Longnote-device-test-v1.pdf)
CW = W - 14 * mm
ink = colors.HexColor("#15171C")
red = colors.HexColor("#E4472B")
green = colors.HexColor("#1F8A4C")
grey = colors.HexColor("#6B6B6B")
line = colors.HexColor("#DDDAD2")
T = ParagraphStyle("t", fontName="Helvetica-Bold", fontSize=17, leading=21, textColor=ink, spaceAfter=4)
S = ParagraphStyle("s", fontName="Helvetica", fontSize=10, leading=13, textColor=grey, spaceAfter=6)
Hd = ParagraphStyle("h", fontName="Helvetica-Bold", fontSize=13, leading=16, textColor=red, spaceBefore=10,
                    spaceAfter=4)
B = ParagraphStyle("b", fontName="Helvetica", fontSize=10.5, leading=14, textColor=ink)
N = ParagraphStyle("n", fontName="Helvetica", fontSize=8.5, leading=11, textColor=grey)
E = ParagraphStyle("e", fontName="Helvetica", fontSize=9, leading=12, textColor=red)
BIG = ParagraphStyle("big", fontName="Helvetica-Bold", fontSize=26, leading=30, spaceBefore=4, spaceAfter=4)

NOT_COVERED = [
    "Lock screen for 10 minutes while recording (the simulator has no real lock/background audio session).",
    "A real phone call during a recording (no calls in the simulator).",
    "The real microphone: audio comes from a file through the same recorder, disk writer and pipeline.",
    "iOS permission prompts (microphone, notifications): system alerts a Flutter test cannot tap. The runs take "
    "\"Skip\" / \"Not now\".",
    "The iOS share sheet itself: the app's files and texts are checked where they are handed to iOS.",
    "The iOS Files picker: the import starts from a file handed in by the test, then runs for real.",
    "Battery, heat, speed and the feel of a real iPhone; very long (1-3 h) recordings.",
    "Real App Store purchases (billing is simulated in v1 anyway).",
]


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def badge(status):
    c = {"PASS": green, "FAIL": red}.get(status, grey)
    t = Table([[status]], colWidths=[13 * mm], rowHeights=[5.5 * mm])
    t.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), c), ("TEXTCOLOR", (0, 0), (-1, -1), colors.white),
                           ("FONTNAME", (0, 0), (-1, -1), "Helvetica-Bold"), ("FONTSIZE", (0, 0), (-1, -1), 8),
                           ("ALIGN", (0, 0), (-1, -1), "CENTER"), ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                           ("TOPPADDING", (0, 0), (-1, -1), 0), ("BOTTOMPADDING", (0, 0), (-1, -1), 1)]))
    return t


_tmp = tempfile.mkdtemp(prefix="qa_pdf_")


def shot(path, width):
    """Downscaled JPEG of a screenshot, as a reportlab Image of [width]."""
    im = PILImage.open(path).convert("RGB")
    w, h = im.size
    im.thumbnail((520, 1200))
    out = os.path.join(_tmp, re.sub(r"[^\w.-]", "_", path)[-80:] + ".jpg")
    im.save(out, "JPEG", quality=72)
    return Image(out, width=width, height=width * h / w)


def shots_row(paths):
    if not paths:
        return []
    per = 3 if len(paths) >= 3 else len(paths)
    width = (CW - 4 * mm * (per - 1)) / per if per > 1 else CW * 0.5
    rows, cur = [], []
    for p in paths:
        cur.append(shot(p, width))
        if len(cur) == per:
            rows.append(cur)
            cur = []
    if cur:
        rows.append(cur + [""] * (per - len(cur)))
    t = Table(rows, colWidths=[width + (4 * mm if i < per - 1 else 0) for i in range(per)])
    t.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 0),
                           ("RIGHTPADDING", (0, 0), (-1, -1), 0), ("BOTTOMPADDING", (0, 0), (-1, -1), 3)]))
    return [t]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("qa_out")
    ap.add_argument("pdf")
    ap.add_argument("--bugs")
    ap.add_argument("--title", default="Longnote: simulator test report")
    a = ap.parse_args()
    summ = json.load(open(os.path.join(a.qa_out, "summary.json")))
    bugs = json.load(open(a.bugs)) if a.bugs else []

    doc = SimpleDocTemplate(a.pdf, pagesize=(W, H), leftMargin=7 * mm, rightMargin=7 * mm, topMargin=8 * mm,
                            bottomMargin=8 * mm, title=a.title)
    s = [Paragraph(a.title, T)]
    meta = [datetime.now().strftime("%d %b %Y")]
    if summ.get("device"):
        meta.append(esc(re.sub(r"\s*\([0-9A-F-]{36}\)", "", summ["device"])) + " (iOS Simulator)")
    if summ.get("commit"):
        meta.append("commit " + summ["commit"][:7])
    s.append(Paragraph(" · ".join(meta), S))
    c = summ["counts"]
    v = summ["verdict"]
    s.append(Paragraph(f'<font color="{"#1F8A4C" if v == "PASS" else "#E4472B"}">{v}</font>', BIG))
    s.append(Paragraph(f"{c['PASS']} checks passed, {c['FAIL']} failed, {c['SKIP']} skipped.", B))
    s.append(Spacer(1, 4))
    s.append(Paragraph(
        "The real Longnote app ran in an iPhone simulator on a cloud Mac, against the real server (transcription "
        "and summaries for real). A test played a 2-voice meeting into the recorder and tapped through the app "
        "like a person. It was opened up to 5 times: a first run, a force-quit while recording, a restart after it, "
        "a run with the server cut off, and an extra run (simulated phone calls, 10 min in the background while "
        "recording, a 1-hour recording). Any error on screen, layout overflow, crash or freeze fails the check.", B))
    if summ.get("run_url"):
        s.append(Spacer(1, 3))
        s.append(Paragraph("Run: " + esc(summ["run_url"]), N))

    if summ["problems"] or bugs:
        s.append(Paragraph("Problems found", Hd))
        for p in summ["problems"]:
            s.append(Paragraph("• " + esc(p), E))
        for b in bugs:
            s.append(Paragraph(f"<b>{esc(b['title'])}</b> ({esc(b.get('status', 'open'))})", B))
            s.append(Paragraph(esc(b["evidence"]), N))
            s.append(Spacer(1, 3))

    for r in summ["runs"]:
        s.append(PageBreak())
        s.append(Paragraph(f"Launch {r['name'][0]}: {esc(r['title'])}", Hd))
        extra = []
        if r.get("audio_seconds_sent"):
            extra.append(f"{r['audio_seconds_sent']} s of audio played")
        if r["name"] == "2-kill":
            extra.append("this launch ends by force-quit on purpose")
        if extra:
            s.append(Paragraph(", ".join(extra) + ".", S))
        for p in r["problems"]:
            s.append(Paragraph("• " + esc(p), E))
        last_section = None
        for ch in r["checks"]:
            if ch["section"] != last_section:
                last_section = ch["section"]
                s.append(Paragraph(esc(last_section), ParagraphStyle("sec", parent=B, fontName="Helvetica-Bold",
                                                                     spaceBefore=6, spaceAfter=2)))
            head = Table([[badge(ch["status"]), Paragraph(f"<b>{esc(ch['id'])}</b> {esc(ch['title'])}", B)]],
                         colWidths=[15 * mm, CW - 15 * mm])
            head.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 0),
                                      ("BOTTOMPADDING", (0, 0), (-1, -1), 2)]))
            block = [head]
            if ch.get("error"):
                block.append(Paragraph("What happened: " + esc(ch["error"][:700]), E))
            # Kept short: one check must fit on a phone-sized page.
            for n in ch.get("notes", [])[:4]:
                block.append(Paragraph(esc(n[:220] + ("…" if len(n) > 220 else "")), N))
            took = f"{ch['ms'] / 1000:.1f} s"
            if ch.get("max_frame_wait_ms"):
                took += f" · slowest frame {ch['max_frame_wait_ms']} ms"
            block.append(Paragraph(took, N))
            paths = [os.path.join(a.qa_out, "shots", p) for p in ch.get("shots", [])]
            paths = [p for p in paths if os.path.exists(p)]
            if ch["status"] == "PASS" and len(paths) > 3:
                paths = paths[-3:]
            block += shots_row(paths)
            block.append(Spacer(1, 2))
            t = Table([[block]], colWidths=[CW])
            t.setStyle(TableStyle([("LEFTPADDING", (0, 0), (-1, -1), 0), ("RIGHTPADDING", (0, 0), (-1, -1), 0),
                                   ("LINEBELOW", (0, 0), (-1, -1), 0.3, line), ("BOTTOMPADDING", (0, 0), (-1, -1), 4)]))
            s.append(t)
        hang_png = os.path.join(a.qa_out, "shots", r["name"], "99-HANG-simulator.png")
        if os.path.exists(hang_png):
            s.append(Paragraph("Screen when the hang was detected:", E))
            s += shots_row([hang_png])
        if r["app_errors"]:
            s.append(Paragraph("App errors in this launch", ParagraphStyle("ae", parent=B, fontName="Helvetica-Bold",
                                                                          spaceBefore=6)))
            for e in r["app_errors"][:12]:
                s.append(Paragraph(f"{esc(e.get('check'))}: {esc(e.get('kind'))}: {esc(e.get('text', '')[:400])}", N))

    s.append(PageBreak())
    s.append(Paragraph("Not covered by the simulator", Hd))
    s.append(Paragraph("Still needs the iPhone (docs/DEVICE-TEST-V1.md):", S))
    for n in NOT_COVERED:
        s.append(Paragraph("• " + esc(n), B))
        s.append(Spacer(1, 2))
    if summ.get("crash_reports"):
        s.append(Paragraph("Crash reports", Hd))
        for cr in summ["crash_reports"]:
            s.append(Paragraph(esc(cr), N))
    doc.build(s)
    print(a.pdf, os.path.getsize(a.pdf) // 1024, "KB")


if __name__ == "__main__":
    main()
