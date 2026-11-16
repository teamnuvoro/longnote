import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:longnote/core/audio/wav.dart';
import 'package:longnote/core/cloud/audio_encoder.dart';
import 'package:longnote/core/cloud/backend_config.dart';
import 'package:longnote/core/config.dart';

const testConfig =
    BackendConfig(url: 'https://proj.supabase.co', anonKey: 'anon-key');

class FakeJob {
  FakeJob(this.id, this.clientId, this.path);
  final String id;
  final String clientId;
  final String path;
  String status = 'transcribing';
  int polls = 0;
  bool acked = false;
}

class FakeUpload {
  FakeUpload(this.path, this.length);
  final String path;
  final int length;
  final bytes = BytesBuilder();
}

/// In-memory Supabase: anonymous auth, TUS storage, and the four edge
/// functions, with knobs to inject failures. Mirrors BACKEND-API.md.
class FakeBackend {
  bool offline = false;
  int signups = 0;
  int refreshes = 0;
  int tusCreates = 0;
  int patches = 0;
  int starts = 0;

  /// Throw a network error on PATCH number N (1-based) once.
  int? dropOnPatch;

  /// Next N transcribe-start calls fail with this code.
  int startFailures = 0;
  String startFailureCode = 'upstream_failed';

  /// transcribe-start answers limit_reached with this scope while set.
  String? limitScope;

  /// Polls until a job is done.
  int pollsUntilDone = 2;

  /// Fail the job on the server at its first poll (once per client id).
  final failOnFirstPoll = <String>{};

  /// Turns for a client id (default: two speakers).
  List<Map<String, Object?>> Function(String clientId) turnsFor = (_) => [
        {'speaker': '1', 'start_ms': 0, 'end_ms': 1500, 'text': 'We decided to launch on Monday.', 'language': 'en'},
        {'speaker': '2', 'start_ms': 1600, 'end_ms': 3000, 'text': 'Priya will send the budget by Friday.', 'language': 'en'},
      ];

  final uploads = <String, FakeUpload>{};
  final objects = <String, Uint8List>{};
  final jobs = <String, FakeJob>{};
  final requests = <http.Request>[];
  final functionCalls = <String, List<Map<String, Object?>>>{};
  var _n = 0;
  final _tokens = <String, String>{}; // access token -> user id

  late final http.Client client = MockClient(_handle);

  List<Map<String, Object?>> calls(String fn) => functionCalls[fn] ?? const [];

  Future<http.Response> _handle(http.Request req) async {
    requests.add(req);
    if (offline) throw const SocketException('offline');
    final path = req.url.path;
    if (path == '/auth/v1/signup') {
      signups++;
      return _session('user-$signups');
    }
    if (path == '/auth/v1/token') {
      refreshes++;
      final rt = (jsonDecode(req.body) as Map)['refresh_token'] as String;
      if (!rt.startsWith('rt-')) return http.Response('{"error":"bad"}', 400);
      return _session(rt.substring(3));
    }
    if (req.url.host == 'proj.storage.supabase.co') return _tus(req);
    if (path.startsWith('/functions/v1/')) {
      final user = _user(req);
      if (user == null) return _err(401, 'unauthorized');
      final fn = path.substring('/functions/v1/'.length);
      final body = (jsonDecode(req.body) as Map).cast<String, Object?>();
      functionCalls.putIfAbsent(fn, () => []).add(body);
      return switch (fn) {
        'transcribe-start' => _start(user, body),
        'transcribe-status' => _status(body),
        'summarize' => _summarize(body),
        'ask' => _ask(body),
        _ => _err(404, 'not_found'),
      };
    }
    return http.Response('not found', 404);
  }

  http.Response _session(String userId) {
    final token = 'at-$userId-${++_n}';
    _tokens[token] = userId;
    return http.Response(
        jsonEncode({
          'access_token': token,
          'refresh_token': 'rt-$userId',
          'expires_in': 3600,
          'user': {'id': userId, 'is_anonymous': true},
        }),
        200);
  }

  String? _user(http.BaseRequest req) {
    final h = req.headers['Authorization'] ?? '';
    if (req.headers['apikey'] != testConfig.anonKey) return null;
    return _tokens[h.replaceFirst('Bearer ', '')];
  }

  http.Response _err(int status, String code, [Map<String, Object?>? detail]) =>
      http.Response(
          jsonEncode({
            'error': {'code': code, 'message': code, 'detail': ?detail}
          }),
          status);

  // ---- TUS -------------------------------------------------------------------
  http.Response _tus(http.Request req) {
    final user = _user(req);
    if (user == null) return http.Response('', 401);
    if (req.method == 'POST') {
      tusCreates++;
      final meta = <String, String>{};
      for (final kv in req.headers['Upload-Metadata']!.split(',')) {
        final parts = kv.split(' ');
        meta[parts[0]] = utf8.decode(base64.decode(parts[1]));
      }
      final objectName = meta['objectName']!;
      if (!objectName.startsWith('$user/')) return http.Response('', 403);
      final id = 'up${++_n}';
      uploads[id] =
          FakeUpload(objectName, int.parse(req.headers['Upload-Length']!));
      return http.Response('', 201,
          headers: {'location': '/storage/v1/upload/resumable/$id'});
    }
    final id = req.url.pathSegments.last;
    final up = uploads[id];
    if (up == null) return http.Response('', 404);
    if (req.method == 'HEAD') {
      return http.Response('', 200,
          headers: {'upload-offset': '${up.bytes.length}'});
    }
    if (req.method == 'PATCH') {
      patches++;
      if (dropOnPatch != null && patches == dropOnPatch) {
        dropOnPatch = null;
        throw http.ClientException('connection reset');
      }
      final off = int.parse(req.headers['Upload-Offset']!);
      if (off != up.bytes.length) return http.Response('', 409);
      up.bytes.add(req.bodyBytes);
      if (up.bytes.length == up.length) {
        objects[up.path] = up.bytes.toBytes();
      }
      return http.Response('', 204,
          headers: {'upload-offset': '${up.bytes.length}'});
    }
    return http.Response('', 405);
  }

