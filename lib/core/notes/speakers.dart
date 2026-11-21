import 'package:sqflite/sqflite.dart';

import '../models/recording.dart';
import '../recording/recording_repository.dart';

/// A voice in a note's transcript. [key] is the server's label ("1", "2", or
/// "2:1" for piece 2 of an over-5-hour note); [name] is what the user sees.
class Speaker {
  const Speaker(
      {required this.recordingId,
      required this.key,
      required this.name,
      required this.colorIndex});

  final String recordingId;
  final String key;
  final String name;
  final int colorIndex;

  factory Speaker.fromMap(Map<String, Object?> m) => Speaker(
        recordingId: m['recording_id'] as String,
        key: m['speaker_key'] as String,
        name: m['display_name'] as String,
        colorIndex: (m['color_index'] as int?) ?? 0,
      );
}

/// Default name for a speaker key: "Speaker 1"; for over-5-hour notes
/// "2:1" -> "Speaker 1 (part 2)" (keys of different pieces are different
/// people as far as we know; the user can merge them).
String defaultSpeakerName(String key) {
  final i = key.indexOf(':');
  if (i < 0) return 'Speaker $key';
  return 'Speaker ${key.substring(i + 1)} (part ${key.substring(0, i)})';
}

/// Speakers table: rename, merge, list.
class SpeakerStore {
  SpeakerStore(this.repo);
  final RecordingRepository repo;
  Database get _db => repo.db;

  Future<List<Speaker>> list(String recordingId) async {
    final r = await _db.query('speakers',
        where: 'recording_id = ?',
        whereArgs: [recordingId],
        orderBy: 'color_index ASC, speaker_key ASC');
    return r.map(Speaker.fromMap).toList();
  }

  /// key -> display name, for rendering and for the summary/ask text.
  Future<Map<String, String>> names(String recordingId) async => {
        for (final s in await list(recordingId)) s.key: s.name,
      };

  /// Adds any speaker keys not yet known, with default names and the next
  /// free colour. Existing names are kept.
  Future<void> ensure(String recordingId, Iterable<String> keys,
      {DatabaseExecutor? txn}) async {
    final ex = txn ?? _db;
    final existing = await ex.query('speakers',
        columns: ['speaker_key', 'color_index'],
        where: 'recording_id = ?',
        whereArgs: [recordingId]);
    final known = {for (final r in existing) r['speaker_key'] as String};
    var next = existing.isEmpty
        ? 0
        : existing.map((r) => r['color_index'] as int).reduce((a, b) => a > b ? a : b) + 1;
    for (final k in keys) {
      if (known.add(k)) {
        await ex.insert('speakers', {
          'recording_id': recordingId,
          'speaker_key': k,
          'display_name': defaultSpeakerName(k),
          'color_index': next++,
        });
      }
    }
  }

  Future<void> rename(String recordingId, String key, String name) async {
    final n = name.trim();
    if (n.isEmpty) return;
    final old = (await names(recordingId))[key];
    await _db.update('speakers', {'display_name': n},
        where: 'recording_id = ? AND speaker_key = ?',
        whereArgs: [recordingId, key]);
    // The summary names people as the transcript did: follow the rename.
    if (old != null) await repo.renameInSummary(recordingId, old, n);
    repo.changed();
  }

  /// Merge [fromKey] into [intoKey]: every turn of [fromKey] becomes
  /// [intoKey], then [fromKey] is deleted. One transaction.
  Future<void> merge(String recordingId,
      {required String fromKey, required String intoKey}) async {
    if (fromKey == intoKey) return;
    final before = await names(recordingId);
    await _db.transaction((txn) async {
      await txn.update('transcript_lines', {'speaker': intoKey},
          where: 'recording_id = ? AND speaker = ?',
          whereArgs: [recordingId, fromKey]);
      await txn.delete('speakers',
          where: 'recording_id = ? AND speaker_key = ?',
          whereArgs: [recordingId, fromKey]);
    });
    final from = before[fromKey], into = before[intoKey];
    if (from != null && into != null) {
      await repo.renameInSummary(recordingId, from, into);
    }
    repo.changed();
  }

  /// First turn of each speaker (D4 shows a sample line per voice).
  Future<Map<String, TranscriptLine>> firstTurns(String recordingId) async {
    final r = await _db.rawQuery('''
      SELECT * FROM transcript_lines t
      WHERE recording_id = ? AND speaker IS NOT NULL AND id = (
        SELECT id FROM transcript_lines u
        WHERE u.recording_id = t.recording_id AND u.speaker = t.speaker
        ORDER BY start_ms ASC, id ASC LIMIT 1)''', [recordingId]);
    return {
      for (final m in r) m['speaker'] as String: TranscriptLine.fromMap(m)
    };
  }
}
