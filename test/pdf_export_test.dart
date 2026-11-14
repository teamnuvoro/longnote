import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/export/pdf_exporter.dart';
import 'package:longnote/core/export/text_format.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/summary/summary_models.dart';

ByteData _font(String name) =>
    ByteData.sublistView(File('assets/fonts/$name').readAsBytesSync());

void main() {
  test('builds a PDF with summary + transcript, incl. Hindi and Rs sign',
      () async {
    final fonts = PdfFonts.fromBytes(
        _font('NotoSans-Regular.ttf'), _font('NotoSans-Bold.ttf'),
        fallback: [_font('NotoSansDevanagari-Regular.ttf')]);
    final bytes = await buildRecordingPdf(
      recording: Recording(
          id: 'r', title: 'Board meeting — Q3', createdAt: DateTime(2026, 11, 15),
          status: RecordingStatus.completed, durationMs: 3600000),
      summary: const MeetingSummary(
        keyPoints: ['Revenue ₹4.2 crore'],
        decisions: ['बजट मंज़ूर'],
        actionItems: [ActionItem(task: 'Send minutes', owner: 'Asha', due: 'Friday')],
      ),
      transcript: List.generate(400, (i) => TranscriptLine(
          startMs: i * 5000, endMs: i * 5000 + 4000, text: 'Line $i of the meeting.')),
      fonts: fonts,
    );
    expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
    expect(bytes.length, greaterThan(10000));
  });

  test('transcript text format', () {
    final t = transcriptToText([
      TranscriptLine(startMs: 0, endMs: 1000, text: 'Hello'),
      TranscriptLine(startMs: 3725000, endMs: 3726000, text: 'Later'),
    ]);
    expect(t, '[00:00] Hello\n[1:02:05] Later');
  });
}
