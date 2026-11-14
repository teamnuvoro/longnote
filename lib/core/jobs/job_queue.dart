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
    await repo.setProcessing(recordingId, ProcessingStatus.queued);
    _schedule();
  }

  /// User tapped "Retry processing".
  Future<void> retry(String recordingId) async {
    await analytics.log(AnalyticsEvent.processingRetried,
        recordingId: recordingId, props: {'manual': true});
    await enqueue(recordingId);
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
        final due = await _db.query('jobs',
            where: 'state = ? AND next_attempt_at <= ?',
            whereArgs: [JobState.pending.name, now],
            orderBy: 'next_attempt_at ASC',
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
      await repo.setProcessing(id, ProcessingStatus.done);
    } catch (e) {
      final failed = attempts + 1;
      final msg = _short(e);
      final isFinal = failed >= maxAutoAttempts;
      await analytics.log(AnalyticsEvent.processingFailed,
          recordingId: id,
          props: {'attempt': failed, 'final': isFinal, 'error': msg});
      if (isFinal) {
        await _setJob(id, JobState.failed, attempts: failed, error: msg);
        await repo.setProcessing(id, ProcessingStatus.failed, error: msg);
      } else {
        final wait = backoffFor(failed);
        await _setJob(id, JobState.pending,
            attempts: failed,
            error: msg,
            nextAt: _clock.now().add(wait));
        await repo.setProcessing(id, ProcessingStatus.queued,
            error: msg, progress: 'Will try again in ${wait.inSeconds} s');
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
