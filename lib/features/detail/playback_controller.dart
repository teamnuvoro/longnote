import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

/// Plays the 5-minute WAV parts as one continuous recording and exposes a
/// single global position for the seek bar and transcript taps.
class PlaybackController extends ChangeNotifier {
  PlaybackController(this.paths, this.partDurationsMs);

  final List<String> paths;
  final List<int> partDurationsMs;
  final AudioPlayer _player = AudioPlayer();
  final List<StreamSubscription<Object?>> _subs = [];
  bool _loaded = false;
  String? error;

  int get totalMs => partDurationsMs.fold(0, (a, b) => a + b);

  int _offsetOf(int index) {
    var o = 0;
    for (var i = 0; i < index && i < partDurationsMs.length; i++) {
      o += partDurationsMs[i];
    }
    return o;
  }

  int get positionMs =>
      _offsetOf(_player.currentIndex ?? 0) + _player.position.inMilliseconds;

  bool get playing => _player.playing;

  Future<void> _ensureLoaded() async {
    if (_loaded || paths.isEmpty) return;
    try {
      // ignore: deprecated_member_use
      await _player.setAudioSource(ConcatenatingAudioSource(
        children: [for (final p in paths) AudioSource.file(p)],
      ));
      _subs.add(_player.positionStream.listen((_) => notifyListeners()));
      _subs.add(_player.playerStateStream.listen((_) => notifyListeners()));
      _loaded = true;
    } catch (e) {
      error = 'Could not open the audio: $e';
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    await _ensureLoaded();
    if (!_loaded) return;
    if (_player.playing) {
      await _player.pause();
    } else {
      if (_player.processingState == ProcessingState.completed) {
        await seekTo(0);
      }
      unawaited(_player.play());
    }
    notifyListeners();
  }

  /// Seeks to a position in the whole recording.
  Future<void> seekTo(int globalMs) async {
    await _ensureLoaded();
    if (!_loaded) return;
    var rest = globalMs.clamp(0, totalMs);
    var idx = 0;
    while (idx < partDurationsMs.length - 1 && rest >= partDurationsMs[idx]) {
      rest -= partDurationsMs[idx];
      idx++;
    }
    await _player.seek(Duration(milliseconds: rest), index: idx);
    notifyListeners();
  }

  Future<void> skip(int deltaMs) => seekTo(positionMs + deltaMs);

  Future<void> playFrom(int globalMs) async {
    await seekTo(globalMs);
    if (_loaded && !_player.playing) unawaited(_player.play());
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _player.dispose();
    super.dispose();
  }
}
