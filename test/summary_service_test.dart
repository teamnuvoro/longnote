import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:longnote/core/summary/cloud_summarizer.dart';
import 'package:longnote/core/summary/local_extractive_summarizer.dart';
import 'package:longnote/core/summary/summary_service.dart';

import 'helpers/fakes.dart';
import 'helpers/test_env.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  const transcript = '[00:01] We decided to launch on 3 March.\n'
      '[00:05] Ravi will send the deck by Friday.';

  test('auto with no Apple Intelligence uses local, without a warning note',
      () async {
    final s = SummaryService(
        kv: env.kv,
        apple: UnavailableSummarizer('apple'),
        cloud: UnavailableSummarizer('cloud'),
        local: LocalExtractiveSummarizer());
    final out = await s.summarize(transcript);
    expect(out.engineId, 'local');
    expect(out.note, isNull);
    expect(out.summary.decisions, isNotEmpty);
  });

  test('chosen engine unavailable -> local with an honest note', () async {
    final s = SummaryService(
        kv: env.kv,
        apple: UnavailableSummarizer('apple'),
        cloud: UnavailableSummarizer('cloud'),
        local: LocalExtractiveSummarizer());
    await s.setEngine(SummaryEngine.cloud);
    final out = await s.summarize(transcript);
    expect(out.engineId, 'local');
    expect(out.note, contains('basic offline summary'));
  });

  test('engine that returns garbage falls back to local', () async {
    final apple = ScriptedSummarizer('apple', (_, _) => 'Sorry, I cannot.');
    final s = SummaryService(
        kv: env.kv,
        apple: apple,
        cloud: UnavailableSummarizer('cloud'),
        local: LocalExtractiveSummarizer());
    final out = await s.summarize(transcript);
    expect(out.engineId, 'local');
    expect(out.note, contains('failed'));
  });

  test('long transcript is chunked, summarized per chunk, then merged',
      () async {
    final lines = List.generate(30, (i) => '[00:${i.toString().padLeft(2, '0')}] Line $i about the budget.');
    final apple = ScriptedSummarizer(
      'apple',
      (chunk, part) => jsonEncode({
        'key_points': ['Budget discussed', 'Part $part'],
        'decisions': [],
        'action_items': [
          {'task': 'Send budget', 'owner': part == 2 ? 'Asha' : null, 'due': null}
        ],
        'numbers_and_dates': [],
        'open_questions': [],
      }),
      maxChunkChars: 200,
    );
    final s = SummaryService(
        kv: env.kv,
        apple: apple,
        cloud: UnavailableSummarizer('cloud'),
        local: LocalExtractiveSummarizer());
    final out = await s.summarize(lines.join('\n'));
    expect(out.engineId, 'apple');
    expect(apple.calls.length, greaterThan(2));
    for (final c in apple.calls) {
      expect(c.length, lessThanOrEqualTo(200));
    }
    // "Budget discussed" de-duplicated across chunks; part markers kept.
    expect(out.summary.keyPoints.where((k) => k == 'Budget discussed'),
        hasLength(1));
    expect(out.summary.keyPoints, contains('Part 1'));
    // Same task merged; owner filled from the chunk that stated it.
    expect(out.summary.actionItems, hasLength(1));
    expect(out.summary.actionItems.single.owner, 'Asha');
  });

  group('CloudSummarizer', () {
    test('posts transcript text and parses {"summary": {...}}', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(
            jsonEncode({
              'summary': {
                'key_points': ['A'],
                'decisions': ['B'],
                'action_items': [
                  {'task': 'C', 'owner': 'Dev', 'due': null}
                ],
                'numbers_and_dates': [],
                'open_questions': [],
              }
            }),
            200);
      });
      final c = CloudSummarizer(
          url: 'https://example.invalid/fn', publicKey: 'anon', client: client);
      final s = await c.summarizeChunk('hello', part: 1, parts: 1);
      expect(s.decisions, ['B']);
      expect(s.actionItems.single.owner, 'Dev');
      final body = jsonDecode(seen.body) as Map;
      expect(body['transcript'], 'hello');
      expect(seen.headers['Authorization'], 'Bearer anon');
      // Never an AI provider key in the request.
      expect(seen.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('x-api-key')));
    });

    test('HTTP error throws (so the service falls back)', () async {
      final c = CloudSummarizer(
          url: 'https://example.invalid/fn',
          client: MockClient((_) async => http.Response('nope', 500)));
      expect(() => c.summarizeChunk('x', part: 1, parts: 1),
          throwsA(isA<CloudSummaryException>()));
    });

    test('not configured -> unavailable', () async {
      expect(await CloudSummarizer(url: '').isAvailable(), isFalse);
    });
  });
}
