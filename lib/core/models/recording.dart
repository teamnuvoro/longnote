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

/// Transcript + summary pipeline state of a note (one column,
/// `recordings.processing_status`). Cloud path:
///
/// ```
/// none(local_only) -> queued -> compressing -> uploading(progress)
///   -> queuedOnServer -> transcribing -> summarizing -> done
/// any network step offline -> waitingForNetwork -> (back online) -> resumes
/// any step fails -> queued (auto retry with backoff) ... -> failed(reason, tries)
/// limit_reached -> failed(error_code = limit_reached), retried automatically at the reset time
/// ```
/// On-device path: queued -> transcribing -> summarizing -> done | failed.
enum ProcessingStatus {
  /// local_only: saved on the phone, not queued (e.g. still recording, or empty).
  none,
  queued,
  compressing,
  uploading,
  queuedOnServer,
  transcribing,
  summarizing,
  done,
  failed,
  waitingForNetwork;

  static ProcessingStatus parse(String? s) => ProcessingStatus.values
      .firstWhere((e) => e.name == s, orElse: () => ProcessingStatus.none);

  /// Shown in the "Waiting & needs attention" list (B1).
  bool get needsAttention => this == failed || this == waitingForNetwork;

  /// Somewhere between queued and summarizing.
  bool get inProgress => !(this == none || this == done || this == failed);
}

/// Where a note is transcribed. Setting default; a note can override it
/// ("Transcribe on this phone instead").
enum TranscriptionMode {
  cloud,
  onDevice;

  String get id => this == cloud ? 'cloud' : 'on_device';
  static TranscriptionMode? parse(String? s) => switch (s) {
        'cloud' => cloud,
        'on_device' => onDevice,
        _ => null,
      };
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
    this.language,
    this.summaryStyle,
    this.customInstructions,
    this.outputLanguage,
    this.transcriptionMode,
    this.transcriptSource,
    this.source = 'recorded',
    this.importFile,
    this.progress,
    this.errorCode,
    this.tries = 0,
    this.updatedAt,
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

  // ---- v2 note options (null = use the app setting) ------------------------
  /// Audio language: 'auto' or a code ('en', 'hi', 'pt-BR').
  String? language;

  /// [SummaryStyle.id].
  String? summaryStyle;

  /// User's own summary instructions (<= 1000 chars).
  String? customInstructions;

  /// Summary language: 'same' or a language name ('English').
  String? outputLanguage;

  /// Per-note override of the setting ("Transcribe on this phone instead").
  TranscriptionMode? transcriptionMode;

  /// Which engine wrote transcript_lines: 'cloud' | 'on_device' | null.
  String? transcriptSource;

  /// 'recorded' | 'imported'.
  String source;

  /// Imported audio file, relative to the note folder (imports only).
  String? importFile;

  /// 0..1 while uploading (and other steps that know it).
  double? progress;

  /// Machine-readable code of the last failure ('limit_reached',
  /// 'upstream_failed', 'network' ...). [processingError] has plain words.
  String? errorCode;

  /// Failed attempts so far (resets on a manual retry).
  int tries;
  DateTime? updatedAt;

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
        'language': language,
        'summary_style': summaryStyle,
        'custom_instructions': customInstructions,
        'output_language': outputLanguage,
        'transcription_mode': transcriptionMode?.id,
        'transcript_source': transcriptSource,
        'source': source,
        'import_file': importFile,
        'progress': progress,
        'error_code': errorCode,
        'tries': tries,
        'updated_at': updatedAt?.millisecondsSinceEpoch,
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
        language: m['language'] as String?,
        summaryStyle: m['summary_style'] as String?,
        customInstructions: m['custom_instructions'] as String?,
        outputLanguage: m['output_language'] as String?,
        transcriptionMode:
            TranscriptionMode.parse(m['transcription_mode'] as String?),
        transcriptSource: m['transcript_source'] as String?,
        source: (m['source'] as String?) ?? 'recorded',
        importFile: m['import_file'] as String?,
        progress: (m['progress'] as num?)?.toDouble(),
        errorCode: m['error_code'] as String?,
        tries: (m['tries'] as int?) ?? 0,
        updatedAt: m['updated_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(m['updated_at'] as int),
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
    this.language,
    this.id,
  });

  /// Row id (null before insert). Used by search hits and highlights.
  final int? id;
  final int startMs;
  final int endMs;
  final String text;

  /// Speaker KEY (cloud: "1", "2"; over-5-hour notes: `<piece>:<n>`, e.g.
  /// "2:1"). Null for on-device transcripts (whisper has no speakers).
  /// Display names live in the `speakers` table.
  final String? speaker;

  /// Cloud: piece index. On-device: WAV part index.
  final int segmentIndex;

  /// ISO code of the turn's main language (cloud only).
  final String? language;

  Map<String, Object?> toMap(String recordingId) => {
        'recording_id': recordingId,
        'seg_idx': segmentIndex,
        'start_ms': startMs,
        'end_ms': endMs,
        'text': text,
        'speaker': speaker,
        'language': language,
      };

  factory TranscriptLine.fromMap(Map<String, Object?> m) => TranscriptLine(
        id: m['id'] as int?,
        language: m['language'] as String?,
        segmentIndex: m['seg_idx'] as int,
        startMs: m['start_ms'] as int,
        endMs: m['end_ms'] as int,
        text: m['text'] as String,
        speaker: m['speaker'] as String?,
      );
}
