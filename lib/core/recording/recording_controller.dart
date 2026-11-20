import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../diagnostics/crash_reporter.dart';
import '../analytics/analytics.dart';
import '../audio/pcm_source.dart';
import '../audio/segment_writer.dart';
import '../config.dart';
import '../models/recording.dart';
import '../util/clock.dart';
import 'recording_repository.dart';

enum CaptureState { idle, starting, recording, paused, stopping }

/// Runs one live recording: microphone -> rotating WAV segments on disk,
/// with DB heartbeat, pause/resume, interruption gaps and honest status text.
class RecordingController extends ChangeNotifier {
  RecordingController({
    required this.repo,
    required this.analytics,
    required this.sourceFactory,
    this.onFinished,
    this.onStopFailed,
    Clock clock = const SystemClock(),
    this.useTimers = true,
  }) : _clock = clock;

  final RecordingRepository repo;
  final Analytics analytics;
  final PcmSource Function() sourceFactory;

  /// Called after a recording is stopped and saved (enqueue processing,
  /// count the free recording, ...).
  final Future<void> Function(Recording r)? onFinished;

  /// Called when Stop could not save the ending (disk full); the note is
  /// repaired at the next launch. Lets the app resume paused processing.
  final void Function()? onStopFailed;
  final Clock _clock;

  /// Tests drive flush/heartbeat by hand.
  final bool useTimers;

  CaptureState state = CaptureState.idle;
  Recording? current;
  /// Input level in dBFS, ~7 updates a second. A separate notifier so only
  /// the waveform repaints (the rest of the recording screen follows the
  /// once-a-second flush notification).
  final ValueNotifier<double> level = ValueNotifier(-60);
  double get levelDb => level.value;

  /// Honest banner text for interruptions/errors; null when all is well.
  String? banner;

  /// Time of the last fsync, for the "Saved on this phone" indicator.
  DateTime? lastSavedAt;

  PcmSource? _source;
  SegmentedWavSink? _sink;
  StreamSubscription<Uint8List>? _audioSub;
  StreamSubscription<double>? _levelSub;
  StreamSubscription<InterruptionPhase>? _intSub;
  Timer? _flushTimer;
  Timer? _heartbeatTimer;
  int? _openGapId;
  DateTime? _gapStartedAt;
  bool _userPaused = false;

  Duration get elapsed => _sink?.totalDuration ?? Duration.zero;
  bool get isActive =>
      state == CaptureState.recording || state == CaptureState.paused;

  static String defaultTitle(DateTime t) {
    const m = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return 'Recording ${t.day} ${m[t.month - 1]}, $hh:$mm';
  }

  /// Starts capture. Throws [StateError] if already recording or the mic
  /// permission is missing. The paywall check happens before this is called.
  Future<Recording> start({String? title}) async {
    if (state != CaptureState.idle) throw StateError('already recording');
    state = CaptureState.starting;
    banner = null;
    // Nothing from the last recording carries over (a Pause before Stop left
    // _userPaused set, which made the next call never resume by itself).
    _userPaused = false;
    _openGapId = null;
    _gapStartedAt = null;
    notifyListeners();
    String? insertedId;
    try {
      final source = sourceFactory();
      if (!await source.hasPermission()) {
        source.dispose();
        throw StateError('microphone permission denied');
      }
      final now = _clock.now();
      final rec = Recording(
        id: const Uuid().v4(),
        title: title ?? defaultTitle(now),
        createdAt: now,
        status: RecordingStatus.recording,
        heartbeatAt: now,
      );
      await repo.insert(rec);
      insertedId = rec.id;
      final dir = Directory(repo.storage.dirFor(rec.id));
      dir.createSync(recursive: true);

      final sink = SegmentedWavSink(
        directory: dir.path,
        segmentBytes: AppConfig.segmentBytes,
        flushInterval: AppConfig.flushInterval,
        clock: _clock,
        onSegmentOpened: (i, name, bytes) {
          repo.upsertSegment(
            AudioSegment(recordingId: rec.id, index: i, fileName: name),
          );
          rec.segmentCount = i + 1;
          // Quiet: a new part every 5 minutes must not refresh the Notes
          // list under a running recording.
          repo.updateCapture(rec, notify: false);
        },
        onSegmentClosed: (i, name, bytes) {
          repo.upsertSegment(
            AudioSegment(
              recordingId: rec.id,
              index: i,
              fileName: name,
              dataBytes: bytes,
              closed: true,
            ),
          );
        },
      )..open();

      _source = source;
      _sink = sink;
      current = rec;

      _intSub = source.interruptions().listen(_onInterruption);
      _levelSub = source.levels().listen((db) => level.value = db);
      final stream = await source.start();
      _audioSub = stream.listen(
        _onAudio,
        onError: (Object e) {
          _fail(
            'The microphone stopped working ($e). Everything up to now is saved.',
          );
        },
      );

      if (useTimers) {
        _flushTimer = Timer.periodic(
          AppConfig.flushInterval,
          (_) => tickFlush(),
        );
        _heartbeatTimer = Timer.periodic(
          AppConfig.heartbeatInterval,
          (_) => tickHeartbeat(),
        );
      }
      state = CaptureState.recording;
      // Never awaited on the capture path: a slow analytics sink must not
      // hold Start, Pause, Resume or Stop.
      unawaited(
          analytics.log(AnalyticsEvent.recordingStarted, recordingId: rec.id));
      notifyListeners();
      return rec;
    } catch (_) {
      // The source failed to start: free the file, the mic and the
      // listeners, and remove the empty row (no audio was captured) so
      // Notes shows no ghost "recording" after a failed Start.
      _flushTimer?.cancel();
      _heartbeatTimer?.cancel();
      await _intSub?.cancel();
      await _levelSub?.cancel();
      _intSub = null;
      _levelSub = null;
      try {
        _sink?.close();
      } catch (_) {}
      try {
        _source?.dispose();
      } catch (_) {}
      _sink = null;
      _source = null;
      current = null;
      state = CaptureState.idle;
      if (insertedId != null) {
        try {
          await repo.deleteByUser(insertedId);
        } catch (_) {/* repaired at next launch as before */}
      }
      notifyListeners();
      rethrow;
    }
  }

