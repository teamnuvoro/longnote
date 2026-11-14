import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:whisper_ggml/whisper_ggml.dart';

import '../models/recording.dart';
import 'transcriber.dart';

/// Which whisper model to use. Default: base.en (148 MB, English only).
/// Multilingual options use language auto-detection.
enum WhisperChoice {
  baseEn(WhisperModel.baseEn, 'Base (English)', '148 MB', 'en'),
  base(WhisperModel.base, 'Base (many languages)', '148 MB', 'auto'),
  smallEn(WhisperModel.smallEn, 'Small (English, more accurate)', '488 MB', 'en'),
  small(WhisperModel.small, 'Small (many languages)', '488 MB', 'auto');

  const WhisperChoice(this.model, this.label, this.size, this.lang);
  final WhisperModel model;
  final String label;
  final String size;
  final String lang;

  static WhisperChoice parse(String? s) => WhisperChoice.values
      .firstWhere((e) => e.name == s, orElse: () => WhisperChoice.baseEn);
}

/// On-device transcription with whisper.cpp through the `whisper_ggml` FFI
/// plugin. UNVERIFIED ON DEVICE: written against whisper_ggml 2.9.0's public
/// API; it has not been built or run on an iPhone yet.
class WhisperTranscriber implements Transcriber {
  WhisperTranscriber({required this.choice, http.Client? client})
      : _client = client ?? http.Client();

  final WhisperChoice choice;
  final http.Client _client;
  final WhisperController _controller = WhisperController();

  /// Live model status for the UI (download progress etc.).
  final ValueNotifier<ModelStatus> status =
      ValueNotifier(const ModelStatus(ready: false));

  Future<void>? _downloading;

  @override
  String get name => 'whisper-${choice.model.modelName}';

  Future<String> modelPath() => _controller.getPath(choice.model);

  @override
  Future<bool> isReady() async {
    final f = File(await modelPath());
    final ok = f.existsSync() && f.lengthSync() > 1024 * 1024;
    if (ok && !status.value.ready) {
      status.value = ModelStatus(ready: true, sizeLabel: choice.size);
    }
    return ok;
  }

  @override
  Future<void> ensureReady({void Function(double progress)? onProgress}) {
    return _downloading ??= _download(onProgress).whenComplete(() {
      _downloading = null;
    });
  }

  Future<void> _download(void Function(double)? onProgress) async {
    if (await isReady()) {
      onProgress?.call(1);
      return;
    }
    final target = File(await modelPath());
    target.parent.createSync(recursive: true);
    final part = File('${target.path}.part');
    status.value =
        ModelStatus(ready: false, downloading: true, sizeLabel: choice.size);
    try {
      final req = http.Request('GET', choice.model.modelUri);
      final resp = await _client.send(req);
      if (resp.statusCode != 200) {
        throw TranscriptionException(
            'Model download failed (HTTP ${resp.statusCode})');
      }
      final total = resp.contentLength ?? 0;
      var got = 0;
      final sink = part.openWrite();
      try {
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) {
            final p = got / total;
            onProgress?.call(p);
            status.value = ModelStatus(
                ready: false,
                downloading: true,
                progress: p,
                sizeLabel: choice.size);
          }
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (total > 0 && got != total) {
        throw TranscriptionException('Model download was cut off');
      }
      part.renameSync(target.path);
      status.value = ModelStatus(ready: true, sizeLabel: choice.size);
      onProgress?.call(1);
    } catch (e) {
      if (part.existsSync()) part.deleteSync();
      status.value = ModelStatus(
          ready: false, error: e.toString(), sizeLabel: choice.size);
      rethrow;
    }
  }

  @override
  Future<List<TranscriptLine>> transcribeFile(String wavPath,
      {required int offsetMs, required int segmentIndex}) async {
    await ensureReady();
    final result = await _controller.transcribe(
      model: choice.model,
      audioPath: wavPath,
      lang: choice.lang,
      withSegments: true,
      // Decode each 30 s window on its own so one hallucinated phrase cannot
      // repeat through a long recording (whisper_ggml README advice).
      maxContext: 0,
      // Keep the model in memory between the 5-minute parts of one recording.
      keepModelLoaded: true,
    );
    // whisper_ggml swallows native errors and returns null.
    if (result == null) {
      throw TranscriptionException('whisper returned no result');
    }
    final segs = result.transcription.segments;
    if (segs == null || segs.isEmpty) {
      final text = result.transcription.text.trim();
      if (text.isEmpty) return const [];
      return [
        TranscriptLine(
            startMs: offsetMs,
            endMs: offsetMs,
            text: text,
            segmentIndex: segmentIndex)
      ];
    }
    return [
      for (final s in segs)
        if (s.text.trim().isNotEmpty && !_isNoise(s.text))
          TranscriptLine(
            startMs: offsetMs + s.fromTs.inMilliseconds,
            endMs: offsetMs + s.toTs.inMilliseconds,
            text: s.text.trim(),
            segmentIndex: segmentIndex,
          ),
    ];
  }

  /// Drop "[BLANK_AUDIO]" style markers; keep real bracketed sounds out of
  /// the summary input too.
  static bool _isNoise(String t) {
    final s = t.trim();
    return s == '[BLANK_AUDIO]' || s == '(silence)' || s == '[ Silence ]';
  }

  /// Free the parked model when a recording is done (~150-500 MB of RAM).
  @override
  Future<void> releaseResources() => _controller.releaseModel();
}
