import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/export/text_format.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/notes/moments.dart';
import 'package:longnote/core/notes/speakers.dart';

import 'helpers/test_env.dart';

void main() {
  late TestEnv env;
  late SpeakerStore store;
  setUp(() async {
    env = await TestEnv.create();
    store = SpeakerStore(env.repo);
    await env.repo.insert(Recording(
        id: 'n', title: 't', createdAt: env.clock.now(),
        status: RecordingStatus.completed));
    final lines = [
      TranscriptLine(startMs: 0, endMs: 1, text: 'a', speaker: '1'),
      TranscriptLine(startMs: 2, endMs: 3, text: 'b', speaker: '2'),
      TranscriptLine(startMs: 4, endMs: 5, text: 'c', speaker: '3'),
      TranscriptLine(startMs: 6, endMs: 7, text: 'd', speaker: '1'),
    ];
    await env.repo.saveSegmentTranscript('n', 0, lines);
    await store.ensure('n', ['1', '2', '3']);
  });
  tearDown(() async => env.dispose());

  test('default names and colours in order of appearance; ensure keeps names',
      () async {
    expect((await store.list('n')).map((s) => (s.name, s.colorIndex)),
        [('Speaker 1', 0), ('Speaker 2', 1), ('Speaker 3', 2)]);
    await store.rename('n', '1', 'Priya');
    await store.ensure('n', ['1', '4']);
    final names = await store.names('n');
    expect(names['1'], 'Priya');
    expect(names['4'], 'Speaker 4');
    expect((await store.list('n')).last.colorIndex, 3);
    expect(defaultSpeakerName('2:1'), 'Speaker 1 (part 2)');
  });

  test('rename ignores blank names', () async {
    await store.rename('n', '2', '   ');
    expect((await store.names('n'))['2'], 'Speaker 2');
  });

  test('merge rewrites the turns and deletes the merged speaker', () async {
    await store.rename('n', '1', 'Priya');
    await store.merge('n', fromKey: '3', intoKey: '1');
    final lines = await env.repo.transcript('n');
    expect(lines.map((l) => l.speaker), ['1', '2', '1', '1']);
    expect((await store.list('n')).map((s) => s.key), ['1', '2']);
    final text = transcriptToText(lines,
        timestamps: false, names: await store.names('n'));
    expect(text, 'Priya: a\nSpeaker 2: b\nPriya: c\nPriya: d');
  });

  test('first turn per speaker (sample lines for D4)', () async {
    final first = await store.firstTurns('n');
    expect(first['1']!.text, 'a');
    expect(first['3']!.text, 'c');
  });

  test('marked moments: add, list in time order, rename, delete', () async {
    final m = MomentStore(env.repo);
    final b = await m.add('n', 90000, label: 'Budget agreed');
    await m.add('n', 30000);
    expect((await m.list('n')).map((x) => x.atMs), [30000, 90000]);
    await m.rename(b, 'Budget number agreed');
    expect((await m.list('n')).last.label, 'Budget number agreed');
    await m.delete(b);
    expect(await m.list('n'), hasLength(1));
  });
}
