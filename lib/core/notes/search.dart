import 'package:sqflite/sqflite.dart';

import '../recording/recording_repository.dart';

enum SearchHitKind { title, summary, transcript }

class SearchHit {
  const SearchHit({
    required this.recordingId,
    required this.kind,
    required this.snippet,
    this.lineId,
    this.startMs,
    this.speaker,
  });

  final String recordingId;
  final SearchHitKind kind;

  /// Text around the match. Matched words are wrapped in
  /// [NoteSearch.markStart] / [NoteSearch.markEnd] for bolding.
  final String snippet;

  /// Transcript hits: the turn, for tap-to-seek.
  final int? lineId;
  final int? startMs;
  final String? speaker;
}

/// Hits of one note, in the order the B3 search screen shows them.
class NoteSearchResult {
  NoteSearchResult(this.recordingId, this.title);
  final String recordingId;
  final String title;
  final hits = <SearchHit>[];
}

/// Full-text search over titles, summaries and transcript turns (B3).
/// Uses SQLite FTS5 (prefix match per word, all words must match); falls
/// back to LIKE when FTS5 is missing.
class NoteSearch {
  NoteSearch(this.repo, {required this.ftsEnabled});
  final RecordingRepository repo;
  final bool ftsEnabled;
  Database get _db => repo.db;

  static const markStart = '\u0002';
  static const markEnd = '\u0003';

  /// `budget prya` -> `"budget"* "prya"*`. Quotes neutralise FTS syntax.
  static String? ftsQuery(String input) {
    final words = input
        .split(RegExp(r'\s+'))
        .map((w) => w.replaceAll('"', '').trim())
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return null;
    return words.map((w) => '"$w"*').join(' ');
  }

  Future<List<NoteSearchResult>> search(String input,
      {int maxTurnHits = 200}) async {
    final q = ftsQuery(input);
    if (q == null) return const [];
    final byNote = <String, NoteSearchResult>{};
    final order = <String>[];
    NoteSearchResult note(String id, String title) =>
        byNote.putIfAbsent(id, () {
          order.add(id);
          return NoteSearchResult(id, title);
        });

    if (ftsEnabled) {
      final notes = await _db.rawQuery('''
        SELECT f.recording_id AS id, r.title AS title,
          highlight(notes_fts, 1, '$markStart', '$markEnd') AS t,
          snippet(notes_fts, 2, '$markStart', '$markEnd', '…', 16) AS s
        FROM notes_fts f JOIN recordings r ON r.id = f.recording_id
        WHERE notes_fts MATCH ? ORDER BY rank''', [q]);
      for (final m in notes) {
        final n = note(m['id'] as String, m['title'] as String);
        final t = m['t'] as String? ?? '';
        final s = m['s'] as String? ?? '';
        if (t.contains(markStart)) {
          n.hits.add(SearchHit(
              recordingId: n.recordingId, kind: SearchHitKind.title, snippet: t));
        }
        if (s.contains(markStart)) {
          n.hits.add(SearchHit(
              recordingId: n.recordingId, kind: SearchHitKind.summary, snippet: s));
        }
      }
      final turns = await _db.rawQuery('''
        SELECT l.id AS line_id, l.recording_id AS id, r.title AS title,
          l.start_ms AS start_ms, l.speaker AS speaker,
          snippet(turns_fts, 0, '$markStart', '$markEnd', '…', 16) AS s
        FROM turns_fts JOIN transcript_lines l ON l.id = turns_fts.rowid
        JOIN recordings r ON r.id = l.recording_id
        WHERE turns_fts MATCH ? ORDER BY rank LIMIT ?''', [q, maxTurnHits]);
      for (final m in turns) {
        final n = note(m['id'] as String, m['title'] as String);
        n.hits.add(SearchHit(
          recordingId: n.recordingId,
          kind: SearchHitKind.transcript,
          snippet: m['s'] as String,
          lineId: m['line_id'] as int,
          startMs: m['start_ms'] as int,
          speaker: m['speaker'] as String?,
        ));
      }
    } else {
      final like = '%${input.trim().replaceAll('%', '').replaceAll('_', '')}%';
      for (final m in await _db.rawQuery(
          'SELECT id, title FROM recordings WHERE title LIKE ? ORDER BY created_at DESC',
          [like])) {
        final n = note(m['id'] as String, m['title'] as String);
        n.hits.add(SearchHit(
            recordingId: n.recordingId,
            kind: SearchHitKind.title,
            snippet: n.title));
      }
      for (final m in await _db.rawQuery('''
          SELECT l.id AS line_id, l.recording_id AS id, r.title AS title,
            l.start_ms, l.speaker, l.text
          FROM transcript_lines l JOIN recordings r ON r.id = l.recording_id
          WHERE l.text LIKE ? ORDER BY r.created_at DESC, l.start_ms LIMIT ?''',
          [like, maxTurnHits])) {
        final n = note(m['id'] as String, m['title'] as String);
        n.hits.add(SearchHit(
          recordingId: n.recordingId,
          kind: SearchHitKind.transcript,
          snippet: m['text'] as String,
          lineId: m['line_id'] as int,
          startMs: m['start_ms'] as int,
          speaker: m['speaker'] as String?,
        ));
      }
    }
    return [for (final id in order) byNote[id]!];
  }
}
