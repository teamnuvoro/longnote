import 'dart:async';
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:record/record.dart';

import '../config.dart';

/// Events from the audio system that the recording screen must explain.
enum InterruptionPhase { began, endedResumable, endedNotResumable }

/// Microphone PCM16 source. Abstract so the controller is testable without
/// platform plugins.
abstract class PcmSource {
  Future<bool> hasPermission({bool request = true});
  Future<Stream<Uint8List>> start();
  Future<void> pause();
  Future<void> resume();
  Future<void> stop();

  /// Input level in dBFS (about -60 silent .. 0 loud).
  Stream<double> levels();

  /// Phone call / Siri / another app took the microphone, and when it ended.
  Stream<InterruptionPhase> interruptions();

  /// true when the recorder is paused (by us or by the system).
  Stream<bool> pausedChanges();
  void dispose();
}

/// Real implementation: `record` in PCM16 stream mode (16 kHz mono) plus
/// `audio_session` for interruption events.
///
/// NOT DEVICE-TESTED: background capture with the screen locked relies on
/// UIBackgroundModes=audio (set in Info.plist) and an active record session.
class RecordPcmSource implements PcmSource {
  final AudioRecorder _rec = AudioRecorder();
  final _interruptions = StreamController<InterruptionPhase>.broadcast();
  StreamSubscription<AudioInterruptionEvent>? _sub;
  bool _sessionReady = false;

  Future<void> _ensureSession() async {
    if (_sessionReady) return;
    final session = await AudioSession.instance;
    // Same category/options that `record` sets, so the two never fight.
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions:
          AVAudioSessionCategoryOptions.defaultToSpeaker |
              AVAudioSessionCategoryOptions.allowBluetooth,
      avAudioSessionMode: AVAudioSessionMode.defaultMode,
    ));
    _sub = session.interruptionEventStream.listen((e) {
      if (e.begin) {
        _interruptions.add(InterruptionPhase.began);
      } else {
        _interruptions.add(e.type == AudioInterruptionType.pause
            ? InterruptionPhase.endedResumable
            : InterruptionPhase.endedNotResumable);
      }
    });
    _sessionReady = true;
  }

  @override
  Future<bool> hasPermission({bool request = true}) =>
      _rec.hasPermission(request: request);

  @override
  Future<Stream<Uint8List>> start() async {
    await _ensureSession();
    return _rec.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: AppConfig.sampleRate,
      numChannels: AppConfig.channels,
      // The recorder pauses on a call and resumes itself afterwards; we mark
      // the gap from the audio_session events.
      audioInterruption: AudioInterruptionMode.pauseResume,
      // Plugging/unplugging headphones moves to the new mic instead of
      // stopping a 3-hour lecture.
      audioRouteChange: AudioRouteChangeMode.follow,
      iosConfig: IosRecordConfig(categoryOptions: [
        IosAudioCategoryOption.defaultToSpeaker,
        IosAudioCategoryOption.allowBluetooth,
      ]),
    ));
  }

  @override
  Future<void> pause() => _rec.pause();
  @override
  Future<void> resume() => _rec.resume();
  @override
  Future<void> stop() async {
    await _rec.stop();
    // Give the microphone back: without this the session stays in
    // playAndRecord, iOS keeps the orange mic dot on, and note playback runs
    // in a recording session.
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      await session.setActive(false,
          avAudioSessionSetActiveOptions:
              AVAudioSessionSetActiveOptions.notifyOthersOnDeactivation);
    } catch (_) {
      // Best effort: a failure here must never lose the recording.
    }
    await _sub?.cancel();
    _sub = null;
    _sessionReady = false;
  }

  @override
  Stream<double> levels() => _rec
      .onAmplitudeChanged(const Duration(milliseconds: 150))
      .map((a) => a.current);

  @override
  Stream<InterruptionPhase> interruptions() => _interruptions.stream;

  @override
  Stream<bool> pausedChanges() =>
      _rec.onStateChanged().map((s) => s == RecordState.pause);

  @override
  void dispose() {
    _sub?.cancel();
    _interruptions.close();
    _rec.dispose();
  }
}
