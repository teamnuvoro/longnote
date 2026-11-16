import 'dart:async';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';

import '../analytics/analytics.dart';
import '../config.dart';
import '../models/recording.dart';
import '../recording/recording_repository.dart';
import '../util/clock.dart';

/// Does the actual work for one recording. Must be idempotent/resumable and
/// must NEVER delete or modify audio files.
typedef JobProcessor = Future<void> Function(
    String recordingId, void Function(String progress) onProgress);

enum JobState { pending, running, done, failed }

/// Thrown by a processor when the work is not finished but nothing failed:
/// polling a server job, waiting for the network, waiting for a usage limit
/// to reset. The job runs again after [wait]; the try counter is NOT used up.
class JobDeferral implements Exception {
  JobDeferral({
    required this.wait,
    required this.status,
    this.progress,
    this.error,
    this.errorCode,
    this.progressValue,
  });

  final Duration wait;

  /// Status shown meanwhile (e.g. transcribing, waitingForNetwork, failed for
  /// limit_reached).
  final ProcessingStatus status;
  final String? progress;
  final double? progressValue;
  final String? error;
  final String? errorCode;

  @override
  String toString() => 'JobDeferral(${status.name}, $wait)';
}

/// A failure with plain words for the user. [retryable] false = give up at
/// once (no automatic retries), e.g. a bad request.
class JobFailure implements Exception {
  JobFailure(this.message, {this.code, this.retryable = true});
  final String message;
  final String? code;
  final bool retryable;
  @override
  String toString() => message;
}

/// Persistent, sequential processing queue with exponential backoff.
///
/// - Automatic retries: [maxAutoAttempts] tries, delay = base * 2^(n-1),
///   capped at [maxDelay].
/// - After that the recording shows "Processing failed" and a Retry button
///   ([retry]) which resets the attempt counter.
/// - Failure only writes job/recording status. Audio is never touched.
class ProcessingJobQueue {
  ProcessingJobQueue({
    required Database db,
    required this.repo,
    required this.analytics,
    required this.processor,
    Clock clock = const SystemClock(),
    this.maxAutoAttempts = AppConfig.maxAutoAttempts,
    this.baseDelay = AppConfig.retryBaseDelay,
    this.maxDelay = AppConfig.retryMaxDelay,
    this.autoSchedule = true,
  })  : _db = db,
        _clock = clock;

  final Database _db;
  final RecordingRepository repo;
  final Analytics analytics;
  final JobProcessor processor;
  final Clock _clock;
  final int maxAutoAttempts;
  final Duration baseDelay;
  final Duration maxDelay;

  /// When false (tests), no timers are created; call [runDue] by hand.
  final bool autoSchedule;

  Timer? _timer;
  bool _running = false;
  bool _paused = false;

  /// Delay before automatic attempt number [failedAttempts] + 1.
  Duration backoffFor(int failedAttempts) {
    final factor = math.pow(2, math.max(0, failedAttempts - 1)).toInt();
    final d = baseDelay * factor;
    return d > maxDelay ? maxDelay : d;
  }

  /// Called at launch: jobs that were running when the app died go back to
  /// pending (their work is resumable per segment).
  Future<void> resetInterrupted() async {
    final now = _clock.now().millisecondsSinceEpoch;
    final rows = await _db.query('jobs',
        where: 'state = ?', whereArgs: [JobState.running.name]);
    for (final r in rows) {
      await _db.update('jobs', {'state': JobState.pending.name, 'updated_at': now},
          where: 'recording_id = ?', whereArgs: [r['recording_id']]);
      await repo.setProcessing(r['recording_id'] as String, ProcessingStatus.queued);
    }
    _schedule();
  }

