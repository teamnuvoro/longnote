import 'dart:io';

import 'package:path/path.dart' as p;

import '../jobs/job_queue.dart';
import '../models/recording.dart';
import '../notes/speakers.dart';
import '../recording/recording_repository.dart';
import '../settings/app_settings.dart';
import '../export/text_format.dart';
import '../summary/cloud_summarizer.dart';
import '../summary/summarizer.dart';
import '../summary/summary_models.dart';
import '../summary/summary_style.dart';
import '../util/clock.dart';
import 'api_error.dart';
import 'audio_encoder.dart';
import 'backend_config.dart';
import 'cloud_pieces.dart';
import 'longnote_api.dart';
import 'network_monitor.dart';
import 'piece_planner.dart';
import 'supabase_auth.dart';
import 'tus_uploader.dart';

/// Called when a note is ready (the app shows a local notification if it is
/// in the background).
abstract class NoteReadyNotifier {
  Future<void> noteReady(Recording note);
}

/// Timings and limits of the cloud pipeline (BACKEND-API 4.2 and 7).
/// Tests shrink them.
class CloudPipelineConfig {
  const CloudPipelineConfig({
    this.maxSingleMs = 5 * 3600 * 1000,
    this.pieceMs = 4 * 3600 * 1000,
    this.pollFast = const Duration(seconds: 5),
    this.pollSlow = const Duration(seconds: 15),
    this.fastFor = const Duration(minutes: 1),
    this.pollPatience = const Duration(hours: 2),
    this.pollAfterPatience = const Duration(minutes: 10),
    this.uploadUrlTtl = const Duration(hours: 23),
    this.offlineWait = const Duration(minutes: 30),
    this.networkRetry = const Duration(seconds: 30),
    this.hourLimitWait = const Duration(minutes: 15),
  });

  final int maxSingleMs;
  final int pieceMs;
  final Duration pollFast;
  final Duration pollSlow;
  final Duration fastFor;

  /// After this, keep checking but slowly and say "still processing".
  final Duration pollPatience;
  final Duration pollAfterPatience;

  /// Upload URLs live 24 h; start a new upload after this.
  final Duration uploadUrlTtl;

  /// Offline: wait this long unless the network comes back first (the
  /// connectivity listener wakes the job).
  final Duration offlineWait;

  /// Online but a request failed at the network level.
  final Duration networkRetry;
  final Duration hourLimitWait;
}

/// Cloud transcription for one note, run inside [ProcessingJobQueue]:
///
/// compress (native AAC) -> TUS upload -> transcribe-start -> poll
/// transcribe-status -> save turns + speakers -> ack -> summarize -> done.
///
/// Every step is resumable from the `cloud_pieces` row. Unfinished work is
/// reported with [JobDeferral] (poll later / wait for network / wait for a
/// limit) or [JobFailure] (counts as a try; backoff; then "failed").
/// Local audio is never modified or deleted.
class CloudPipeline {
  CloudPipeline({
    required this.repo,
    required this.settings,
    required this.auth,
    required this.api,
    required this.tus,
    required this.encoder,
    required this.network,
    required this.pieces,
    this.notifier,
    this.config = const CloudPipelineConfig(),
    Clock clock = const SystemClock(),
    CloudSummarizer? summarizer,
  })  : _clock = clock,
        speakers = SpeakerStore(repo),
        summarizer = summarizer ?? CloudSummarizer(api: api);

  final RecordingRepository repo;
  final AppSettings settings;
  final SupabaseAuth auth;
  final LongnoteApi api;
  final TusUploader tus;
  final AudioEncoder encoder;
  final NetworkMonitor network;
  final CloudPieceStore pieces;
  final NoteReadyNotifier? notifier;
  final CloudPipelineConfig config;
  final CloudSummarizer summarizer;
  final SpeakerStore speakers;
  final Clock _clock;

  /// [JobProcessor] entry point.
  Future<void> process(String id, void Function(String) onProgress) async {
    try {
      await _process(id);
    } on JobDeferral {
      rethrow;
    } on JobFailure {
      rethrow;
    } catch (e) {
      throw await _translate(e);
    }
  }

