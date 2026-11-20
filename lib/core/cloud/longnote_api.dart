import 'dart:convert';

import 'package:http/http.dart' as http;

import '../notes/chat.dart';
import 'api_error.dart';
import 'backend_config.dart';
import 'supabase_auth.dart';

/// Reply of transcribe-start.
class StartResult {
  StartResult(this.jobId, this.status);
  final String jobId;
  final String status;
}

/// One turn as the server sends it.
class ServerTurn {
  ServerTurn(
      {required this.speaker,
      required this.startMs,
      required this.endMs,
      required this.text,
      this.language});
  final String speaker;
  final int startMs;
  final int endMs;
  final String text;
  final String? language;

  static ServerTurn? tryParse(Object? v) {
    if (v is! Map) return null;
    int? n(Object? x) => x is num ? x.toInt() : int.tryParse('$x');
    final s = n(v['start_ms']);
    final e = n(v['end_ms']);
    final t = v['text'];
    if (s == null || t is! String) return null;
    return ServerTurn(
      speaker: '${v['speaker'] ?? '1'}',
      startMs: s,
      endMs: e ?? s,
      text: t,
      language: v['language'] as String?,
    );
  }
}

/// Reply of transcribe-status.
class StatusResult {
  StatusResult({
    required this.status,
    this.jobId,
    this.providerStatus,
    this.turns,
    this.audioDurationMs,
    this.errorCode,
    this.errorMessage,
    this.raw = const {},
  });

  /// uploaded | transcribing | done | fetched | failed
  final String status;
  final String? jobId;
  final String? providerStatus;

  /// Only on `done` (the first fetch and repeats until the ack, at most 24 h after the first fetch).
  final List<ServerTurn>? turns;
  final int? audioDurationMs;
  final String? errorCode;
  final String? errorMessage;
  final Map<String, Object?> raw;

  factory StatusResult.fromJson(Map<String, Object?> m) {
    final result = m['result'];
    final err = m['error'];
    List<ServerTurn>? turns;
    int? dur;
    if (result is Map) {
      final t = result['turns'];
      turns = t is List ? [for (final x in t) ?ServerTurn.tryParse(x)] : const [];
      dur = (result['audio_duration_ms'] as num?)?.toInt();
    }
    return StatusResult(
      status: '${m['status'] ?? ''}',
      jobId: m['job_id'] as String?,
      providerStatus: m['provider_status'] as String?,
      turns: turns,
      audioDurationMs: dur,
      errorCode: err is Map ? err['code'] as String? : null,
      errorMessage: err is Map ? err['message'] as String? : null,
      raw: m,
    );
  }
}

/// Reply of ask.
class AskReply {
  AskReply(
      {required this.answer,
      required this.found,
      required this.sources,
      required this.truncated});
  final String answer;
  final bool found;
  final List<AskSource> sources;
  final bool truncated;

  /// Lenient parse: missing fields become empty/false; bad sources dropped.
  factory AskReply.fromJson(Map<String, Object?> m) {
    final src = m['sources'];
    return AskReply(
      answer: '${m['answer'] ?? ''}'.trim(),
      found: m['found'] == true,
      sources: src is List ? [for (final s in src) ?AskSource.tryParse(s)] : const [],
      truncated: m['truncated'] == true,
    );
  }
}

/// The four edge functions (BACKEND-API 4). Every call sends the signed-in
/// user's JWT (`Authorization: Bearer <user token>`) and the anon key as
/// `apikey`. A 401 refreshes the token once and retries.
class LongnoteApi {
  LongnoteApi({
    required this.config,
    required this.auth,
    http.Client? client,
    this.timeout = const Duration(seconds: 90),
  }) : _client = client ?? http.Client();

  final BackendConfig config;
  final SupabaseAuth auth;
  final http.Client _client;
  final Duration timeout;

  Future<Map<String, Object?>> call(String fn, Map<String, Object?> body,
      {Duration? timeout}) async {
    for (var attempt = 0;; attempt++) {
      final token = await auth.accessToken();
      final r = await _client
          .post(config.function(fn),
              headers: {
                'Authorization': 'Bearer $token',
                'apikey': config.anonKey,
                'Content-Type': 'application/json',
              },
              body: jsonEncode(body))
          .timeout(timeout ?? this.timeout);
      if (r.statusCode == 401 && attempt == 0) {
        await auth.invalidate();
        continue;
      }
      // Still rejected with a fresh token: the user may be gone on the
      // server (or the signing key changed). Start a new one if GoTrue
      // confirms it; the pipeline re-sends work of the old user.
      if (r.statusCode == 401 && attempt == 1 && await auth.replaceIfRejected()) {
        continue;
      }
      final text = utf8.decode(r.bodyBytes);
      Map<String, Object?>? json;
      try {
        final d = jsonDecode(text);
        if (d is Map) json = d.cast<String, Object?>();
      } catch (_) {}
      if (r.statusCode == 200 && json != null) return json;
      final err = json?['error'];
      if (err is Map) {
        final detail = err['detail'];
        throw ApiException('${err['code'] ?? 'server_error'}', err['message'] as String?,
            httpStatus: r.statusCode,
            detail: detail is Map ? detail.cast<String, Object?>() : const {});
      }
      throw ApiException(
          r.statusCode >= 500 ? 'server_error' : 'bad_request', 'HTTP ${r.statusCode}',
          httpStatus: r.statusCode);
    }
  }

  Future<StartResult> transcribeStart({
    required String clientNoteId,
    required String audioPath,
    required double audioSeconds,
    required String language,
    List<String> languageHints = const [],
  }) async {
    final m = await call('transcribe-start', {
      'client_note_id': clientNoteId,
      'audio_path': audioPath,
      'audio_seconds': audioSeconds,
      'language': language,
      if (languageHints.isNotEmpty) 'language_hints': languageHints,
    });
    return StartResult(m['job_id'] as String, '${m['status']}');
  }

  Future<StatusResult> transcribeStatus(String jobId, {bool ack = false}) async =>
      StatusResult.fromJson(await call('transcribe-status',
          {'job_id': jobId, if (ack) 'ack': true}));

  /// Returns the `summary` object (MeetingSummary JSON incl. in_short).
  Future<Map<String, Object?>> summarize({
    required String transcript,
    required int part,
    required int parts,
    required String style,
    String? customInstructions,
    String outputLanguage = 'same',
  }) async {
    final m = await call('summarize', {
      'transcript': transcript,
      'part': part,
      'parts': parts,
      'style': style,
      if (customInstructions != null && customInstructions.trim().isNotEmpty)
        'custom_instructions': customInstructions.trim(),
      'output_language': outputLanguage,
    }, timeout: const Duration(minutes: 3));
    final s = m['summary'];
    if (s is Map) return s.cast<String, Object?>();
    if (s is String) {
      final d = jsonDecode(s);
      if (d is Map) return d.cast<String, Object?>();
    }
    throw ApiException('server_error', 'summary missing in reply');
  }

  Future<AskReply> ask({
    required List<Map<String, Object?>> turns,
    required String question,
    List<Map<String, String>> history = const [],
  }) async =>
      AskReply.fromJson(await call('ask', {
        'transcript_turns': turns,
        'question': question,
        'history': history,
      }));
}
