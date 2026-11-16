import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../analytics/analytics.dart';
import '../audio/wav.dart';
import '../cloud/audio_encoder.dart';
import '../models/recording.dart';
import '../recording/recording_repository.dart';
import '../summary/summary_models.dart';
import 'pdf_exporter.dart';
import 'text_format.dart';

/// Copy / share / export. Every export logs a local `export` event.
class ShareService {
  ShareService({
    required this.repo,
    required this.analytics,
    this.encoder = const NativeAudioEncoder(),
  });
  final RecordingRepository repo;
  final Analytics analytics;

  /// AAC encoder for the M4A audio export (D5).
  final AudioEncoder encoder;

  PdfFonts? _fonts;

  Future<PdfFonts> _loadFonts() async => _fonts ??= PdfFonts.fromBytes(
        await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
        await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'),
        fallback: [
          await rootBundle.load('assets/fonts/NotoSansDevanagari-Regular.ttf')
        ],
      );

  static String safeFileName(String title) {
    final s = title.replaceAll(RegExp(r'[^\w\- ]+'), '').trim();
    return s.isEmpty ? 'Recording' : s;
  }

  Future<void> copyText(String text, String kind, String recordingId) async {
    await Clipboard.setData(ClipboardData(text: text));
    await analytics.log(AnalyticsEvent.export,
        recordingId: recordingId, props: {'kind': kind, 'via': 'copy'});
  }

  Future<void> shareText(String text, String kind, Recording r,
      {Rect? origin}) async {
    await SharePlus.instance.share(ShareParams(
        text: text, subject: r.title, sharePositionOrigin: origin));
    await analytics.log(AnalyticsEvent.export,
        recordingId: r.id, props: {'kind': kind, 'via': 'share'});
  }

  /// [speakerNames] (key -> name) prints names before each turn; null
  /// leaves them out (D5 "Include speaker names" off).
  Future<void> sharePdf(Recording r,
      {MeetingSummary? summary,
      String? note,
      Rect? origin,
      Map<String, String>? speakerNames}) async {
    final bytes = await buildRecordingPdf(
      recording: r,
      summary: summary,
      summaryNote: note,
      transcript: await repo.transcript(r.id),
      fonts: await _loadFonts(),
      speakerNames: speakerNames,
    );
    final dir = await getTemporaryDirectory();
    final f = File(p.join(dir.path, '${safeFileName(r.title)}.pdf'));
    await f.writeAsBytes(bytes, flush: true);
    await SharePlus.instance.share(ShareParams(
        files: [XFile(f.path, mimeType: 'application/pdf')],
        subject: r.title,
        sharePositionOrigin: origin));
    await analytics.log(AnalyticsEvent.export,
        recordingId: r.id, props: {'kind': 'pdf', 'via': 'share'});
  }

  /// Joins the 5-minute parts into one WAV in the temp folder and shares it.
  /// The original parts are untouched.
  Future<void> shareAudio(Recording r, {Rect? origin}) async {
    final parts = await repo.segmentPaths(r.id);
    final dir = await getTemporaryDirectory();
    final out = p.join(dir.path, '${safeFileName(r.title)}.wav');
    await concatWavs(parts, out);
    await SharePlus.instance.share(ShareParams(
        files: [XFile(out, mimeType: 'audio/wav')],
        subject: r.title,
        sharePositionOrigin: origin));
    await analytics.log(AnalyticsEvent.export,
        recordingId: r.id, props: {'kind': 'audio', 'via': 'share'});
    // Temp copy can be large (115 MB/hour); remove it after the sheet closes.
    try {
      File(out).deleteSync();
    } catch (_) {}
  }

  /// Encodes the parts to one AAC .m4a in the temp folder and shares it
  /// (about 15 MB per hour). The original parts are untouched.
  Future<void> shareAudioM4a(Recording r, {Rect? origin}) async {
    final parts = await repo.segmentPaths(r.id);
    final dir = await getTemporaryDirectory();
    final out = p.join(dir.path, '${safeFileName(r.title)}.m4a');
    await encoder.encodeM4a(inputs: parts, output: out);
    await SharePlus.instance.share(ShareParams(
        files: [XFile(out, mimeType: 'audio/mp4')],
        subject: r.title,
        sharePositionOrigin: origin));
    await analytics.log(AnalyticsEvent.export,
        recordingId: r.id, props: {'kind': 'audio_m4a', 'via': 'share'});
    try {
      File(out).deleteSync();
    } catch (_) {}
  }

  /// Plain transcript; [names] null = no speaker labels.
  String transcriptText(List<TranscriptLine> lines, {Map<String, String>? names}) =>
      names == null
          ? transcriptToText([
              for (final l in lines)
                TranscriptLine(
                    startMs: l.startMs,
                    endMs: l.endMs,
                    text: l.text,
                    segmentIndex: l.segmentIndex)
            ])
          : transcriptToText(lines, names: names);
}
