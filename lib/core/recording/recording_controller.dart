import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

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
    Clock clock = const SystemClock(),
    this.useTimers = true,
  }) : _clock = clock;

  final RecordingRepository repo;
  final Analytics analytics;
  final PcmSource Function() sourceFactory;

  /// Called after a recording is stopped and saved (enqueue processing,
  /// count the free recording, ...).
  final Future<void> Function(Recording r)? onFinished;
  final Clock _clock;

  /// Tests drive flush/heartbeat by hand.
  final bool useTimers;

  CaptureState state = CaptureState.idle;
  Recording? current;
  double levelDb = -60;

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
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
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
    notifyListeners();
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
      final dir = Directory(repo.storage.dirFor(rec.id));
      dir.createSync(recursive: true);

      final sink = SegmentedWavSink(
        directory: dir.path,
        segmentBytes: AppConfig.segmentBytes,
        flushInterval: AppConfig.flushInterval,
        clock: _clock,
        onSegmentOpened: (i, name, bytes) {
          repo.upsertSegment(AudioSegment(
              recordingId: rec.id, index: i, fileName: name));
          rec.segmentCount = i + 1;
          // Quiet: a new part every 5 minutes must not refresh the Notes
          // list under a running recording.
          repo.updateCapture(rec, notify: false);
        },
        onSegmentClosed: (i, name, bytes) {
          repo.upsertSegment(AudioSegment(
              recordingId: rec.id,
              index: i,
              fileName: name,
              dataBytes: bytes,
              closed: true));
        },
      )..open();

      _source = source;
      _sink = sink;
      current = rec;

      _intSub = source.interruptions().listen(_onInterruption);
      _levelSub = source.levels().listen((db) {
        levelDb = db;
        notifyListeners();
      });
      final stream = await source.start();
      _audioSub = stream.listen(_onAudio, onError: (Object e) {
        _fail('The microphone stopped working ($e). Everything up to now is saved.');
      });

      if (useTimers) {
        _flushTimer = Timer.periodic(AppConfig.flushInterval, (_) => tickFlush());
        _heartbeatTimer =
            Timer.periodic(AppConfig.heartbeatInterval, (_) => tickHeartbeat());
      }
      state = CaptureState.recording;
      await analytics.log(AnalyticsEvent.recordingStarted, recordingId: rec.id);
      notifyListeners();
      return rec;
    } catch (_) {
      state = CaptureState.idle;
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
      _fail(full
          ? 'Stopped: the phone is out of storage. Everything up to now is saved.'
          : 'Stopped: could not write audio (${e.message}). Everything up to now is saved.');
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
      _fail('Stopped: the phone is out of storage. Everything up to now is saved.');
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
    // Keep the open segment's byte count current too.
    await repo.upsertSegment(AudioSegment(
        recordingId: rec.id,
        index: sink.currentIndex,
        fileName: segmentFileName(sink.currentIndex),
        dataBytes: sink.currentSegmentBytes));
  }

  Future<void> pause() async {
    if (state != CaptureState.recording) return;
    _userPaused = true;
    await _source?.pause();
    _sink?.flushNow();
    await _setStatus(RecordingStatus.paused, CaptureState.paused);
  }

  Future<void> resume() async {
    if (state != CaptureState.paused) return;
    _userPaused = false;
    await _source?.resume();
    await _endGap();
    banner = null;
    await _setStatus(RecordingStatus.recording, CaptureState.recording);
  }

  Future<void> _setStatus(RecordingStatus s, CaptureState cs) async {
    final rec = current;
    if (rec == null) return;
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
        _openGapId = await repo.addGap(RecordingGap(
          recordingId: rec.id,
          atMs: sink.totalDuration.inMilliseconds,
          startedAt: _gapStartedAt!,
          reason: 'interruption',
        ));
        banner =
            'Paused by a phone call or another app. Audio up to now is saved.';
        await analytics.log(AnalyticsEvent.recordingInterrupted,
            recordingId: rec.id,
            props: {'cause': 'audio_interruption', 'at_ms': sink.totalDuration.inMilliseconds});
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
    try {
      await _source?.stop();
    } catch (_) {}
    await _audioSub?.cancel();
    await _levelSub?.cancel();
    await _intSub?.cancel();
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
    await repo.upsertSegment(AudioSegment(
        recordingId: rec.id,
        index: sink.currentIndex,
        fileName: segmentFileName(sink.currentIndex),
        dataBytes: lastBytes,
        closed: true));
    rec
      ..status = RecordingStatus.completed
      ..durationMs = sink.totalDuration.inMilliseconds
      ..heartbeatAt = _clock.now()
      ..segmentCount = sink.currentIndex + 1
      ..note = reason == 'error' ? banner : null;
    await repo.updateCapture(rec);
    await analytics.log(AnalyticsEvent.recordingCompleted,
        recordingId: rec.id,
        props: {'duration_ms': rec.durationMs, 'reason': reason});
    _source?.dispose();
    _source = null;
    _sink = null;
    current = null;
    state = CaptureState.idle;
    if (reason == 'user') banner = null;
    notifyListeners();
    await onFinished?.call(rec);
    return rec;
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _heartbeatTimer?.cancel();
    _source?.dispose();
    super.dispose();
  }
}
