import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'piece_planner.dart';

/// Persistent state of one piece of a note on its way through the server
/// (table `cloud_pieces`). Everything needed to resume after a crash.
class CloudPiece {
  CloudPiece({
    required this.recordingId,
    required this.index,
    required this.clientId,
    required this.inputs,
    required this.rangeStartMs,
    required this.startMs,
    required this.durationMs,
    this.audioFile,
    this.audioBytes,
    this.audioMs,
    this.userId,
    this.uploadUrl,
    this.uploadCreatedAt,
    this.uploaded = false,
    this.serverJobId,
    this.pollStartedAt,
    this.transcribed = false,
  });

  final String recordingId;
  final int index;

  /// `client_note_id` on the server: the note id, or `<note>_p<n>` when the
  /// note is split.
  final String clientId;
  final List<String> inputs;
  final int rangeStartMs;
  final int startMs;
  final int durationMs;
  String? audioFile;
  int? audioBytes;
  int? audioMs;
  String? userId;
  String? uploadUrl;
  DateTime? uploadCreatedAt;
  bool uploaded;
  String? serverJobId;
  DateTime? pollStartedAt;
  bool transcribed;

  Map<String, Object?> toMap() => {
        'recording_id': recordingId,
        'idx': index,
        'client_id': clientId,
        'inputs': jsonEncode(inputs),
        'range_start_ms': rangeStartMs,
        'start_ms': startMs,
        'duration_ms': durationMs,
        'audio_file': audioFile,
        'audio_bytes': audioBytes,
        'audio_ms': audioMs,
        'user_id': userId,
        'upload_url': uploadUrl,
        'upload_created_at': uploadCreatedAt?.millisecondsSinceEpoch,
        'uploaded': uploaded ? 1 : 0,
        'server_job_id': serverJobId,
        'poll_started_at': pollStartedAt?.millisecondsSinceEpoch,
        'transcribed': transcribed ? 1 : 0,
      };

  factory CloudPiece.fromMap(Map<String, Object?> m) {
    DateTime? t(Object? v) =>
        v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
    return CloudPiece(
      recordingId: m['recording_id'] as String,
      index: m['idx'] as int,
      clientId: m['client_id'] as String,
      inputs: (jsonDecode(m['inputs'] as String) as List).cast<String>(),
      rangeStartMs: m['range_start_ms'] as int,
      startMs: m['start_ms'] as int,
      durationMs: m['duration_ms'] as int,
      audioFile: m['audio_file'] as String?,
      audioBytes: m['audio_bytes'] as int?,
      audioMs: m['audio_ms'] as int?,
      userId: m['user_id'] as String?,
      uploadUrl: m['upload_url'] as String?,
      uploadCreatedAt: t(m['upload_created_at']),
      uploaded: m['uploaded'] == 1,
      serverJobId: m['server_job_id'] as String?,
      pollStartedAt: t(m['poll_started_at']),
      transcribed: m['transcribed'] == 1,
    );
  }

  /// Forget the server side (upload + job) so the next run uploads again.
  /// The local m4a is kept.
  void resetServer() {
    uploadUrl = null;
    uploadCreatedAt = null;
    uploaded = false;
    serverJobId = null;
    pollStartedAt = null;
  }
}

class CloudPieceStore {
  CloudPieceStore(this._db);
  final Database _db;

  Future<List<CloudPiece>> list(String recordingId) async => (await _db.query(
          'cloud_pieces',
          where: 'recording_id = ?',
          whereArgs: [recordingId],
          orderBy: 'idx ASC'))
      .map(CloudPiece.fromMap)
      .toList();

  Future<List<CloudPiece>> create(
      String recordingId, List<PiecePlan> plans) async {
    final out = [
      for (final p in plans)
        CloudPiece(
          recordingId: recordingId,
          index: p.index,
          clientId: plans.length == 1 ? recordingId : '${recordingId}_p${p.index + 1}',
          inputs: p.inputs,
          rangeStartMs: p.rangeStartMs,
          startMs: p.startMs,
          durationMs: p.durationMs,
        )
    ];
    await _db.transaction((txn) async {
      await txn.delete('cloud_pieces',
          where: 'recording_id = ?', whereArgs: [recordingId]);
      for (final p in out) {
        await txn.insert('cloud_pieces', p.toMap());
      }
    });
    return out;
  }

  Future<void> save(CloudPiece p, {DatabaseExecutor? txn}) => (txn ?? _db).update(
      'cloud_pieces', p.toMap(),
      where: 'recording_id = ? AND idx = ?', whereArgs: [p.recordingId, p.index]);

  Future<void> deleteAll(String recordingId) => _db.delete('cloud_pieces',
      where: 'recording_id = ?', whereArgs: [recordingId]);
}
