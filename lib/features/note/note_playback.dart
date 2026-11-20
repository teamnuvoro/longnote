import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// The bits of an audio player the note screens need. The real one is
/// just_audio; widget tests use a fake.
abstract class AudioEngine {
  Future<void> load(List<String> paths);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(int partIndex, Duration position);
  Future<void> setSpeed(double speed);

  /// Fires whenever position / playing / part changes.
  Stream<void> get changes;
  int get partIndex;
  Duration get position;
  bool get playing;
  bool get completed;
  void dispose();
}

class JustAudioEngine implements AudioEngine {
  final _player = AudioPlayer();
  final _changes = StreamController<void>.broadcast();
  final _subs = <StreamSubscription<Object?>>[];

  @override
  Future<void> load(List<String> paths) async {
    // ignore: deprecated_member_use
    await _player.setAudioSource(ConcatenatingAudioSource(
        children: [for (final p in paths) AudioSource.file(p)]));
    _subs.add(_player.positionStream.listen((_) => _changes.add(null)));
    _subs.add(_player.playerStateStream.listen((_) => _changes.add(null)));
  }

  @override
  Future<void> play() async => unawaited(_player.play());
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(int partIndex, Duration position) =>
      _player.seek(position, index: partIndex);
  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);
  @override
  Stream<void> get changes => _changes.stream;
  @override
  int get partIndex => _player.currentIndex ?? 0;
  @override
  Duration get position => _player.position;
  @override
  bool get playing => _player.playing;
  @override
  bool get completed => _player.processingState == ProcessingState.completed;
  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _changes.close();
    _player.dispose();
  }
}

/// Plays a note's 5-minute WAV parts as one recording, with one global
/// position (ms) for the mini player, the full player and transcript taps.
class NotePlayback extends ChangeNotifier {
  NotePlayback(this.paths, this.partDurationsMs,
      {AudioEngine? engine, this.onStarted})
      : _engine = engine ?? engineFactory();

  /// Called once, the first time audio actually plays (playback_started).
  final void Function()? onStarted;
  bool _started = false;

  Future<void> _play() async {
    await _engine.play();
    if (_started) return;
    _started = true;
    onStarted?.call();
  }

  /// Swapped in widget tests.
  static AudioEngine Function() engineFactory = JustAudioEngine.new;

  static const speeds = [0.8, 1.0, 1.25, 1.5, 2.0];

  final List<String> paths;
  final List<int> partDurationsMs;
  final AudioEngine _engine;
  StreamSubscription<void>? _sub;
  Future<void>? _loading;
  bool _loaded = false;
  bool _disposed = false;
  int? _clipEndMs;
  String? error;
  double speed = 1.0;

  /// Position to show before the audio is loaded (e.g. "open at 14:19").
  int _pendingMs = 0;

  int get totalMs => partDurationsMs.fold(0, (a, b) => a + b);
  bool get hasAudio => paths.isNotEmpty;
  bool get playing => _loaded && _engine.playing;

  int _offsetOf(int index) {
    var o = 0;
    for (var i = 0; i < index && i < partDurationsMs.length; i++) {
      o += partDurationsMs[i];
    }
    return o;
  }

  int get positionMs {
    if (!_loaded) return _pendingMs;
    final p = _offsetOf(_engine.partIndex) + _engine.position.inMilliseconds;
    return p.clamp(0, totalMs);
  }

  Future<void> _ensureLoaded() {
    if (_loaded || paths.isEmpty) return Future.value();
    return _loading ??= () async {
      try {
        await _engine.load(paths);
        _sub = _engine.changes.listen((_) => _onTick());
        _loaded = true;
        if (speed != 1.0) await _engine.setSpeed(speed);
        if (_pendingMs > 0) await _seekLoaded(_pendingMs);
      } catch (e) {
        error = 'Could not open the audio.';
        _loading = null;
      }
      _notify();
    }();
  }

