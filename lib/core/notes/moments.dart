import 'package:sqflite/sqflite.dart';

import '../recording/recording_repository.dart';

/// "Mark moment" bookmark at a position in the audio (C1, D7).
class Moment {
  const Moment(
      {required this.id,
      required this.recordingId,
      required this.atMs,
      this.label,
      required this.createdAt});
  final int id;
  final String recordingId;
  final int atMs;
  final String? label;
  final DateTime createdAt;

  factory Moment.fromMap(Map<String, Object?> m) => Moment(
        id: m['id'] as int,
        recordingId: m['recording_id'] as String,
        atMs: m['at_ms'] as int,
        label: m['label'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
}

class MomentStore {
  MomentStore(this.repo);
  final RecordingRepository repo;
  Database get _db => repo.db;

  Future<int> add(String recordingId, int atMs, {String? label, DateTime? at}) async {
    final id = await _db.insert('moments', {
      'recording_id': recordingId,
      'at_ms': atMs,
      'label': label,
      'created_at': (at ?? DateTime.now()).millisecondsSinceEpoch,
    });
    repo.changed();
    return id;
  }

  Future<List<Moment>> list(String recordingId) async => (await _db.query(
          'moments',
          where: 'recording_id = ?',
          whereArgs: [recordingId],
          orderBy: 'at_ms ASC'))
      .map(Moment.fromMap)
      .toList();

  Future<void> rename(int id, String? label) async {
    await _db.update('moments', {'label': label}, where: 'id = ?', whereArgs: [id]);
    repo.changed();
  }

  Future<void> delete(int id) async {
    await _db.delete('moments', where: 'id = ?', whereArgs: [id]);
    repo.changed();
  }
}