  void _onAudio(Uint8List chunk) {
    final sink = _sink;
    if (sink == null) return;
    try {
      sink.add(chunk);
    } on FileSystemException catch (e) {
      final full = e.osError?.errorCode == 28; // ENOSPC
      _fail(
        full
            ? 'Stopped: the phone is out of storage. Everything up to now is saved.'
            : 'Stopped: could not write audio (${e.message}). Everything up to now is saved.',
      );
    }
  }

  /// Called every ~1 s: flush to disk and update the "saved" indicator.
  void tickFlush() {
    final sink = _sink;
    if (sink == null) return;
    try {
      sink.maybeFlush();
      lastSavedAt = _clock.now();
    } on FileSystemException {
      _fail(
        'Stopped: the phone is out of storage. Everything up to now is saved.',
      );
      return;
    }
    notifyListeners();
  }

  /// Called every ~5 s: heartbeat + duration in the database.
  Future<void> tickHeartbeat() async {
    final rec = current;
    final sink = _sink;
    if (rec == null || sink == null) return;
    rec.heartbeatAt = _clock.now();
    rec.durationMs = sink.totalDuration.inMilliseconds;
    await repo.heartbeat(rec.id, rec.heartbeatAt!, rec.durationMs);
    // Stop may have run while we waited: it closed the sink (its byte count
    // is now 0) and wrote the final segment row. Writing now would set that
    // row to 0 bytes and the note would fail with "No audio was saved".
    if (!identical(_sink, sink) || !isActive) return;
    // Keep the open segment's byte count current too.
    await repo.upsertSegment(
      AudioSegment(
        recordingId: rec.id,
        index: sink.currentIndex,
        fileName: segmentFileName(sink.currentIndex),
        dataBytes: sink.currentSegmentBytes,
      ),
    );
  }

  Future<void> pause() async {
    if (state != CaptureState.recording) return;
    _userPaused = true;
    await _source?.pause();
    _sink?.flushNow();
    await _setStatus(RecordingStatus.paused, CaptureState.paused);
    unawaited(
        analytics.log(AnalyticsEvent.recordingPaused, recordingId: current?.id));
  }

  Future<void> resume() async {
    if (state != CaptureState.paused) return;
    _userPaused = false;
    await _source?.resume();
    await _endGap();
    banner = null;
    await _setStatus(RecordingStatus.recording, CaptureState.recording);
    unawaited(analytics.log(AnalyticsEvent.recordingResumed,
        recordingId: current?.id));
  }

  Future<void> _setStatus(RecordingStatus s, CaptureState cs) async {
    final rec = current;
    // Stop (or a failed Start) owns the ending: a pause/resume/interruption
    // that resumes after an await must not reopen the recorder.
    if (rec == null || !isActive) return;
    rec.status = s;
    state = cs;
    await repo.updateCapture(rec);
    notifyListeners();
  }