  void _onTick() {
    final end = _clipEndMs;
    if (end != null && _engine.playing && positionMs >= end) {
      _clipEndMs = null;
      _engine.pause();
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> toggle() async {
    await _ensureLoaded();
    if (!_loaded) return;
    _clipEndMs = null;
    if (_engine.playing) {
      await _engine.pause();
    } else {
      if (_engine.completed) await _seekLoaded(0);
      await _play();
    }
    _notify();
  }

  Future<void> pause() async {
    if (_loaded && _engine.playing) await _engine.pause();
    _notify();
  }

  Future<void> _seekLoaded(int globalMs) async {
    var rest = globalMs.clamp(0, totalMs);
    var idx = 0;
    while (idx < partDurationsMs.length - 1 && rest >= partDurationsMs[idx]) {
      rest -= partDurationsMs[idx];
      idx++;
    }
    await _engine.seek(idx, Duration(milliseconds: rest));
  }

  /// Seeks without loading the audio when it is not loaded yet (cheap; used
  /// when a note opens at a search hit).
  Future<void> seekTo(int globalMs, {bool load = true}) async {
    if (!_loaded && !load) {
      _pendingMs = globalMs.clamp(0, totalMs);
      _notify();
      return;
    }
    _pendingMs = globalMs.clamp(0, totalMs);
    await _ensureLoaded();
    if (_loaded) await _seekLoaded(globalMs);
    _notify();
  }

  Future<void> skip(int deltaMs) => seekTo(positionMs + deltaMs);

  Future<void> playFrom(int globalMs) async {
    _clipEndMs = null;
    await seekTo(globalMs);
    if (_loaded && !_engine.playing) await _play();
    _notify();
  }

  /// Plays [startMs]..[endMs] then pauses (D4 "play a clip of this voice").
  Future<void> playClip(int startMs, int endMs) async {
    await playFrom(startMs);
    _clipEndMs = endMs;
  }

  Future<void> setSpeed(double s) async {
    speed = s;
    if (_loaded) await _engine.setSpeed(s);
    _notify();
  }

  /// Mini player speed chip: 1 -> 1.25 -> 1.5 -> 2 -> 0.8 -> 1.
  Future<void> cycleSpeed() {
    final i = speeds.indexOf(speed);
    return setSpeed(speeds[(i + 1) % speeds.length]);
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _engine.dispose();
    super.dispose();
  }
}

/// One [NotePlayback] per open note, shared by the note screen and the
/// sheets pushed over it (D4 clips, D7 full player). Reference counted.
abstract final class NotePlaybacks {
  static final _items = <String, (NotePlayback, int)>{};

  static NotePlayback acquire(String id, NotePlayback Function() create) {
    final e = _items[id];
    if (e != null) {
      _items[id] = (e.$1, e.$2 + 1);
      return e.$1;
    }
    final p = create();
    _items[id] = (p, 1);
    return p;
  }

  static NotePlayback? peek(String id) => _items[id]?.$1;

  static void release(String id) {
    final e = _items[id];
    if (e == null) return;
    if (e.$2 <= 1) {
      _items.remove(id);
      e.$1.dispose();
    } else {
      _items[id] = (e.$1, e.$2 - 1);
    }
  }
}

/// Peak levels (0..1) at [bars] evenly spaced points of the note's WAV
/// parts. Reads a small window at each point, so it is cheap even for a
/// 3-hour note. Runs off the UI isolate.
Future<List<double>> waveformPeaks(List<String> paths, List<int> partMs,
    {int bars = 58}) async {
  if (paths.isEmpty) return const [];
  try {
    return await Isolate.run(() => _peaks(paths, partMs, bars));
  } catch (_) {
    return const [];
  }
}

List<double> _peaks(List<String> paths, List<int> partMs, int bars) {
  final total = partMs.fold(0, (a, b) => a + b);
  if (total <= 0) return const [];
  const header = 44;
  const bytesPerMs = 32; // 16 kHz mono 16-bit
  const window = 1600; // 800 samples = 50 ms
  final files = [for (final p in paths) File(p).openSync()];
  final out = <double>[];
  try {
    for (var b = 0; b < bars; b++) {
      var at = ((b + 0.5) / bars * total).floor();
      var part = 0;
      while (part < partMs.length - 1 && at >= partMs[part]) {
        at -= partMs[part];
        part++;
      }
      final f = files[part];
      final off = header + at * bytesPerMs;
      final len = f.lengthSync();
      if (off >= len) {
        out.add(0);
        continue;
      }
      f.setPositionSync(off & ~1);
      final bytes = f.readSync(window);
      final data = ByteData.sublistView(bytes);
      var peak = 0;
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        final v = data.getInt16(i, Endian.little).abs();
        if (v > peak) peak = v;
      }
      out.add(peak / 32768);
    }
  } finally {
    for (final f in files) {
      f.closeSync();
    }
  }
  // Normalise so quiet recordings still show a shape.
  final max = out.fold<double>(0, (a, b) => a > b ? a : b);
  return max <= 0 ? out : [for (final v in out) v / max];
}
