import '../export/text_format.dart';
import '../recording/recording_repository.dart';
import '../summary/summary_service.dart';
import '../transcription/transcriber.dart';

/// Transcribe every untranscribed segment, then summarize. Resumable: each
/// segment's transcript is saved as soon as it is done, so a retry continues
/// where the last attempt stopped. Reads audio; never writes or deletes it.
class ProcessingPipeline {
  ProcessingPipeline({
    required this.repo,
    required this.transcriber,
    required this.summaries,
  });

  final RecordingRepository repo;
  final Transcriber Function() transcriber;
  final SummaryService summaries;

  Future<void> process(
      String recordingId, void Function(String) onProgress) async {
    final segs = (await repo.segments(recordingId))
        .where((s) => s.dataBytes > 0)
        .toList();
    final t = transcriber();

    if (segs.any((s) => !s.transcribed)) {
      if (!await t.isReady()) {
        onProgress('Downloading speech model');
        await t.ensureReady(
            onProgress: (p) =>
                onProgress('Downloading speech model ${(p * 100).round()}%'));
      }
      var offset = 0;
      for (var i = 0; i < segs.length; i++) {
        final s = segs[i];
        if (!s.transcribed) {
          onProgress('Transcribing part ${i + 1} of ${segs.length}');
          final lines = await t.transcribeFile(
              repo.storage.segmentPath(recordingId, s.fileName),
              offsetMs: offset,
              segmentIndex: s.index);
          await repo.saveSegmentTranscript(recordingId, s.index, lines);
        }
        offset += s.durationMs;
      }
    }

    onProgress('Writing summary');
    final text = transcriptToText(await repo.transcript(recordingId));
    final outcome = await summaries.summarize(text, onProgress: onProgress);
    await repo.saveSummary(recordingId, outcome.summary.encode(), outcome.engineId,
        note: outcome.note ??
            (text.trim().isEmpty ? 'No speech was found in this recording.' : null));
  }
}
