import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/recording.dart';
import '../summary/summary_models.dart';
import '../util/clock.dart';
import 'text_format.dart';

/// Fonts are passed in (loaded from assets in the app, from disk in tests)
/// so Unicode text (names, Hindi, currency signs) renders correctly.
class PdfFonts {
  PdfFonts({required this.regular, required this.bold, this.fallback = const []});
  final pw.Font regular;
  final pw.Font bold;
  final List<pw.Font> fallback;

  static PdfFonts fromBytes(ByteData regular, ByteData bold,
          {List<ByteData> fallback = const []}) =>
      PdfFonts(
        regular: pw.Font.ttf(regular),
        bold: pw.Font.ttf(bold),
        fallback: [for (final f in fallback) pw.Font.ttf(f)],
      );
}

/// Basic, clean PDF: title, date/length, summary sections, full transcript.
Future<Uint8List> buildRecordingPdf({
  required Recording recording,
  required MeetingSummary? summary,
  required List<TranscriptLine> transcript,
  required PdfFonts fonts,
  String? summaryNote,
}) async {
  final theme = pw.ThemeData.withFont(
    base: fonts.regular,
    bold: fonts.bold,
    fontFallback: fonts.fallback,
  );
  final doc = pw.Document(
    theme: theme,
    title: recording.title,
    creator: 'Longnote',
  );

  pw.Widget h(String t) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 14, bottom: 6),
        child: pw.Text(t,
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
      );
  pw.Widget bullet(String t) => pw.Bullet(
      text: t, style: const pw.TextStyle(fontSize: 11, lineSpacing: 2));

  final created = recording.createdAt;
  final meta =
      '${created.day}/${created.month}/${created.year}  ·  ${formatMinutes(recording.duration)}'
      '${recording.note == null ? '' : '  ·  ${recording.note}'}';

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(40),
    footer: (ctx) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
    ),
    build: (ctx) => [
      pw.Text(recording.title,
          style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      pw.Text(meta,
          style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
      if (summary != null) ...[
        if (summaryNote != null)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 8),
            child: pw.Text(summaryNote,
                style: const pw.TextStyle(
                    fontSize: 9, color: PdfColors.grey700)),
          ),
        if (summary.keyPoints.isNotEmpty) ...[
          h('Key points'),
          ...summary.keyPoints.map(bullet)
        ],
        if (summary.decisions.isNotEmpty) ...[
          h('Decisions'),
          ...summary.decisions.map(bullet)
        ],
        if (summary.actionItems.isNotEmpty) ...[
          h('Action items'),
          ...summary.actionItems.map((a) => bullet([
                a.task,
                if (a.owner != null) 'Owner: ${a.owner}',
                if (a.due != null) 'Due: ${a.due}',
              ].join('  ·  '))),
        ],
        if (summary.numbersAndDates.isNotEmpty) ...[
          h('Numbers and dates'),
          ...summary.numbersAndDates.map(bullet)
        ],
        if (summary.openQuestions.isNotEmpty) ...[
          h('Open questions'),
          ...summary.openQuestions.map(bullet)
        ],
      ],
      h('Transcript'),
      if (transcript.isEmpty)
        pw.Text('No transcript yet.', style: const pw.TextStyle(fontSize: 11)),
      ...transcript.map((l) => pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 4),
            child: pw.RichText(
                text: pw.TextSpan(children: [
              pw.TextSpan(
                  text: '${formatTimestamp(l.startMs)}  ',
                  style: const pw.TextStyle(
                      fontSize: 9, color: PdfColors.grey600)),
              pw.TextSpan(
                  text: l.text, style: const pw.TextStyle(fontSize: 11)),
            ])),
          )),
    ],
  ));
  return doc.save();
}
