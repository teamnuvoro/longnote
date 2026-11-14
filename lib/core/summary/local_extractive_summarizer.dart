import 'summarizer.dart';
import 'summary_models.dart';

/// Offline fallback that always works: picks sentences from the transcript
/// with simple rules. It never writes new words, so it cannot invent owners
/// or dates; it is much weaker than an LLM summary and the UI says so.
class LocalExtractiveSummarizer implements Summarizer {
  LocalExtractiveSummarizer({this.maxKeyPoints = 7});

  final int maxKeyPoints;

  @override
  String get id => 'local';

  @override
  String get label => 'Basic offline summary';

  /// Works on any length in one go (pure Dart, linear time).
  @override
  int get maxChunkChars => 1 << 30;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<MeetingSummary> summarizeChunk(String chunk,
          {required int part, required int parts}) async =>
      summarizeText(chunk);

  static final _timestamp = RegExp(r'^\s*\[?\d{1,2}:\d{2}(?::\d{2})?\]?\s*');

  static final _decisionCue = RegExp(
      r"\b(we (have )?decided|decided to|decision is|agreed|we agree|approved|"
      r"motion (passed|carried|failed)|voted|resolved|we('ll| will) go with|"
      r"final(ly)? (call|answer)|settled on|signed off)\b",
      caseSensitive: false);

  static final _actionCue = RegExp(
      r"\b(will|'ll|is going to|needs? to|has to|have to|must|should|"
      r"action item|to-?do|follow up|take care of|responsible for|assign(ed)?)\b",
      caseSensitive: false);

  /// "Ravi will send the deck", "Priya, can you ..." -> owner only when a
  /// capitalised name is directly the subject of the commitment.
  static final _ownerWill = RegExp(
      r"\b([A-Z][a-z]+(?: [A-Z][a-z]+)?)(?: will|'ll| is going to| needs to| has to| to)\b");
  static final _ownerAsk =
      RegExp(r"^\s*([A-Z][a-z]+),? (?:can|could|would|please) you\b");

  static const _notNames = {
    'I', 'We', 'You', 'They', 'He', 'She', 'It', 'This', 'That', 'There',
    'Someone', 'Everyone', 'Somebody', 'Nobody', 'Who', 'What', 'So', 'And',
    'But', 'Then', 'Also', 'Okay', 'OK', 'Yes', 'No', 'Next', 'The', 'Our',
    'Let', 'Maybe', 'Now', 'Well', 'Just', 'If', 'When',
  };

  static const _months =
      r'(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)';
  static const _days =
      r'(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tue|wed|thu|fri|sat|sun)';

  static final _due = RegExp(
      r"\b(?:by|before|on|due|until|no later than)\s+("
      "(?:next |this )?$_days|"
      "(?:the )?\\d{1,2}(?:st|nd|rd|th)?(?: of)? $_months(?: \\d{4})?|"
      "$_months \\d{1,2}(?:st|nd|rd|th)?(?:,? \\d{4})?|"
      r"\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?|"
      r"tomorrow|tonight|today|end of (?:the )?(?:day|week|month|quarter|year)|"
      r"next (?:week|month|quarter)|eod|eow)\b",
      caseSensitive: false);

  static final _numberOrDate = RegExp(
      "(\\d|\\\$|₹|€|£|%|\\b$_months\\b|\\b$_days\\b|"
      r"\b(?:tomorrow|yesterday|next week|next month|quarter|deadline)\b|"
      r"\b(?:lakh|crore|million|billion|thousand|hundred)\b)",
      caseSensitive: false);

  static const _stop = {
    'the', 'a', 'an', 'and', 'or', 'but', 'so', 'to', 'of', 'in', 'on', 'at',
    'for', 'with', 'is', 'are', 'was', 'were', 'be', 'been', 'it', 'this',
    'that', 'we', 'i', 'you', 'they', 'he', 'she', 'our', 'your', 'my', 'me',
    'us', 'them', 'do', 'did', 'does', 'have', 'has', 'had', 'will', 'would',
    'can', 'could', 'should', 'just', 'like', 'yeah', 'okay', 'ok', 'um',
    'uh', 'right', 'know', 'think', 'going', 'get', 'got', 'there', 'what',
    'about', 'not', 'if', 'then', 'also', 'from', 'as', 'all', 'some', 'one',
    'really', 'very', 'gonna', 'kind', 'sort', 'mean', 'well', 'actually',
    'thing', 'things', 'lot', 'yes', 'no', 'now', 'here', 'when', 'which',
    'who', 'how', 'why', 'into', 'out', 'up', 'down', 'more', 'than', 'its',
    "it's", "that's", "i'm", "we're", "don't", 'by', 'any', 'want', 'need',
  };