  Future<void> _onInterruption(InterruptionPhase p) async {
    final rec = current;
    final sink = _sink;
    if (rec == null || sink == null) return;
    switch (p) {
      case InterruptionPhase.began:
        sink.flushNow();
        if (_openGapId != null) return;
        _gapStartedAt = _clock.now();
        final gapId = await repo.addGap(
          RecordingGap(
            recordingId: rec.id,
            atMs: sink.totalDuration.inMilliseconds,
            startedAt: _gapStartedAt!,
            reason: 'interruption',
          ),
        );
        if (!isActive || !identical(_sink, sink)) {
          // Stop ran while the gap was being saved: close it right away.
          await repo.endGap(gapId, _clock.now());
          // Clear our start time unless a new recording already owns it.
          if (_sink == null || identical(_sink, sink)) _gapStartedAt = null;
          return;
        }
        _openGapId = gapId;
        banner =
            'Paused by a phone call or another app. Audio up to now is saved.';
        unawaited(analytics.log(
          AnalyticsEvent.recordingInterrupted,
          recordingId: rec.id,
          props: {
            'cause': 'audio_interruption',
            'at_ms': sink.totalDuration.inMilliseconds,
          },
        ));
        await _setStatus(RecordingStatus.paused, CaptureState.paused);
      case InterruptionPhase.endedResumable:
        if (_userPaused) return;
        try {
          await _source?.resume(); // no-op if the recorder already resumed
        } catch (_) {}
        final gap = await _endGap();
        banner = gap == null
            ? null
            : 'Recording resumed. ${_gapText(gap)} was not recorded during the interruption.';
        await _setStatus(RecordingStatus.recording, CaptureState.recording);
      case InterruptionPhase.endedNotResumable:
        banner =
            'Recording is paused after an interruption. Tap Resume to continue.';
        notifyListeners();
    }
  }

  String _gapText(Duration d) =>
      d.inSeconds < 60 ? 'About ${d.inSeconds} s' : 'About ${formatMinutes(d)}';

  Future<Duration?> _endGap() async {
    final id = _openGapId;
    final started = _gapStartedAt;
    if (id == null || started == null) return null;
    _openGapId = null;
    _gapStartedAt = null;
    final now = _clock.now();
    await repo.endGap(id, now);
    return now.difference(started);
  }

  void _fail(String message) {
    banner = message;
    notifyListeners();
    stop(reason: 'error');
  }

  /// Stops, finalizes the WAV headers and marks the recording completed.
  Future<Recording?> stop({String reason = 'user'}) async {
    if (!isActive || current == null || _sink == null) return null;
    state = CaptureState.stopping;
    notifyListeners();
    _flushTimer?.cancel();
    _heartbeatTimer?.cancel();
    final rec = current!;
    // No interruption events once Stop has begun. cancel() takes effect at
    // once; its future (source cleanup) is not waited for.
    unawaited(_intSub?.cancel());
    _intSub = null;
    try {
      await _source?.stop();
    } catch (_) {}
    var saved = false;
    try {
      await _audioSub?.cancel();
      await _levelSub?.cancel();
      final sink = _sink!;
      final lastBytes = sink.currentSegmentBytes;
      try {
        sink.close();
      } on FileSystemException {
        // Header could not be finalized (disk full). Recovery-style repair on
        // next launch is not needed: sizes were written at the last flush.
      }
      await _endGap();
      // Final segment row with exact size.
      await repo.upsertSegment(
        AudioSegment(
          recordingId: rec.id,
          index: sink.currentIndex,
          fileName: segmentFileName(sink.currentIndex),
          dataBytes: lastBytes,
          closed: true,
        ),
      );
      rec
        ..status = RecordingStatus.completed
        ..durationMs = sink.totalDuration.inMilliseconds
        ..heartbeatAt = _clock.now()
        ..segmentCount = sink.currentIndex + 1
        ..note = reason == 'error' ? banner : null;
      await repo.updateCapture(rec);
      saved = true;
      unawaited(analytics.log(
        AnalyticsEvent.recordingCompleted,
        recordingId: rec.id,
        props: {'duration_ms': rec.durationMs, 'reason': reason},
      ));
    } catch (e, st) {
      // Disk full / database error: the audio files are on disk and the row
      // is repaired at the next launch (RecoveryService). Never leave the
      // recorder stuck in "stopping" with the microphone open.
      CrashReporter.instance?.record('stop_failed', e, st);
      banner =
          'Recording stopped. It will be repaired when you reopen Longnote.';
    } finally {
      try {
        _source?.dispose();
      } catch (_) {}
      _source = null;
      _sink = null;
      current = null;
      state = CaptureState.idle;
      if (reason == 'user' && saved) banner = null;
    }
    // Queue the note before telling the screens we are idle, so the
    // recording screen never flashes "Recording stopped" after a user Stop.
    if (saved) {
      try {
        await onFinished?.call(rec);
      } catch (e, st) {
        CrashReporter.instance?.record('on_finished_failed', e, st);
      }
    }
    if (!saved) {
      try {
        onStopFailed?.call();
      } catch (_) {}
    }
    notifyListeners();
    if (!saved) return null;
    return rec;
  }

  @override
  void dispose() {
    level.dispose();
    _flushTimer?.cancel();
    _heartbeatTimer?.cancel();
    _source?.dispose();
    super.dispose();
  }
}
