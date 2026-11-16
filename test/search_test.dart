import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/notes/search.dart';
import 'package:longnote/core/summary/summary_models.dart';

import 'helpers/test_env.dart';

void main() {
  late TestEnv env;
  late NoteSearch search;
  setUp(() async {
    env = await TestEnv.create();
    search = NoteSearch(env.repo, ftsEnabled: env.db.ftsEnabled);
    Future<void> add(String id, String title, List<String> lines) async {
      await env.repo.insert(Recording(
          id: id, title: title, createdAt: env.clock.now(),
          status: RecordingStatus.completed));
      await env.repo.saveSegmentTranscript(id, 0, [
        for (var i = 0; i < lines.length; i++)
          TranscriptLine(startMs: i * 1000, endMs: i * 1000 + 900, text: lines[i], speaker: '1')
      ]);
    }

    await add('a', 'Q3 budget review', ['Referrals hold at four percent.', 'Cut paid ads.']);
    await add('b', 'Lecture 7 organic chemistry', ['Benzene rings are aromatic.']);
    await env.repo.saveSummary(
        'b',
        const MeetingSummary(
                inShort: 'Aromaticity and the Hückel rule.',
                keyPoints: ['Benzene is stable'])
            .encode(),
        'cloud');
  });
  tearDown(() async => env.dispose());

  test('FTS5 is available in the test SQLite', () {
    expect(env.db.ftsEnabled, isTrue);
  });

  test('finds titles, summaries and transcript turns with prefix matching',
      () async {
    final r = await search.search('budg');
    expect(r.single.recordingId, 'a');
    expect(r.single.hits.single.kind, SearchHitKind.title);
    expect(r.single.hits.single.snippet,
        contains('${NoteSearch.markStart}budget${NoteSearch.markEnd}'));

    final s = await search.search('huckel'); // diacritics removed
    expect(s.single.hits.single.kind, SearchHitKind.summary);

    final t = await search.search('referrals');
    final hit = t.single.hits.single;
    expect(hit.kind, SearchHitKind.transcript);
    expect(hit.startMs, 0);
    expect(hit.speaker, '1');
  });

  test('all words must match; results grouped per note', () async {
    expect(await search.search('benzene ads'), isEmpty);
    final r = await search.search('benzene');
    expect(r.single.recordingId, 'b');
    expect(r.single.hits.map((h) => h.kind),
        containsAll([SearchHitKind.summary, SearchHitKind.transcript]));
  });

  test('index follows renames, new lines and deletes', () async {
    await env.repo.rename('a', 'Marketing plan');
    expect(await search.search('budget'), isEmpty);
    expect((await search.search('marketing')).single.recordingId, 'a');
    await env.repo.saveSegmentTranscript('a', 0,
        [TranscriptLine(startMs: 0, endMs: 1, text: 'Brand new words.')]);
    expect(await search.search('referrals'), isEmpty);
    expect(await search.search('brand'), hasLength(1));
    await env.repo.deleteByUser('a');
    expect(await search.search('marketing'), isEmpty);
    expect(await search.search('brand'), isEmpty);
  });

  test('query syntax is neutralised', () async {
    expect(NoteSearch.ftsQuery('  "budget"  OR  ads* '), '"budget"* "OR"* "ads*"*');
    expect(NoteSearch.ftsQuery('   '), isNull);
    expect(await search.search('NEAR( "a'), isA<List<NoteSearchResult>>());
  });

  test('LIKE fallback when FTS5 is missing', () async {
    final like = NoteSearch(env.repo, ftsEnabled: false);
    expect((await like.search('chemistry')).single.recordingId, 'b');
    expect((await like.search('paid ads')).single.hits.single.startMs, 1000);
  });
}
