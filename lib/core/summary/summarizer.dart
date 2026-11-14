import 'summary_models.dart';

/// Shared instructions for every LLM-based summarizer (Apple on-device and the
/// cloud backend use the same wording; keep supabase/functions/summarize in
/// sync).
const String summaryInstructions = '''
You turn a meeting, lecture or talk transcript into notes.
Return ONLY a JSON object with exactly these keys:
{"key_points": [string], "decisions": [string],
 "action_items": [{"task": string, "owner": string or null, "due": string or null}],
 "numbers_and_dates": [string], "open_questions": [string]}
Rules:
- Keep people's names, numbers, amounts, dates, deadlines, votes and motions exactly as said.
- A decision is something the group agreed, approved, voted or settled. Include who moved or seconded a motion and the vote result when stated.
- Only fill "owner" when the transcript says who will do it. Only fill "due" when a date or deadline is said. Otherwise use null. Never invent an owner or a date.
- Do not add facts that are not in the transcript. If a list has nothing, return [].
- Write short, plain sentences in the language of the transcript.
- The transcript may come from speech recognition and contain errors; do not "fix" names or numbers by guessing.''';

/// Builds the user message for one chunk.
String summaryUserPrompt(String chunk, {int? part, int? parts}) {
  final header = (part != null && parts != null && parts > 1)
      ? 'This is part $part of $parts of a long transcript. Summarize only this part.\n\n'
      : '';
  return '${header}Transcript:\n$chunk';
}

/// Interface for every summary engine.
abstract class Summarizer {
  /// Stable id stored with the summary ("apple", "cloud", "local").
  String get id;

  /// Human label shown in the UI.
  String get label;

  /// Max characters per chunk this engine can take in one call.
  int get maxChunkChars;

  Future<bool> isAvailable();

  /// Summarizes one chunk (already sized to [maxChunkChars]).
  Future<MeetingSummary> summarizeChunk(String chunk,
      {required int part, required int parts});
}

/// Splits a transcript into chunks of at most [maxChars], breaking on line
/// boundaries (lines carry timestamps) and, for over-long lines, on sentence
/// or word boundaries.
List<String> chunkTranscript(String text, int maxChars) {
  assert(maxChars > 50);
  final out = <String>[];
  final buf = StringBuffer();
  void flush() {
    if (buf.isNotEmpty) {
      out.add(buf.toString().trim());
      buf.clear();
    }
  }

  for (final rawLine in text.split('\n')) {
    final pieces = rawLine.length <= maxChars
        ? [rawLine]
        : _splitLong(rawLine, maxChars);
    for (final line in pieces) {
      if (buf.length + line.length + 1 > maxChars) flush();
      buf.writeln(line);
    }
  }
  flush();
  return out.where((c) => c.isNotEmpty).toList();
}

List<String> _splitLong(String line, int maxChars) {
  final out = <String>[];
  var rest = line;
  while (rest.length > maxChars) {
    var cut = rest.lastIndexOf(RegExp(r'[.!?]\s'), maxChars - 1);
    if (cut < maxChars ~/ 2) cut = rest.lastIndexOf(' ', maxChars - 1);
    if (cut < maxChars ~/ 4) cut = maxChars - 1;
    out.add(rest.substring(0, cut + 1).trim());
    rest = rest.substring(cut + 1).trimLeft();
  }
  if (rest.isNotEmpty) out.add(rest);
  return out;
}

/// Long transcripts: chunk -> summarize each chunk -> merge.
Future<MeetingSummary> summarizeLong(Summarizer s, String transcript,
    {void Function(int done, int total)? onProgress}) async {
  final chunks = chunkTranscript(transcript, s.maxChunkChars);
  if (chunks.isEmpty) return const MeetingSummary();
  final parts = <MeetingSummary>[];
  for (var i = 0; i < chunks.length; i++) {
    onProgress?.call(i, chunks.length);
    parts.add(
        await s.summarizeChunk(chunks[i], part: i + 1, parts: chunks.length));
  }
  onProgress?.call(chunks.length, chunks.length);
  return parts.length == 1 ? parts.first : MeetingSummary.merge(parts);
}