  // ---------------------------------------------------------------------------
  Future<void> _process(String id) async {
    final note = await repo.get(id);
    if (note == null) {
      throw JobFailure('This note no longer exists.', code: 'not_found', retryable: false);
    }
    if (!await network.isOnline()) throw _offline();

    var list = await pieces.list(id);
    if (list.isEmpty) {
      final plans = planPieces(await _inputs(note),
          maxSingleMs: config.maxSingleMs, pieceMs: config.pieceMs);
      if (plans.isEmpty) {
        throw JobFailure(plainEnglishError('no_audio'), code: 'no_audio', retryable: false);
      }
      if (note.transcriptSource != 'cloud') {
        await repo.clearTranscript(id);
        await repo.setTranscriptSource(id, 'cloud');
      }
      list = await pieces.create(id, plans);
    }

    // Phase 1: every piece without a server job: compress, upload, start.
    for (final piece in list) {
      if (piece.transcribed || piece.serverJobId != null) continue;
      await _encode(note, piece, list.length);
      await _upload(note, piece, list.length);
      await _start(note, piece);
    }

    // Phase 2: poll every running piece once.
    var anyQueued = false;
    var pending = 0;
    DateTime? oldest;
    for (final piece in list) {
      if (piece.transcribed) continue;
      final st = await api.transcribeStatus(piece.serverJobId!);
      switch (st.status) {
        case 'done' when st.turns != null:
          await _saveTurns(piece, st.turns!, multi: list.length > 1);
          try {
            await api.transcribeStatus(piece.serverJobId!, ack: true);
          } catch (_) {
            // The server deletes the copy 15-30 min after the fetch anyway.
          }
        case 'transcribing' || 'done':
          pending++;
          if (st.providerStatus == 'queued') anyQueued = true;
          final started = piece.pollStartedAt ?? _clock.now();
          if (oldest == null || started.isBefore(oldest)) oldest = started;
        case 'uploaded':
          // Not started (limit hit / provider refused): ask again.
          await _start(note, piece);
          pending++;
          oldest ??= _clock.now();
        case 'failed':
          piece.resetServer();
          await pieces.save(piece);
          final code = st.errorCode ?? 'transcription_failed';
          throw JobFailure(
              code == 'upstream_failed'
                  ? plainEnglishError('transcription_failed')
                  : plainEnglishError(code),
              code: code);
        default: // 'fetched' without a saved transcript: the result is gone.
          piece.resetServer();
          await pieces.save(piece);
          throw JobFailure(plainEnglishError('transcription_failed'),
              code: 'transcription_failed');
      }
    }
    if (pending > 0) {
      final elapsed = _clock.now().difference(oldest!);
      final patient = elapsed > config.pollPatience;
      final wait = patient
          ? config.pollAfterPatience
          : (elapsed < config.fastFor ? config.pollFast : config.pollSlow);
      throw JobDeferral(
        wait: wait,
        status: anyQueued
            ? ProcessingStatus.queuedOnServer
            : ProcessingStatus.transcribing,
        progress: patient
            ? 'Still processing. We will keep checking.'
            : (anyQueued ? 'Waiting for the server' : 'Transcribing'),
      );
    }

    // Phase 3: summary.
    await _summarize(note);
    final done = await repo.get(id);
    if (done != null) await notifier?.noteReady(done);
  }

  // ---------------------------------------------------------------------------
  Future<List<AudioInput>> _inputs(Recording note) async {
    if (note.source == 'imported' && note.importFile != null) {
      return [AudioInput(note.importFile!, note.durationMs)];
    }
    return [
      for (final s in await repo.segments(note.id))
        if (s.dataBytes > 0) AudioInput(s.fileName, s.durationMs)
    ];
  }

  String _abs(String noteId, String rel) =>
      p.join(repo.storage.dirFor(noteId), rel);

