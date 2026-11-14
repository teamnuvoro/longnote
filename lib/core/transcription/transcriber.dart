import '../models/recording.dart';

class TranscriptionException implements Exception {
  TranscriptionException(this.message);
  final String message;
  @override
  String toString() => 'Transcription failed: $message';
}

/// Model download / readiness, reported to the UI.
class ModelStatus {
  const ModelStatus({
    required this.ready,
    this.downloading = false,
    this.progress = 0,
    this.error,
    this.sizeLabel,
  });
  final bool ready;
  final bool downloading;

  /// 0..1 while downloading.
  final double progress;
  final String? error;
  final String? sizeLabel;
}

/// Turns one WAV file (16 kHz mono PCM16) into timed lines.
///
/// [offsetMs] is the position of this file within the whole recording so
/// returned timestamps are recording-relative.
abstract class Transcriber {
  String get name;

  /// Download the model if needed. [onProgress] gets 0..1.
  Future<void> ensureReady({void Function(double progress)? onProgress});

  Future<bool> isReady();

  Future<List<TranscriptLine>> transcribeFile(
    String wavPath, {
    required int offsetMs,
    required int segmentIndex,
  });

  /// Free model memory after a whole recording is done.
  Future<void> releaseResources();
}
