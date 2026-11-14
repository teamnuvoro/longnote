import '../audio/wav.dart';
import '../config.dart';
import '../models/recording.dart';
import 'transcriber.dart';

/// Deterministic transcriber for tests and the simulator. Emits one line per
/// 30 s of audio. Can be told to fail N times to exercise retries.
class FakeTranscriber implements Transcriber {
  FakeTranscriber({this.failTimes = 0, this.lines});

  int failTimes;
  int calls = 0;

  /// Optional fixed text per call (cycled).
  final List<String>? lines;

  @override
  String get name => 'fake';

  @override
  Future<void> ensureReady({void Function(double progress)? onProgress}) async {
    onProgress?.call(1);
  }

  @override
  Future<bool> isReady() async => true;

  @override
  Future<void> releaseResources() async {}

  @override
  Future<List<TranscriptLine>> transcribeFile(String wavPath,
      {required int offsetMs, required int segmentIndex}) async {
    calls++;
    if (failTimes > 0) {
      failTimes--;
      throw TranscriptionException('fake failure');
    }
    final bytes = wavDataBytesFromLength(wavPath);
    final ms = bytes * 1000 ~/ AppConfig.bytesPerSecond;
    final out = <TranscriptLine>[];
    var i = 0;
    for (var t = 0; t < ms || (t == 0 && ms > 0); t += 30000) {
      final end = (t + 30000) > ms ? ms : t + 30000;
      final text = lines == null
          ? 'Fake transcript line ${i + 1} of part ${segmentIndex + 1}.'
          : lines![(i) % lines!.length];
      out.add(TranscriptLine(
          startMs: offsetMs + t,
          endMs: offsetMs + end,
          text: text,
          segmentIndex: segmentIndex));
      i++;
      if (end >= ms) break;
    }
    return out;
  }
}