  Future<void> _encode(Recording note, CloudPiece piece, int n) async {
    if (piece.audioFile != null) {
      final f = File(_abs(note.id, piece.audioFile!));
      if (f.existsSync() && f.lengthSync() == piece.audioBytes) return;
    }
    await repo.setProcessing(note.id, ProcessingStatus.compressing,
        progress: n > 1
            ? 'Preparing audio (part ${piece.index + 1} of $n)'
            : 'Preparing audio');
    final rel = p.join('cloud', 'piece_${piece.index + 1}.m4a');
    final out = _abs(note.id, rel);
    Directory(p.dirname(out)).createSync(recursive: true);
    final r = await encoder.encodeM4a(
      inputs: [for (final i in piece.inputs) _abs(note.id, i)],
      output: out,
      startMs: piece.rangeStartMs,
      durationMs: n > 1 ? piece.durationMs : null,
    );
    piece
      ..audioFile = rel
      ..audioBytes = File(out).lengthSync()
      ..audioMs = r.durationMs
      ..resetServer();
    await pieces.save(piece);
  }

  Future<void> _upload(Recording note, CloudPiece piece, int n) async {
    final userId = await auth.userId();
    if (piece.userId != null && piece.userId != userId) piece.resetServer();
    if (piece.uploaded) return;
    final file = File(_abs(note.id, piece.audioFile!));
    final total = piece.audioBytes!;
    var lastPct = -1;
    Future<void> report(int sent) async {
      final frac = total == 0 ? 1.0 : sent / total;
      final pct = (frac * 100).floor();
      if (pct == lastPct) return;
      lastPct = pct;
      await repo.setProcessing(note.id, ProcessingStatus.uploading,
          progressValue: (piece.index + frac) / n,
          progress: n > 1
              ? 'Uploading part ${piece.index + 1} of $n · $pct%'
              : 'Uploading · $pct%');
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      var offset = 0;
      final now = _clock.now();
      if (piece.uploadUrl != null &&
          piece.uploadCreatedAt != null &&
          now.difference(piece.uploadCreatedAt!) < config.uploadUrlTtl) {
        final off =
            await tus.offset(location: piece.uploadUrl!, token: await auth.accessToken());
        if (off == null) {
          piece.uploadUrl = null;
        } else {
          offset = off;
        }
      } else {
        piece.uploadUrl = null;
      }
      if (piece.uploadUrl == null) {
        piece
          ..uploadUrl = await tus.create(
              token: await auth.accessToken(),
              bucket: BackendConfig.bucket,
              objectPath: '$userId/${piece.clientId}.m4a',
              length: total)
          ..uploadCreatedAt = now
          ..userId = userId;
        await pieces.save(piece);
      }
      await report(offset);
      try {
        if (offset < total) {
          await tus.upload(
            location: piece.uploadUrl!,
            file: file,
            from: offset,
            token: auth.accessToken,
            onOffset: (sent, _) => report(sent),
          );
        }
        piece.uploaded = true;
        await pieces.save(piece);
        return;
      } on TusExpired {
        piece.uploadUrl = null;
        await pieces.save(piece);
      }
    }
    throw JobFailure(plainEnglishError('server_error'), code: 'upload_expired');
  }

  Future<void> _start(Recording note, CloudPiece piece) async {
    await repo.setProcessing(note.id, ProcessingStatus.queuedOnServer,
        progress: 'Waiting for the server', progressValue: null);
    final language = note.language ?? await settings.audioLanguage();
    final ms = piece.audioMs ?? piece.durationMs;
    try {
      final r = await api.transcribeStart(
        clientNoteId: piece.clientId,
        audioPath: '${piece.userId}/${piece.clientId}.m4a',
        audioSeconds: (ms <= 0 ? 100 : ms) / 1000.0,
        language: language,
      );
      piece
        ..serverJobId = r.jobId
        ..pollStartedAt = _clock.now();
      await pieces.save(piece);
    } on ApiException catch (e) {
      if (e.code == 'not_found') {
        // The upload is gone (24-h sweep, or never finished): send it again.
        piece.resetServer();
        await pieces.save(piece);
      }
      rethrow;
    }
  }

