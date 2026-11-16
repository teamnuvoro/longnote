import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../../core/models/recording.dart';
import '../../core/notes/moments.dart';
import '../../core/notes/speakers.dart';
import '../../core/recording/recording_repository.dart';
import '../../core/summary/summary_models.dart';
import '../../core/util/coalescing_runner.dart';

/// Everything the note screen (D1-D8) shows, loaded off the build path.
class NoteData {
  NoteData({
    required this.note,
    required this.segments,
    required this.lines,
    required this.speakers,
    required this.summary,
    required this.summaryNote,
    required this.gaps,
    required this.moments,
  });

  final Recording note;
  final List<AudioSegment> segments;
  final List<TranscriptLine> lines;
  final List<Speaker> speakers;
  final MeetingSummary? summary;
  final String? summaryNote;
  final List<RecordingGap> gaps;
  final List<Moment> moments;

  late final Map<String, Speaker> byKey = {for (final s in speakers) s.key: s};

  List<AudioSegment> get playable =>
      segments.where((s) => s.dataBytes > 0).toList();

  bool get hasSpeakers => lines.any((l) => l.speaker != null);

  String nameOf(String? key) {
    if (key == null) return '';
    return byKey[key]?.name ?? defaultSpeakerName(key);
  }

  int colorOf(String? key) => key == null ? 0 : (byKey[key]?.colorIndex ?? 0);

  /// Colour of an action-item owner when it matches a speaker name.
  int? colorForOwner(String owner) {
    final o = owner.trim().toLowerCase();
    for (final s in speakers) {
      if (s.name.trim().toLowerCase() == o) return s.colorIndex;
    }
    return null;
  }

  /// Most common turn language (for 'auto' notes).
  String? get detectedLanguage {
    final counts = <String, int>{};
    for (final l in lines) {
      final c = l.language;
      if (c != null) counts[c] = (counts[c] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;
    return (counts.entries.toList()..sort((a, b) => b.value - a.value)).first.key;
  }

  /// Index of the turn playing at [ms] (last turn starting at or before it).
  int turnAt(int ms) {
    var lo = 0, hi = lines.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].startMs <= ms) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }
}

/// Loads [NoteData] for one note and reloads when the repository changes.
/// The transcript (the big part) is only re-read when it actually changed.
class NoteModel extends ChangeNotifier {
  NoteModel(this.repo, this.id) {
    repo.addListener(_schedule);
    _schedule();
  }

  final RecordingRepository repo;
  final String id;
  NoteData? data;

  /// True once we know the note does not exist (deleted).
  bool gone = false;
  bool _disposed = false;
  String? _transcriptKey;
  List<TranscriptLine> _lines = const [];

  late final CoalescingRunner _runner = CoalescingRunner(_load);
  void _schedule() => _runner.request();

  Future<void> reload() => _load();

  Future<void> _load() async {
    final note = await repo.get(id);
    if (_disposed) return;
    if (note == null) {
      gone = true;
      notifyListeners();
      return;
    }
    final db = repo.db;
    final speakers = await SpeakerStore(repo).list(id);
    final stat = await db.rawQuery(
        'SELECT COUNT(*) AS n, MAX(id) AS m FROM transcript_lines WHERE recording_id = ?',
        [id]);
    final key = '${stat.first['n']}/${stat.first['m']}/'
        '${speakers.map((s) => s.key).join(',')}';
    if (key != _transcriptKey) {
      _lines = await repo.transcript(id);
      _transcriptKey = key;
    }
    final segs = await repo.segments(id);
    final sum = await repo.summary(id);
    MeetingSummary? parsed;
    if (sum != null) {
      try {
        parsed = MeetingSummary.parse(sum.json);
      } catch (_) {}
    }
    final gaps = await repo.gaps(id);
    List<Moment> moments;
    try {
      moments = await MomentStore(repo).list(id);
    } on DatabaseException {
      moments = const [];
    }
    if (_disposed) return;
    data = NoteData(
      note: note,
      segments: segs,
      lines: _lines,
      speakers: speakers,
      summary: parsed,
      summaryNote: sum?.note,
      gaps: gaps,
      moments: moments,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _runner.close();
    repo.removeListener(_schedule);
    super.dispose();
  }
}