  /// Queues (or re-queues) a note from the start of its pipeline. Work
  /// already done (uploaded pieces, saved transcript parts) is kept.
  Future<void> enqueue(String recordingId) async {
    final now = _clock.now().millisecondsSinceEpoch;
    await _db.insert(
        'jobs',
        {
          'recording_id': recordingId,
          'state': JobState.pending.name,
          'attempts': 0,
          'next_attempt_at': now,
          'last_error': null,
          'updated_at': now,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
    await repo.setProcessing(recordingId, ProcessingStatus.queued, tries: 0);
    _schedule();
  }

  /// User tapped "Retry processing".
  Future<void> retry(String recordingId) async {
    await analytics.log(AnalyticsEvent.processingRetried,
        recordingId: recordingId, props: {'manual': true});
    await enqueue(recordingId);
  }

  /// Network came back: run every job that was waiting for it now.
  Future<void> wakeNetworkWaiters() async {
    final now = _clock.now().millisecondsSinceEpoch;
    await _db.rawUpdate('''
      UPDATE jobs SET next_attempt_at = ?
      WHERE state = ? AND recording_id IN (
        SELECT id FROM recordings WHERE processing_status = ?)''',
        [now, JobState.pending.name, ProcessingStatus.waitingForNetwork.name]);
    _schedule();
  }

  /// App start / back to foreground: check every pending job now (server
  /// jobs that were being polled, uploads that were cut off). Jobs deferred
  /// for a usage limit (status failed) keep their reset time.
  Future<void> pokeAll() async {
    final now = _clock.now().millisecondsSinceEpoch;
    await _db.rawUpdate('''
      UPDATE jobs SET next_attempt_at = ?
      WHERE state = ? AND next_attempt_at > ? AND recording_id IN (
        SELECT id FROM recordings WHERE processing_status != ?)''',
        [now, JobState.pending.name, now, ProcessingStatus.failed.name]);
    _schedule();
  }

  /// Hold processing (e.g. while a recording is running, to keep the CPU and
  /// battery for capture).
  void pause() {
    _paused = true;
    _timer?.cancel();
  }

  void resume() {
    _paused = false;
    _schedule();
  }

  Future<Map<String, Object?>?> job(String recordingId) async {
    final r = await _db
        .query('jobs', where: 'recording_id = ?', whereArgs: [recordingId]);
    return r.isEmpty ? null : r.first;
  }

  /// Runs every due job once, one at a time. Returns how many ran.
  Future<int> runDue() async {
    if (_running || _paused) return 0;
    _running = true;
    var ran = 0;
    try {
      while (!_paused) {
        final now = _clock.now().millisecondsSinceEpoch;
        // Ties (notes queued in the same millisecond) go in queue order.
        final due = await _db.query('jobs',
            where: 'state = ? AND next_attempt_at <= ?',
            whereArgs: [JobState.pending.name, now],
            orderBy: 'next_attempt_at ASC, rowid ASC',
            limit: 1);
        if (due.isEmpty) break;
        await _runOne(due.first);
        ran++;
      }
    } finally {
      _running = false;
    }
    _schedule();
    return ran;
  }

  Future<void> _runOne(Map<String, Object?> job) async {
    final id = job['recording_id'] as String;
    final attempts = job['attempts'] as int;
    if (attempts > 0) {
      await analytics.log(AnalyticsEvent.processingRetried,
          recordingId: id, props: {'manual': false, 'attempt': attempts + 1});
    }
    await _setJob(id, JobState.running, attempts: attempts);
    try {
      await processor(id, (msg) {
        repo.setProcessing(id, _stageFor(msg), progress: msg);
      });
      await _setJob(id, JobState.done, attempts: attempts + 1);
      await repo.setProcessing(id, ProcessingStatus.done, tries: 0);
    } on JobDeferral catch (d) {
      await _setJob(id, JobState.pending,
          attempts: attempts,
          error: d.error,
          nextAt: _clock.now().add(d.wait));
      await repo.setProcessing(id, d.status,
          error: d.error,
          errorCode: d.errorCode,
          progress: d.progress,
          progressValue: d.progressValue);
    } catch (e) {
      final failed = attempts + 1;
      final msg = e is JobFailure ? e.message : _short(e);
      final code = e is JobFailure ? e.code : null;
      final isFinal =
          failed >= maxAutoAttempts || (e is JobFailure && !e.retryable);
      await analytics.log(AnalyticsEvent.processingFailed,
          recordingId: id,
          props: {'attempt': failed, 'final': isFinal, 'error': code ?? msg});
      if (isFinal) {
        await _setJob(id, JobState.failed, attempts: failed, error: msg);
        await repo.setProcessing(id, ProcessingStatus.failed,
            error: msg, errorCode: code, tries: failed);
      } else {
        final wait = backoffFor(failed);
        await _setJob(id, JobState.pending,
            attempts: failed,
            error: msg,
            nextAt: _clock.now().add(wait));
        await repo.setProcessing(id, ProcessingStatus.queued,
            error: msg,
            errorCode: code,
            tries: failed,
            progress: 'Will try again in ${wait.inSeconds} s');
      }
    }
  }

  ProcessingStatus _stageFor(String msg) => msg.toLowerCase().contains('summar')
      ? ProcessingStatus.summarizing
      : ProcessingStatus.transcribing;

  Future<void> _setJob(String id, JobState s,
      {required int attempts, String? error, DateTime? nextAt}) {
    final now = _clock.now();
    return _db.update(
        'jobs',
        {
          'state': s.name,
          'attempts': attempts,
          'last_error': error,
          'next_attempt_at': (nextAt ?? now).millisecondsSinceEpoch,
          'updated_at': now.millisecondsSinceEpoch,
        },
        where: 'recording_id = ?',
        whereArgs: [id]);
  }

  void _schedule() {
    if (!autoSchedule || _paused) return;
    _timer?.cancel();
    () async {
      final rows = await _db.query('jobs',
          where: 'state = ?',
          whereArgs: [JobState.pending.name],
          orderBy: 'next_attempt_at ASC',
          limit: 1);
      if (rows.isEmpty || _paused) return;
      final at = DateTime.fromMillisecondsSinceEpoch(
          rows.first['next_attempt_at'] as int);
      var wait = at.difference(_clock.now());
      if (wait.isNegative) wait = Duration.zero;
      _timer?.cancel();
      _timer = Timer(wait, () => runDue());
    }();
  }

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 300 ? '${s.substring(0, 300)}...' : s;
  }

  void dispose() => _timer?.cancel();
}