  Future<void> _saveTurns(CloudPiece piece, List<ServerTurn> turns,
      {required bool multi}) async {
    String key(String s) => multi ? '${piece.index + 1}:$s' : s;
    await repo.db.transaction((txn) async {
      await txn.delete('transcript_lines',
          where: 'recording_id = ? AND seg_idx = ?',
          whereArgs: [piece.recordingId, piece.index]);
      for (final t in turns) {
        await txn.insert(
            'transcript_lines',
            TranscriptLine(
              startMs: t.startMs + piece.startMs,
              endMs: t.endMs + piece.startMs,
              text: t.text,
              speaker: key(t.speaker),
              segmentIndex: piece.index,
              language: t.language,
            ).toMap(piece.recordingId));
      }
      await speakers.ensure(
          piece.recordingId, turns.map((t) => key(t.speaker)),
          txn: txn);
      piece.transcribed = true;
      await pieces.save(piece, txn: txn);
    });
    repo.changed();
  }

  Future<void> _summarize(Recording note) async {
    await repo.setProcessing(note.id, ProcessingStatus.summarizing,
        progress: 'Writing summary');
    final lines = await repo.transcript(note.id);
    final names = await speakers.names(note.id);
    final text = transcriptToText(lines, names: names);
    final style = SummaryStyle.parse(
        note.summaryStyle ?? (await settings.defaultStyle()).id);
    if (text.trim().isEmpty) {
      await repo.saveSummary(note.id, const MeetingSummary().encode(), 'cloud',
          note: 'No speech was found in this recording.', style: style.id);
      return;
    }
    final s = await summarizeLong(
      summarizer.withOptions(SummaryOptions(
        style: style,
        customInstructions: note.customInstructions,
        outputLanguage: note.outputLanguage ?? await settings.summaryLanguage(),
      )),
      text,
      onProgress: (d, t) {
        if (t > 1) {
          repo.setProcessing(note.id, ProcessingStatus.summarizing,
              progress: 'Writing summary (${d + 1 > t ? t : d + 1} of $t)');
        }
      },
    );
    await repo.saveSummary(note.id, s.encode(), 'cloud', style: style.id);
  }

  /// Re-summarize a done note with a new style / instructions (D6). Runs
  /// directly (not via the queue); throws [ApiException] / network errors.
  Future<void> resummarize(String id) async {
    final note = await repo.get(id);
    if (note == null) return;
    await _summarize(note);
    await repo.setProcessing(id, ProcessingStatus.done);
  }

  // ---------------------------------------------------------------------------
  JobDeferral _offline() => JobDeferral(
        wait: config.offlineWait,
        status: ProcessingStatus.waitingForNetwork,
        error: plainEnglishError(networkErrorCode),
        errorCode: networkErrorCode,
        progress: 'Waiting for internet',
      );

  Future<Exception> _translate(Object e) async {
    if (isNetworkError(e)) {
      if (!await network.isOnline()) return _offline();
      return JobDeferral(
        wait: config.networkRetry,
        status: ProcessingStatus.waitingForNetwork,
        error: plainEnglishError(networkErrorCode),
        errorCode: networkErrorCode,
        progress: 'Waiting for internet',
      );
    }
    if (e is AudioEncodeException) {
      return JobFailure(plainEnglishError('encode_failed'), code: 'encode_failed');
    }
    if (e is ApiException) {
      switch (e.code) {
        case 'limit_reached':
          final scope = e.detail['scope'];
          final wait = scope == 'user_hour'
              ? config.hourLimitWait
              : _untilNextUtcDay();
          return JobDeferral(
            wait: wait,
            status: ProcessingStatus.failed,
            error: e.userMessage,
            errorCode: 'limit_reached',
          );
        case 'bad_request' || 'too_long' || 'payload_too_large':
          return JobFailure(e.userMessage, code: e.code, retryable: false);
        default:
          return JobFailure(e.userMessage, code: e.code);
      }
    }
    return JobFailure(plainEnglishError('server_error'), code: 'unexpected');
  }

  Duration _untilNextUtcDay() {
    final now = _clock.now().toUtc();
    final next = DateTime.utc(now.year, now.month, now.day + 1, 0, 2);
    return next.difference(now);
  }
}
