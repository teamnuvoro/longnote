import 'dart:io';

import 'package:flutter/services.dart';

import 'summarizer.dart';
import 'summary_models.dart';

/// Apple Intelligence on-device model (FoundationModels framework, iOS 26+,
/// Apple Intelligence devices only) through a small Swift MethodChannel in
/// ios/Runner/AppleSummarizerPlugin.swift.
///
/// UNTESTED: the Swift side has never been compiled (no Xcode on the build
/// server). Every failure path returns "not available" so the app falls back
/// to another engine.
class AppleOnDeviceSummarizer implements Summarizer {
  AppleOnDeviceSummarizer({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'longnote/apple_summarizer';
  final MethodChannel _channel;
  bool? _available;

  @override
  String get id => 'apple';

  @override
  String get label => 'Apple Intelligence (on this phone)';

  /// The on-device model has a ~4k-token context window shared by
  /// instructions, input and output; ~6000 characters of input is safe.
  @override
  int get maxChunkChars => 6000;

  @override
  Future<bool> isAvailable() async {
    if (_available != null) return _available!;
    if (!Platform.isIOS) return _available = false;
    try {
      _available = await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (_) {
      _available = false; // MissingPluginException, old iOS, etc.
    }
    return _available!;
  }

  /// Why it is unavailable, for Settings ("device not eligible", "Apple
  /// Intelligence turned off", "model downloading", ...).
  Future<String?> unavailableReason() async {
    if (!Platform.isIOS) return 'Only on iPhone';
    try {
      return await _channel.invokeMethod<String>('unavailableReason');
    } catch (_) {
      return 'Needs iOS 26 and an Apple Intelligence iPhone';
    }
  }

  @override
  Future<MeetingSummary> summarizeChunk(String chunk,
      {required int part, required int parts}) async {
    final raw = await _channel.invokeMethod<String>('summarize', {
      'instructions': summaryInstructions,
      'prompt': summaryUserPrompt(chunk, part: part, parts: parts),
    });
    if (raw == null) throw SummaryParseException('empty response');
    return MeetingSummary.parse(raw);
  }
}
