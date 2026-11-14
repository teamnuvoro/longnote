import 'dart:convert';

class SummaryParseException implements Exception {
  SummaryParseException(this.message);
  final String message;
  @override
  String toString() => 'Could not read summary: $message';
}

class ActionItem {
  const ActionItem({required this.task, this.owner, this.due});
  final String task;

  /// Only set when the speaker said who. Never guessed.
  final String? owner;

  /// Only set when a date/deadline was said. Never guessed.
  final String? due;

  Map<String, Object?> toJson() => {
        'task': task,
        if (owner != null) 'owner': owner,
        if (due != null) 'due': due,
      };
}

/// The summary shape every summarizer produces:
/// `{key_points, decisions, action_items[{task, owner?, due?}],
///   numbers_and_dates, open_questions}`
class MeetingSummary {
  const MeetingSummary({
    this.keyPoints = const [],
    this.decisions = const [],
    this.actionItems = const [],
    this.numbersAndDates = const [],
    this.openQuestions = const [],
  });

  final List<String> keyPoints;
  final List<String> decisions;
  final List<ActionItem> actionItems;
  final List<String> numbersAndDates;
  final List<String> openQuestions;

  bool get isEmpty =>
      keyPoints.isEmpty &&
      decisions.isEmpty &&
      actionItems.isEmpty &&
      numbersAndDates.isEmpty &&
      openQuestions.isEmpty;

  Map<String, Object?> toJson() => {
        'key_points': keyPoints,
        'decisions': decisions,
        'action_items': actionItems.map((a) => a.toJson()).toList(),
        'numbers_and_dates': numbersAndDates,
        'open_questions': openQuestions,
      };

  String encode() => jsonEncode(toJson());

  /// Defensive parse of model output. Accepts:
  /// - plain JSON, JSON inside ```json fences, or JSON with chatter around it
  /// - missing fields (-> empty lists)
  /// - list items that are strings, numbers, or {"text": ...} objects
  /// - action items as strings or objects; owner/due "null", "", "unknown",
  ///   "n/a", "tbd" -> treated as not stated
  /// Throws [SummaryParseException] when there is no JSON object at all or it
  /// contains none of the expected fields.
  static MeetingSummary parse(String raw) {
    final obj = _extractJsonObject(raw);
    if (obj == null) throw SummaryParseException('no JSON object found');
    const keys = [
      'key_points',
      'decisions',
      'action_items',
      'numbers_and_dates',
      'open_questions'
    ];
    final normalized = <String, Object?>{
      for (final e in obj.entries) _normKey(e.key): e.value
    };
    if (!keys.any(normalized.containsKey)) {
      throw SummaryParseException('none of the expected fields present');
    }
    return MeetingSummary(
      keyPoints: _strings(normalized['key_points']),
      decisions: _strings(normalized['decisions']),
      actionItems: _actions(normalized['action_items']),
      numbersAndDates: _strings(normalized['numbers_and_dates']),
      openQuestions: _strings(normalized['open_questions']),
    );
  }

  static String _normKey(String k) =>
      k.trim().toLowerCase().replaceAll(RegExp(r'[\s\-]+'), '_');

  static Map<String, Object?>? _extractJsonObject(String raw) {
    final text = raw.trim();
    // Try whole string first.
    final direct = _tryDecode(text);
    if (direct != null) return direct;
    // Fenced block.
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(text);
    if (fence != null) {
      final f = _tryDecode(fence.group(1)!.trim());
      if (f != null) return f;
    }
    // First balanced {...} (string-aware).
    final start = text.indexOf('{');
    if (start < 0) return null;
    var depth = 0;
    var inStr = false;
    var esc = false;
    for (var i = start; i < text.length; i++) {
      final c = text[i];
      if (inStr) {
        if (esc) {
          esc = false;
        } else if (c == r'\') {
          esc = true;
        } else if (c == '"') {
          inStr = false;
        }
        continue;
      }
      if (c == '"') {
        inStr = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return _tryDecode(text.substring(start, i + 1));
      }
    }
    return null;
  }

  static Map<String, Object?>? _tryDecode(String s) {
    try {
      final v = jsonDecode(s);
      if (v is Map) return v.cast<String, Object?>();
    } catch (_) {}
    return null;
  }

