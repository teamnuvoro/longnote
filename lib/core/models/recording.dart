import '../config.dart';

/// Capture state of a recording.
enum RecordingStatus {
  /// Being recorded right now (or the app died while it was).
  recording,

  /// Paused by the user or by an interruption (phone call).
  paused,

  /// Stopped normally by the user.
  completed,

  /// The app was killed or crashed while recording; audio up to the last
  /// flush was recovered on next launch.
  interrupted;

  static RecordingStatus parse(String? s) => RecordingStatus.values
      .firstWhere((e) => e.name == s, orElse: () => RecordingStatus.completed);

  bool get isLive => this == recording || this == paused;
}

/// Transcript + summary pipeline state.
enum ProcessingStatus {
  none,
  queued,
  transcribing,
  summarizing,
  done,
  failed;

  static ProcessingStatus parse(String? s) => ProcessingStatus.values
      .firstWhere((e) => e.name == s, orElse: () => ProcessingStatus.none);
}

class Recording {
  Recording({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.status,
    this.durationMs = 0,
    this.segmentCount = 0,
    this.heartbeatAt,
    this.note,
    this.processingStatus = ProcessingStatus.none,
    this.processingError,
    this.processingProgress,
  });

  final String id;
  String title;
  final DateTime createdAt;
  RecordingStatus status;
  int durationMs;
  int segmentCount;
  DateTime? heartbeatAt;

  /// Honest note shown to the user, e.g. "Interrupted - saved 42 min".
  String? note;
  ProcessingStatus processingStatus;
  String? processingError;

  /// Free-text progress, e.g. "Transcribing part 3 of 12".
  String? processingProgress;

  Duration get duration => Duration(milliseconds: durationMs);

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'created_at': createdAt.millisecondsSinceEpoch,
        'status': status.name,
        'duration_ms': durationMs,
        'segment_count': segmentCount,
        'heartbeat_at': heartbeatAt?.millisecondsSinceEpoch,
        'note': note,
        'processing_status': processingStatus.name,
        'processing_error': processingError,
        'processing_progress': processingProgress,
      };

  factory Recording.fromMap(Map<String, Object?> m) => Recording(
        id: m['id'] as String,
        title: (m['title'] as String?) ?? 'Recording',
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
        status: RecordingStatus.parse(m['status'] as String?),
        durationMs: (m['duration_ms'] as int?) ?? 0,
        segmentCount: (m['segment_count'] as int?) ?? 0,
        heartbeatAt: m['heartbeat_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['heartbeat_at'] as int),
        note: m['note'] as String?,
        processingStatus:
            ProcessingStatus.parse(m['processing_status'] as String?),
        processingError: m['processing_error'] as String?,
        processingProgress: m['processing_progress'] as String?,
      );
}

/// One 5-minute WAV file of a recording.
class AudioSegment {
  AudioSegment({
    required this.recordingId,
    required this.index,
    required this.fileName,
    this.dataBytes = 0,
    this.closed = false,
    this.transcribed = false,
  });

  final String recordingId;
  final int index;

  /// File name relative to the recording folder (iOS container paths change
  /// between installs/updates, so we never store absolute paths).
  final String fileName;
  int dataBytes;
  bool closed;
  bool transcribed;

  int get durationMs => dataBytes * 1000 ~/ AppConfig.bytesPerSecond;

  Map<String, Object?> toMap() => {
        'recording_id': recordingId,
        'idx': index,
        'file_name': fileName,
        'data_bytes': dataBytes,
        'closed': closed ? 1 : 0,
        'transcribed': transcribed ? 1 : 0,
      };

  factory AudioSegment.fromMap(Map<String, Object?> m) => AudioSegment(
        recordingId: m['recording_id'] as String,
        index: m['idx'] as int,
        fileName: m['file_name'] as String,
        dataBytes: (m['data_bytes'] as int?) ?? 0,
        closed: (m['closed'] as int? ?? 0) == 1,
        transcribed: (m['transcribed'] as int? ?? 0) == 1,
      );
}

/// A stretch where capture was paused by an interruption (e.g. phone call).
/// [atMs] is the position in the saved audio where the gap happened.
class RecordingGap {
  RecordingGap({
    required this.recordingId,
    required this.atMs,
    required this.startedAt,
    this.endedAt,
    required this.reason,
  });

  final String recordingId;
  final int atMs;
  final DateTime startedAt;
  DateTime? endedAt;
  final String reason;

  Map<String, Object?> toMap() => {
        'recording_id': recordingId,
        'at_ms': atMs,
        'started_at': startedAt.millisecondsSinceEpoch,
        'ended_at': endedAt?.millisecondsSinceEpoch,
        'reason': reason,
      };

  factory RecordingGap.fromMap(Map<String, Object?> m) => RecordingGap(
        recordingId: m['recording_id'] as String,
        atMs: m['at_ms'] as int,
        startedAt:
            DateTime.fromMillisecondsSinceEpoch(m['started_at'] as int),
        endedAt: m['ended_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['ended_at'] as int),
        reason: m['reason'] as String,
      );
}

/// One timed line of transcript.
class TranscriptLine {
  TranscriptLine({
    required this.startMs,
    required this.endMs,
    required this.text,
    this.speaker,
    this.segmentIndex = 0,
  });

  final int startMs;
  final int endMs;
  final String text;

  /// Always null in v1: whisper.cpp cannot tell speakers apart. Kept so cloud
  /// diarization can fill it later without a schema change.
  final String? speaker;
  final int segmentIndex;

  Map<String, Object?> toMap(String recordingId) => {
        'recording_id': recordingId,
        'seg_idx': segmentIndex,
        'start_ms': startMs,
        'end_ms': endMs,
        'text': text,
        'speaker': speaker,
      };

  factory TranscriptLine.fromMap(Map<String, Object?> m) => TranscriptLine(
        segmentIndex: m['seg_idx'] as int,
        startMs: m['start_ms'] as int,
        endMs: m['end_ms'] as int,
        text: m['text'] as String,
        speaker: m['speaker'] as String?,
      );
}
