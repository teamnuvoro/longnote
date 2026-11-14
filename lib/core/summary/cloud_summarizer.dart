import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart';
import 'summarizer.dart';
import 'summary_models.dart';

class CloudSummaryException implements Exception {
  CloudSummaryException(this.message);
  final String message;
  @override
  String toString() => 'Cloud summary failed: $message';
}

/// Sends transcript text (never audio) to our own backend
/// (supabase/functions/summarize), which calls the AI provider with a key
/// that only the server has. Off unless CLOUD_SUMMARY_URL is set at build time
/// AND the user picks "Cloud" in Settings.
class CloudSummarizer implements Summarizer {
  CloudSummarizer({
    String? url,
    String? publicKey,
    http.Client? client,
    this.timeout = const Duration(seconds: 90),
  })  : url = url ?? AppConfig.cloudSummaryUrl,
        publicKey = publicKey ?? AppConfig.cloudSummaryPublicKey,
        _client = client ?? http.Client();

  final String url;
  final String publicKey;
  final http.Client _client;
  final Duration timeout;

  @override
  String get id => 'cloud';

  @override
  String get label => 'Cloud summary';

  /// ~25k tokens per call keeps latency and cost predictable; a 3-hour
  /// meeting is 2-3 calls.
  @override
  int get maxChunkChars => 100000;

  @override
  Future<bool> isAvailable() async => url.isNotEmpty;

  @override
  Future<MeetingSummary> summarizeChunk(String chunk,
      {required int part, required int parts}) async {
    if (url.isEmpty) throw CloudSummaryException('not configured');
    final resp = await _client
        .post(
          Uri.parse(url),
          headers: {
            'Content-Type': 'application/json',
            if (publicKey.isNotEmpty) 'Authorization': 'Bearer $publicKey',
            if (publicKey.isNotEmpty) 'apikey': publicKey,
          },
          body: jsonEncode({'transcript': chunk, 'part': part, 'parts': parts}),
        )
        .timeout(timeout);
    if (resp.statusCode != 200) {
      throw CloudSummaryException('HTTP ${resp.statusCode}');
    }
    final body = utf8.decode(resp.bodyBytes);
    // Server returns {"summary": {...}}; parse defensively either way.
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['summary'] != null) {
        final s = decoded['summary'];
        return MeetingSummary.parse(s is String ? s : jsonEncode(s));
      }
    } catch (_) {}
    return MeetingSummary.parse(body);
  }
}