  MeetingSummary summarizeText(String transcript) {
    final sentences = splitSentences(transcript);
    if (sentences.isEmpty) return const MeetingSummary();

    final decisions = <String>[];
    final actions = <ActionItem>[];
    final numbers = <String>[];
    final questions = <String>[];

    for (final s in sentences) {
      if (s.endsWith('?')) {
        if (_wordCount(s) >= 4) questions.add(s);
        continue;
      }
      if (_decisionCue.hasMatch(s)) {
        decisions.add(s);
      } else if (_actionCue.hasMatch(s) && _looksLikeCommitment(s)) {
        actions.add(ActionItem(task: s, owner: _owner(s), due: _dueOf(s)));
      }
      if (_numberOrDate.hasMatch(s) && _wordCount(s) >= 4) numbers.add(s);
    }

    return MeetingSummary(
      keyPoints: _keyPoints(sentences),
      decisions: _cap(decisions, 15),
      actionItems: actions.length > 20 ? actions.sublist(0, 20) : actions,
      numbersAndDates: _cap(numbers, 15),
      openQuestions: _cap(questions, 10),
    );
  }

  static List<String> splitSentences(String transcript) {
    final cleaned = transcript
        .split('\n')
        .map((l) => l.replaceFirst(_timestamp, '').trim())
        .where((l) => l.isNotEmpty)
        .join(' ');
    final parts = cleaned.split(RegExp(r'(?<=[.!?])\s+'));
    return parts
        .map((s) => s.trim())
        .where((s) => s.length > 2 && _wordCount(s) >= 3)
        .toList();
  }

  static int _wordCount(String s) =>
      s.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

  static bool _looksLikeCommitment(String s) {
    // Skip hypotheticals and past tense chatter.
    final l = s.toLowerCase();
    if (l.startsWith('if ') || l.contains('would have') || l.contains('i think it will')) {
      return false;
    }
    return _ownerWill.hasMatch(s) ||
        _ownerAsk.hasMatch(s) ||
        RegExp(r"\b(i|we)('ll| will| need to| have to| should)\b",
                caseSensitive: false)
            .hasMatch(s) ||
        RegExp(r'\b(action item|to-?do|follow up)\b', caseSensitive: false)
            .hasMatch(s);
  }

  static String? _owner(String s) {
    final ask = _ownerAsk.firstMatch(s);
    if (ask != null && !_notNames.contains(ask.group(1))) return ask.group(1);
    for (final m in _ownerWill.allMatches(s)) {
      final name = m.group(1)!;
      if (!_notNames.contains(name.split(' ').first)) return name;
    }
    return null;
  }

  static String? _dueOf(String s) => _due.firstMatch(s)?.group(1);

  List<String> _keyPoints(List<String> sentences) {
    final tf = <String, int>{};
    List<String> words(String s) => s
        .toLowerCase()
        .split(RegExp(r"[^a-z0-9'ऀ-ॿ]+"))
        .where((w) => w.length > 2 && !_stop.contains(w))
        .toList();
    for (final s in sentences) {
      for (final w in words(s)) {
        tf[w] = (tf[w] ?? 0) + 1;
      }
    }
    final scored = <(int, double)>[];
    for (var i = 0; i < sentences.length; i++) {
      final ws = words(sentences[i]);
      if (ws.length < 3) continue;
      final score = ws.fold<int>(0, (a, w) => a + (tf[w] ?? 0)) /
          (ws.length + 4); // mild preference for longer, content-rich lines
      scored.add((i, score));
    }
    scored.sort((a, b) => b.$2.compareTo(a.$2));
    // Spread picks across the recording: at most 2 from each tenth.
    final perBucket = <int, int>{};
    final picked = <int>[];
    final bucketSize = (sentences.length / 10).ceil().clamp(1, 1 << 30);
    for (final (i, _) in scored) {
      final b = i ~/ bucketSize;
      if ((perBucket[b] ?? 0) >= 2) continue;
      perBucket[b] = (perBucket[b] ?? 0) + 1;
      picked.add(i);
      if (picked.length >= maxKeyPoints) break;
    }
    picked.sort();
    return [for (final i in picked) sentences[i]];
  }

  static List<String> _cap(List<String> l, int n) =>
      l.length > n ? l.sublist(0, n) : l;
}