  static String? _clean(Object? v) {
    if (v == null) return null;
    if (v is Map) {
      v = v['text'] ?? v['point'] ?? v['item'] ?? v['value'] ?? v['task'];
      if (v == null) return null;
    }
    if (v is! String && v is! num && v is! bool) return null;
    final s = v.toString().trim();
    return s.isEmpty ? null : s;
  }

  static List<String> _strings(Object? v) {
    if (v == null) return const [];
    if (v is String) {
      final s = v.trim();
      return s.isEmpty ? const [] : [s];
    }
    if (v is! List) return const [];
    return [for (final e in v) ?_clean(e)];
  }

  static const _unknown = {
    'null', 'none', 'unknown', 'n/a', 'na', 'tbd', 'not stated',
    'not specified', 'unspecified', '-', '',
  };

  static String? _opt(Object? v) {
    final s = _clean(v);
    if (s == null) return null;
    return _unknown.contains(s.toLowerCase()) ? null : s;
  }

  static List<ActionItem> _actions(Object? v) {
    if (v == null) return const [];
    final list = v is List ? v : [v];
    final out = <ActionItem>[];
    for (final e in list) {
      if (e is Map) {
        final m = {
          for (final x in e.entries) _normKey(x.key.toString()): x.value
        };
        final task = _clean(m['task'] ?? m['action'] ?? m['text'] ?? m['item']);
        if (task == null) continue;
        out.add(ActionItem(
          task: task,
          owner: _opt(m['owner'] ?? m['assignee'] ?? m['who']),
          due: _opt(m['due'] ?? m['due_date'] ?? m['deadline'] ?? m['when']),
        ));
      } else {
        final t = _clean(e);
        if (t != null) out.add(ActionItem(task: t));
      }
    }
    return out;
  }

  /// Merges chunk summaries in order, dropping exact/near-exact duplicates.
  static MeetingSummary merge(List<MeetingSummary> parts) {
    List<String> mergeStr(Iterable<List<String>> lists) {
      final seen = <String>{};
      final out = <String>[];
      for (final l in lists) {
        for (final s in l) {
          if (seen.add(_dedupeKey(s))) out.add(s);
        }
      }
      return out;
    }

    final seenTasks = <String, int>{};
    final actions = <ActionItem>[];
    for (final p in parts) {
      for (final a in p.actionItems) {
        final k = _dedupeKey(a.task);
        final existing = seenTasks[k];
        if (existing == null) {
          seenTasks[k] = actions.length;
          actions.add(a);
        } else {
          // Keep the version that has more stated detail.
          final old = actions[existing];
          actions[existing] = ActionItem(
            task: old.task,
            owner: old.owner ?? a.owner,
            due: old.due ?? a.due,
          );
        }
      }
    }

    return MeetingSummary(
      keyPoints: mergeStr(parts.map((p) => p.keyPoints)),
      decisions: mergeStr(parts.map((p) => p.decisions)),
      actionItems: actions,
      numbersAndDates: mergeStr(parts.map((p) => p.numbersAndDates)),
      openQuestions: mergeStr(parts.map((p) => p.openQuestions)),
    );
  }

  static String _dedupeKey(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9ऀ-ॿ]+'), ' ').trim();

  /// Plain text for copy/share.
  String toPlainText({String? title}) {
    final b = StringBuffer();
    if (title != null) b.writeln('$title\n');
    void section(String h, List<String> items) {
      if (items.isEmpty) return;
      b.writeln(h);
      for (final i in items) {
        b.writeln('- $i');
      }
      b.writeln();
    }

    section('Key points', keyPoints);
    section('Decisions', decisions);
    if (actionItems.isNotEmpty) {
      b.writeln('Action items');
      for (final a in actionItems) {
        final extra = [
          if (a.owner != null) 'owner: ${a.owner}',
          if (a.due != null) 'due: ${a.due}',
        ];
        b.writeln('- ${a.task}${extra.isEmpty ? '' : ' (${extra.join(', ')})'}');
      }
      b.writeln();
    }
    section('Numbers and dates', numbersAndDates);
    section('Open questions', openQuestions);
    return b.toString().trimRight();
  }
}
