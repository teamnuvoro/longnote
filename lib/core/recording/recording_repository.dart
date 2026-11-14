import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/recording.dart';

/// Where audio files live: `<root>/<recordingId>/seg_0000.wav`.
class RecordingStorage {
  RecordingStorage(this.rootPath);
  final String rootPath;

  String dirFor(String recordingId) => p.join(rootPath, recordingId);
  String segmentPath(String recordingId, String fileName) =>
      p.join(dirFor(recordingId), fileName);
}

/// All database access for recordings and their children. Notifies listeners
/// on any change so the UI can refresh.
class RecordingRepository extends ChangeNotifier {
  RecordingRepository(this._db, this.storage);
  final Database _db;
  final RecordingStorage storage;

  // ---- recordings ------------------------------------------------------------
  Future<void> insert(Recording r) async {
    await _db.insert('recordings', r.toMap());
    notifyListeners();
  }

  Future<void> update(Recording r) async {
    await _db.update('recordings', r.toMap(),
        where: 'id = ?', whereArgs: [r.id]);
    notifyListeners();
  }

  /// Quiet update for the 5-second heartbeat (no UI rebuild storm).
  Future<void> heartbeat(String id, DateTime at, int durationMs) =>
      _db.update(
          'recordings',
          {
            'heartbeat_at': at.millisecondsSinceEpoch,
            'duration_ms': durationMs,
          },
          where: 'id = ?',
          whereArgs: [id]);

  Future<Recording?> get(String id) async {
    final r =
        await _db.query('recordings', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Recording.fromMap(r.first);
  }

  Future<List<Recording>> all() async {
    final r = await _db.query('recordings', orderBy: 'created_at DESC');
    return r.map(Recording.fromMap).toList();
  }

  Future<List<Recording>> withStatus(List<RecordingStatus> s) async {
    final r = await _db.query('recordings',
        where: 'status IN (${List.filled(s.length, '?').join(',')})',
        whereArgs: s.map((e) => e.name).toList());
    return r.map(Recording.fromMap).toList();
  }

  Future<int> count() async =>
      Sqflite.firstIntValue(
          await _db.rawQuery('SELECT COUNT(*) FROM recordings')) ??
      0;

  Future<void> rename(String id, String title) async {
    await _db.update('recordings', {'title': title},
        where: 'id = ?', whereArgs: [id]);
    notifyListeners();
  }

  Future<void> setProcessing(String id, ProcessingStatus s,
      {String? error, String? progress}) async {
    await _db.update(
        'recordings',
        {
          'processing_status': s.name,
          'processing_error': error,
          'processing_progress': progress,
        },
        where: 'id = ?',
        whereArgs: [id]);
    notifyListeners();
  }

  /// The ONLY place audio is deleted: an explicit user delete with
  /// confirmation. Processing code never calls this.
  Future<void> deleteByUser(String id) async {
    await _db.delete('recordings', where: 'id = ?', whereArgs: [id]);
    final dir = Directory(storage.dirFor(id));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    notifyListeners();
  }

  // ---- segments ----------------------------------------------------------------
  Future<void> upsertSegment(AudioSegment s) => _db.insert(
      'segments', s.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<AudioSegment>> segments(String recordingId) async {
    final r = await _db.query('segments',
        where: 'recording_id = ?',
        whereArgs: [recordingId],
        orderBy: 'idx ASC');
    return r.map(AudioSegment.fromMap).toList();
  }

  Future<void> markSegmentTranscribed(String recordingId, int idx,
      {bool value = true}) =>
      _db.update('segments', {'transcribed': value ? 1 : 0},
          where: 'recording_id = ? AND idx = ?', whereArgs: [recordingId, idx]);

  Future<void> deleteSegmentRow(String recordingId, int idx) => _db.delete(
      'segments',
      where: 'recording_id = ? AND idx = ?',
      whereArgs: [recordingId, idx]);

  Future<List<String>> segmentPaths(String recordingId) async =>
      (await segments(recordingId))
          .where((s) => s.dataBytes > 0)
          .map((s) => storage.segmentPath(recordingId, s.fileName))
          .toList();

  // ---- gaps ----------------------------------------------------------------------
  Future<int> addGap(RecordingGap g) => _db.insert('gaps', g.toMap());

  Future<void> endGap(int gapId, DateTime endedAt) => _db.update(
      'gaps', {'ended_at': endedAt.millisecondsSinceEpoch},
      where: 'id = ?', whereArgs: [gapId]);

  Future<void> closeOpenGaps(String recordingId, DateTime endedAt) =>
      _db.update('gaps', {'ended_at': endedAt.millisecondsSinceEpoch},
          where: 'recording_id = ? AND ended_at IS NULL',
          whereArgs: [recordingId]);

  Future<List<RecordingGap>> gaps(String recordingId) async {
    final r = await _db.query('gaps',
        where: 'recording_id = ?',
        whereArgs: [recordingId],
        orderBy: 'at_ms ASC');
    return r.map(RecordingGap.fromMap).toList();
  }

  // ---- transcript ------------------------------------------------------------------
  /// Replaces the lines of one segment atomically (retry-safe).
  Future<void> saveSegmentTranscript(
      String recordingId, int segIdx, List<TranscriptLine> lines) async {
    await _db.transaction((txn) async {
      await txn.delete('transcript_lines',
          where: 'recording_id = ? AND seg_idx = ?',
          whereArgs: [recordingId, segIdx]);
      for (final l in lines) {
        await txn.insert('transcript_lines', l.toMap(recordingId));
      }
      await txn.update('segments', {'transcribed': 1},
          where: 'recording_id = ? AND idx = ?',
          whereArgs: [recordingId, segIdx]);
    });
  }

  Future<List<TranscriptLine>> transcript(String recordingId) async {
    final r = await _db.query('transcript_lines',
        where: 'recording_id = ?',
        whereArgs: [recordingId],
        orderBy: 'start_ms ASC, id ASC');
    return r.map(TranscriptLine.fromMap).toList();
  }

  // ---- summary -------------------------------------------------------------------
  Future<void> saveSummary(String recordingId, String json, String engine,
      {String? note, DateTime? at}) async {
    await _db.insert(
        'summaries',
        {
          'recording_id': recordingId,
          'json': json,
          'engine': engine,
          'note': note,
          'created_at': (at ?? DateTime.now()).millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<({String json, String engine, String? note})?> summary(
      String recordingId) async {
    final r = await _db.query('summaries',
        where: 'recording_id = ?', whereArgs: [recordingId]);
    if (r.isEmpty) return null;
    return (
      json: r.first['json'] as String,
      engine: r.first['engine'] as String,
      note: r.first['note'] as String?,
    );
  }
}
