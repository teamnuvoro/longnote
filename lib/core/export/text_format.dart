import '../models/recording.dart';
import '../util/clock.dart';

String formatTimestamp(int ms) => formatDuration(Duration(milliseconds: ms));

/// "[00:12] text" lines. Used for copy/share and as LLM input (timestamps help
/// the model keep order; they are cheap). [names] maps speaker keys to the
/// display names (speakers table); unknown keys print as `Speaker <key>`.
String transcriptToText(List<TranscriptLine> lines,
    {bool timestamps = true, Map<String, String>? names}) {
  final b = StringBuffer();
  for (final l in lines) {
    final k = l.speaker;
    final who = k == null
        ? ''
        : '${names == null ? k : (names[k] ?? 'Speaker $k')}: ';
    b.writeln(timestamps ? '[${formatTimestamp(l.startMs)}] $who${l.text}' : '$who${l.text}');
  }
  return b.toString().trimRight();
}
