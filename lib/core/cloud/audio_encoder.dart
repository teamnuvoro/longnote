import 'package:flutter/services.dart';

class EncodedAudio {
  const EncodedAudio({required this.durationMs, required this.bytes});
  final int durationMs;
  final int bytes;
}

/// Joins audio files and encodes them to AAC-LC m4a (mono, 16 kHz, ~32 kbps,
/// ~14.4 MB per hour), the upload format of BACKEND-API 2. Inputs are never
/// changed or deleted.
abstract class AudioEncoder {
  /// Encodes the time range [startMs, startMs + durationMs) of the
  /// concatenation of [inputs] (any format iOS can read: our WAV parts,
  /// m4a, mp3, a video's sound) into [output] (overwritten).
  Future<EncodedAudio> encodeM4a({
    required List<String> inputs,
    required String output,
    int startMs = 0,
    int? durationMs,
  });
}

class AudioEncodeException implements Exception {
  AudioEncodeException(this.message);
  final String message;
  @override
  String toString() => 'Audio encode failed: $message';
}

/// iOS: `AudioEncoderPlugin` in ios/Runner/AppDelegate.swift
/// (AVMutableComposition -> AVAssetReader (LPCM 16 kHz mono) -> AVAssetWriter
/// (AAC)). Channel "longnote/audio_encoder".
class NativeAudioEncoder implements AudioEncoder {
  const NativeAudioEncoder();
  static const _channel = MethodChannel('longnote/audio_encoder');

  @override
  Future<EncodedAudio> encodeM4a({
    required List<String> inputs,
    required String output,
    int startMs = 0,
    int? durationMs,
  }) async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('encodeM4a', {
        'inputs': inputs,
        'output': output,
        'startMs': startMs,
        'durationMs': ?durationMs,
        'sampleRate': 16000,
        'bitRate': 32000,
      });
      if (r == null) throw AudioEncodeException('no result');
      return EncodedAudio(
          durationMs: (r['durationMs'] as num).toInt(),
          bytes: (r['bytes'] as num).toInt());
    } on PlatformException catch (e) {
      throw AudioEncodeException('${e.code}: ${e.message}');
    } on MissingPluginException {
      throw AudioEncodeException('no native encoder on this platform');
    }
  }
}
