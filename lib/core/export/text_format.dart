import '../models/recording.dart';
import '../util/clock.dart';

String formatTimestamp(int ms) => formatDuration(Duration(milliseconds: ms));

/// "[00:12] text" lines. Used for copy/share and as LLM input (timestamps help
/// the model keep order; they are cheap).
String transcriptToText(List<TranscriptLine> lines, {bool timestamps = true}) {
  final b = StringBuffer();
  for (final l in lines) {
    final who = l.speaker == null ? '' : '${l.speaker}: ';
    b.writeln(timestamps ? '[${formatTimestamp(l.startMs)}] $who${l.text}' : '$who${l.text}');
  }
  return b.toString().trimRight();
}