  // ---- functions ---------------------------------------------------------------
  http.Response _start(String user, Map<String, Object?> b) {
    starts++;
    final client = b['client_note_id'] as String;
    final path = b['audio_path'] as String;
    if (path != '$user/$client.m4a') return _err(400, 'bad_request');
    final secs = (b['audio_seconds'] as num).toDouble();
    if (secs <= 0 || secs > 18000) return _err(422, 'too_long');
    if (limitScope != null) {
      return _err(429, 'limit_reached', {'scope': limitScope});
    }
    final existing = jobs.values.where((j) => j.clientId == client).toList();
    if (existing.isNotEmpty &&
        (existing.first.status == 'transcribing' || existing.first.status == 'done')) {
      return http.Response(
          jsonEncode({'job_id': existing.first.id, 'client_note_id': client, 'status': existing.first.status}),
          200);
    }
    if (!objects.containsKey(path)) return _err(404, 'not_found');
    if (startFailures > 0) {
      startFailures--;
      return _err(502, startFailureCode, {'tries_left': 2});
    }
    final job = existing.isNotEmpty ? existing.first : FakeJob('job-${++_n}', client, path);
    job
      ..status = 'transcribing'
      ..polls = 0
      ..acked = false;
    jobs[job.id] = job;
    return http.Response(
        jsonEncode({'job_id': job.id, 'client_note_id': client, 'status': 'transcribing'}),
        200);
  }

  http.Response _status(Map<String, Object?> b) {
    final job = jobs[b['job_id']];
    if (job == null) return _err(404, 'not_found');
    if (b['ack'] == true) {
      job
        ..acked = true
        ..status = 'fetched';
      return http.Response(jsonEncode({'job_id': job.id, 'status': 'fetched'}), 200);
    }
    if (job.status == 'transcribing') {
      job.polls++;
      if (failOnFirstPoll.remove(job.clientId)) {
        job.status = 'failed';
        objects.remove(job.path); // the server deletes the audio
      } else if (job.polls >= pollsUntilDone) {
        job.status = 'done';
        objects.remove(job.path);
      }
    }
    final m = <String, Object?>{
      'job_id': job.id,
      'client_note_id': job.clientId,
      'status': job.status,
    };
    if (job.status == 'transcribing') m['provider_status'] = 'processing';
    if (job.status == 'done') {
      m['result'] = {
        'turns': turnsFor(job.clientId),
        'audio_duration_ms': 3000,
        'speakers': 2,
        'languages': ['en'],
      };
    }
    if (job.status == 'failed') {
      m['error'] = {'code': 'upstream_failed', 'message': 'Transcription failed.'};
    }
    return http.Response(jsonEncode(m), 200);
  }

  http.Response _summarize(Map<String, Object?> b) => http.Response(
      jsonEncode({
        'summary': {
          'in_short': 'Part ${b['part']} in short.',
          'key_points': ['Launch on Monday'],
          'decisions': ['Launch on Monday.'],
          'action_items': [
            {'task': 'Send the budget', 'owner': 'Priya', 'due': 'Friday'}
          ],
          'numbers_and_dates': [],
          'open_questions': [],
        },
        'model': 'fake',
        'style': b['style'],
      }),
      200);

  http.Response _ask(Map<String, Object?> b) {
    final turns = (b['transcript_turns'] as List).cast<Map>();
    return http.Response(
        jsonEncode({
          'answer': 'Priya sends it on Friday.',
          'found': true,
          'sources': [
            {'speaker': turns.last['speaker'], 'start_ms': turns.last['start_ms']},
            {'speaker': 'x', 'start_ms': 'bad'},
          ],
          'truncated': false,
          'model': 'fake',
        }),
        200);
  }
}

/// Linux stand-in for the native AAC encoder: writes 2 bytes per ms of the
/// requested range (deterministic size), never touches the inputs.
class FakeAudioEncoder implements AudioEncoder {
  final calls = <({List<String> inputs, int startMs, int? durationMs})>[];
  bool fail = false;

  @override
  Future<EncodedAudio> encodeM4a({
    required List<String> inputs,
    required String output,
    int startMs = 0,
    int? durationMs,
  }) async {
    calls.add((inputs: inputs, startMs: startMs, durationMs: durationMs));
    if (fail) throw AudioEncodeException('fake failure');
    var total = 0;
    for (final i in inputs) {
      total += wavDataBytesFromLength(i) * 1000 ~/ AppConfig.bytesPerSecond;
    }
    var ms = total - startMs;
    if (durationMs != null && durationMs < ms) ms = durationMs;
    final bytes = Uint8List.fromList(List.generate(ms * 2, (i) => i & 0xff));
    File(output).writeAsBytesSync(bytes);
    return EncodedAudio(durationMs: ms, bytes: bytes.length);
  }
}
