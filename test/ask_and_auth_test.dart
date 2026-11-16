import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:longnote/core/cloud/longnote_api.dart';
import 'package:longnote/core/cloud/piece_planner.dart';
import 'package:longnote/core/cloud/supabase_auth.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/notes/ask_service.dart';
import 'package:longnote/core/notes/chat.dart';
import 'package:longnote/core/notes/speakers.dart';

import 'helpers/fake_backend.dart';
import 'helpers/test_env.dart';

void main() {
  late TestEnv env;
  late FakeBackend server;
  setUp(() async {
    env = await TestEnv.create();
    server = FakeBackend();
  });
  tearDown(() async => env.dispose());

  group('AskReply parsing', () {
    test('full reply', () {
      final r = AskReply.fromJson({
        'answer': ' Speaker 1 sends it on Monday. ',
        'found': true,
        'sources': [
          {'speaker': 'Speaker 1', 'start_ms': 47370},
          {'speaker': 'Priya', 'start_ms': 1200.0},
        ],
        'truncated': true,
      });
      expect(r.answer, 'Speaker 1 sends it on Monday.');
      expect(r.found, isTrue);
      expect(r.truncated, isTrue);
      expect(r.sources.map((s) => (s.speaker, s.startMs)),
          [('Speaker 1', 47370), ('Priya', 1200)]);
    });

    test('not covered / junk sources / missing fields', () {
      final r = AskReply.fromJson({
        'answer': 'The recording does not cover it.',
        'found': false,
        'sources': [null, 'x', {'speaker': 'A'}, {'start_ms': 'abc'}, {'start_ms': '15'}],
      });
      expect(r.found, isFalse);
      expect(r.sources.single.startMs, 15);
      expect(AskReply.fromJson({}).answer, '');
      expect(AskReply.fromJson({}).sources, isEmpty);
    });
  });

  group('AskService', () {
    late AskService ask;
    setUp(() async {
      await env.repo.insert(Recording(
          id: 'n', title: 't', createdAt: env.clock.now(),
          status: RecordingStatus.completed));
      await env.repo.saveSegmentTranscript('n', 0, [
        TranscriptLine(startMs: 0, endMs: 1, text: 'Hello.', speaker: '1'),
        TranscriptLine(startMs: 7200, endMs: 9000, text: 'I send it Friday.', speaker: '2'),
      ]);
      final sp = SpeakerStore(env.repo);
      await sp.ensure('n', ['1', '2']);
      await sp.rename('n', '2', 'Priya');
      final auth = SupabaseAuth(config: testConfig, kv: env.kv, client: server.client);
      ask = AskService(
          repo: env.repo,
          api: LongnoteApi(config: testConfig, auth: auth, client: server.client));
    });

    test('sends named turns + question, stores both messages with sources',
        () async {
      final a = await ask.ask('n', '  Who sends it?  ');
      expect(a.role, ChatRole.assistant);
      expect(a.found, isTrue);
      expect(a.sources.single.startMs, 7200);
      final body = server.calls('ask').single;
      expect(body['question'], 'Who sends it?');
      expect((body['transcript_turns'] as List).last,
          {'speaker': 'Priya', 'start_ms': 7200, 'text': 'I send it Friday.'});
      expect(body['history'], isEmpty);
      final stored = await ask.chat.list('n');
      expect(stored.map((m) => m.role), [ChatRole.user, ChatRole.assistant]);
      expect(stored.last.sources.single.speaker, 'Priya');
    });

    test('history = last 6 messages', () async {
      for (var i = 0; i < 5; i++) {
        await ask.ask('n', 'Q$i');
      }
      final hist = (server.calls('ask').last['history'] as List).cast<Map>();
      expect(hist, hasLength(6));
      expect(hist.first['content'], 'Q1');
      expect(hist.last['role'], 'assistant');
    });

    test('failure keeps the question and throws', () async {
      server.offline = true;
      await expectLater(ask.ask('n', 'Who?'), throwsA(anything));
      server.offline = false;
      final stored = await ask.chat.list('n');
      expect(stored.single.text, 'Who?');
    });
  });

  group('SupabaseAuth', () {
    test('signs up once, persists the session, refreshes near expiry', () async {
      final a1 = SupabaseAuth(
          config: testConfig, kv: env.kv, client: server.client, clock: env.clock);
      final t1 = await a1.accessToken();
      expect(await a1.accessToken(), t1);
      expect(await a1.userId(), 'user-1');

      final a2 = SupabaseAuth(
          config: testConfig, kv: env.kv, client: server.client, clock: env.clock);
      expect(await a2.accessToken(), t1, reason: 'loaded from the database');
      expect(server.signups, 1);

      env.clock.advance(const Duration(minutes: 56));
      final t2 = await a2.accessToken();
      expect(t2, isNot(t1));
      expect(server.refreshes, 1);
      expect(await a2.userId(), 'user-1', reason: 'same user after refresh');
    });

    test('concurrent callers share one sign-up', () async {
      final a = SupabaseAuth(config: testConfig, kv: env.kv, client: server.client);
      await Future.wait([a.accessToken(), a.accessToken(), a.userId()]);
      expect(server.signups, 1);
    });

    test('rejected refresh token -> new anonymous user', () async {
      await env.kv.set(
          SupabaseAuth.kvSession,
          jsonEncode(AuthSession(
                  accessToken: 'old',
                  refreshToken: 'revoked',
                  expiresAt: DateTime(2000),
                  userId: 'gone')
              .toJson()));
      final a = SupabaseAuth(config: testConfig, kv: env.kv, client: server.client);
      expect(await a.userId(), 'user-1');
      expect(server.signups, 1);
    });

    test('API retries once with a fresh token after 401', () async {
      var calls = 0;
      var refreshes = 0;
      final seenTokens = <String?>[];
      http.Response session(String token) => http.Response(
          jsonEncode({
            'access_token': token,
            'refresh_token': 'r',
            'expires_in': 3600,
            'user': {'id': 'u'}
          }),
          200);
      final client = MockClient((req) async {
        if (req.url.path == '/auth/v1/signup') return session('t1');
        if (req.url.path == '/auth/v1/token') {
          refreshes++;
          return session('t2');
        }
        calls++;
        seenTokens.add(req.headers['Authorization']);
        if (calls == 1) {
          return http.Response('{"error":{"code":"unauthorized","message":"x"}}', 401);
        }
        return http.Response('{"job_id":"j","status":"fetched"}', 200);
      });
      final auth = SupabaseAuth(config: testConfig, kv: env.kv, client: client);
      final api = LongnoteApi(config: testConfig, auth: auth, client: client);
      expect((await api.transcribeStatus('j')).status, 'fetched');
      expect(calls, 2);
      expect(refreshes, 1);
      expect(seenTokens, ['Bearer t1', 'Bearer t2']);
    });
  });

  group('planPieces', () {
    const h = 3600 * 1000;
    test('up to 5 h is one piece of everything', () {
      final p = planPieces([for (var i = 0; i < 60; i++) AudioInput('s$i', 5 * 60 * 1000)]);
      expect(p, hasLength(1));
      expect(p.single.inputs, hasLength(60));
      expect(p.single.durationMs, 5 * h);
    });

    test('over 5 h: 4-h pieces aligned to the files that cover them', () {
      final p = planPieces([for (var i = 0; i < 61; i++) AudioInput('s$i', 5 * 60 * 1000)]);
      expect(p.map((x) => x.startMs), [0, 4 * h]);
      expect(p.map((x) => x.durationMs), [4 * h, 65 * 60 * 1000]);
      expect(p[1].inputs.first, 's48');
      expect(p[1].rangeStartMs, 0);
    });

    test('one long imported file is cut by range', () {
      final p = planPieces([const AudioInput('import.m4a', 9 * h)]);
      expect(p.map((x) => (x.rangeStartMs, x.durationMs)),
          [(0, 4 * h), (4 * h, 4 * h), (8 * h, h)]);
      expect(p.every((x) => x.inputs.single == 'import.m4a'), isTrue);
    });

    test('empty files are skipped; nothing to send -> no pieces', () {
      expect(planPieces([const AudioInput('a', 0)]), isEmpty);
    });
  });
}
