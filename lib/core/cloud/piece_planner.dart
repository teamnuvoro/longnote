/// One audio file that is part of a note (a 5-minute WAV part, or an
/// imported file), in order.
class AudioInput {
  const AudioInput(this.file, this.durationMs);

  /// Path relative to the note folder.
  final String file;
  final int durationMs;
}

/// What one upload/transcription job covers.
class PiecePlan {
  const PiecePlan({
    required this.index,
    required this.inputs,
    required this.rangeStartMs,
    required this.startMs,
    required this.durationMs,
  });

  final int index;

  /// Files to join for this piece (only the ones that overlap it).
  final List<String> inputs;

  /// Where the piece starts inside the join of [inputs].
  final int rangeStartMs;

  /// Where the piece starts in the whole note (added to turn times).
  final int startMs;
  final int durationMs;
}

/// Soniox transcribes at most 5 h per file (BACKEND-API 7). Notes up to
/// [maxSingleMs] are one piece; longer notes are cut into [pieceMs] pieces
/// (4 h) that are transcribed separately and stitched by time offset.
List<PiecePlan> planPieces(
  List<AudioInput> inputs, {
  int maxSingleMs = 5 * 3600 * 1000,
  int pieceMs = 4 * 3600 * 1000,
}) {
  final files = inputs.where((i) => i.durationMs > 0).toList();
  final total = files.fold<int>(0, (a, i) => a + i.durationMs);
  if (total <= 0) return const [];
  if (total <= maxSingleMs) {
    return [
      PiecePlan(
          index: 0,
          inputs: [for (final f in files) f.file],
          rangeStartMs: 0,
          startMs: 0,
          durationMs: total)
    ];
  }
  final out = <PiecePlan>[];
  for (var start = 0, k = 0; start < total; start += pieceMs, k++) {
    final end = (start + pieceMs) > total ? total : start + pieceMs;
    final used = <String>[];
    int? firstStart;
    var cursor = 0;
    for (final f in files) {
      final fEnd = cursor + f.durationMs;
      if (fEnd > start && cursor < end) {
        used.add(f.file);
        firstStart ??= cursor;
      }
      cursor = fEnd;
    }
    out.add(PiecePlan(
      index: k,
      inputs: used,
      rangeStartMs: start - (firstStart ?? 0),
      startMs: start,
      durationMs: end - start,
    ));
  }
  return out;
}
