import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/analytics/analytics.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/notes/speakers.dart';
import 'package:longnote/core/recording/recording_repository.dart';
import 'package:longnote/core/summary/summary_models.dart';
import 'package:longnote/features/note/summary_editor.dart';

import 'helpers/test_env.dart';

void main() {
  test('replaceWholeName: whole names only', () {
    expect(replaceWholeName('Speaker 1 and Speaker 10 met Speaker 1.',
            'Speaker 1', 'Priya'),
        'Priya and Speaker 10 met Priya.');
    expect(replaceWholeName("Speaker 2's plan", 'Speaker 2', r'A$1'), r"A$1's plan");
    expect(replaceWholeName('Ana and Anabel', 'Ana', 'Maria'), 'Maria and Anabel');
  });

  group('speaker names reach the summary', () {
    late TestEnv env;
    late SpeakerStore store;
    setUp(() async {
      env = await TestEnv.create();
      store = SpeakerStore(env.repo);
      await env.repo.insert(Recording(
          id: 'n', title: 't', createdAt: env.clock.now(),
          status: RecordingStatus.completed));
      await store.ensure('n', ['1', '2', '10']);
      await env.repo.saveSummary(
          'n',
          const MeetingSummary(
            inShort: 'Speaker 1 said, "I love Tibidabo."',
            keyPoints: ['Speaker 1 and Speaker 10 agreed.'],
            actionItems: [ActionItem(task: 'Send the deck', owner: 'Speaker 2')],
          ).encode(),
          'cloud');
    });
    tearDown(() async => env.dispose());

    Future<MeetingSummary> sum() async =>
        MeetingSummary.parse((await env.repo.summary('n'))!.json);

    test('rename: Speaker 1 -> Priya everywhere, Speaker 10 untouched; '
        'a second rename follows', () async {
      await store.rename('n', '1', 'Priya');
      await store.rename('n', '2', 'Arjun');
      var s = await sum();
      expect(s.inShort, 'Priya said, "I love Tibidabo."');
      expect(s.keyPoints, ['Priya and Speaker 10 agreed.']);
      expect(s.actionItems.single.owner, 'Arjun');
      await store.rename('n', '1', 'Priya Shah');
      s = await sum();
      expect(s.inShort, 'Priya Shah said, "I love Tibidabo."');
      expect((await env.repo.summary('n'))!.engine, 'cloud');
    });

    test('merge: the merged speaker takes the kept name; edits stay marked',
        () async {
      final edited = (await sum());
      await env.repo.updateSummaryJson(
          'n',
          MeetingSummary(
                  inShort: edited.inShort,
                  keyPoints: edited.keyPoints,
                  actionItems: edited.actionItems,
                  edited: true)
              .encode());
      await store.rename('n', '1', 'Priya');
      await store.merge('n', fromKey: '10', intoKey: '1');
      final s = await sum();
      expect(s.keyPoints, ['Priya and Priya agreed.']);
      expect(s.edited, isTrue);
    });
  });

  group('SummaryEditor', () {
    const initial = MeetingSummary(
      inShort: 'The recording was very brief.',
      keyPoints: ['Point one', 'Point two'],
      decisions: ['Ship it'],
    );

    Future<(List<MeetingSummary>, TestEnv)> pump(WidgetTester t,
        {VoidCallback? onDone}) async {
      final env = (await t.runAsync(TestEnv.create))!;
      final saved = <MeetingSummary>[];
      await t.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: SummaryEditor(
        recordingId: 'n',
        initial: initial,
        analytics: env.analytics,
        save: (s) async => saved.add(s),
        onDone: onDone ?? () {},
      )))));
      return (saved, env);
    }

    testWidgets('autosaves after typing; empty points are removed; '
        'one summary_edited with counts only', (t) async {
      var done = false;
      final (saved, env) = await pump(t, onDone: () => done = true);
      await t.enterText(find.text('The recording was very brief.'),
          'A short test of the app.');
      await t.pump(const Duration(milliseconds: 100));
      expect(saved, isEmpty); // waits for typing to pause
      await t.pump(SummaryEditor.autosaveDelay);
      expect(saved.single.inShort, 'A short test of the app.');
      expect(saved.single.edited, isTrue);
      expect(find.text('Saved'), findsOneWidget);

      await t.enterText(find.text('Point two'), '   ');
      await t.tap(find.text('+ Add a point'));
      await t.pump();
      await t.enterText(find.byType(TextField).last, 'Point three');
      await t.tap(find.text('Done'));
      await t.pump();
      expect(done, isTrue);
      expect(saved.last.keyPoints, ['Point one', 'Point three']);
      expect(saved.last.decisions, ['Ship it']);

      await t.pumpWidget(const SizedBox()); // editor closes: session logged
      final ev = (await t.runAsync(
          () => env.analytics.recent(name: AnalyticsEvent.summaryEdited)))!;
      expect(ev.single.props,
          {'fields_changed': 1, 'items_removed': 1, 'items_added': 1});
      expect(ev.single.recordingId, 'n');
      await t.runAsync(env.dispose);
    });

    testWidgets('action owners stay with their task after an autosave '
        'reloads the editor; a summary written by someone else closes it '
        'without saving', (t) async {
      final env = (await t.runAsync(TestEnv.create))!;
      const start = MeetingSummary(actionItems: [
        ActionItem(task: 'A', owner: 'Priya'),
        ActionItem(task: 'B', owner: 'Arjun'),
        ActionItem(task: 'C', owner: 'Meera', due: 'Friday'),
      ]);
      final saved = <MeetingSummary>[];
      var done = 0;
      Widget app(MeetingSummary initial) => MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: SummaryEditor(
                      recordingId: 'n',
                      initial: initial,
                      analytics: env.analytics,
                      save: (s) async => saved.add(s),
                      onDone: () => done++))));
      await t.pumpWidget(app(start));
      await t.enterText(find.text('B'), '');
      await t.pump(SummaryEditor.autosaveDelay);
      // The note screen reloads: the editor gets what it saved.
      await t.pumpWidget(app(MeetingSummary.parse(saved.last.encode())));
      await t.enterText(find.text('C'), 'C2');
      await t.pump(SummaryEditor.autosaveDelay);
      expect(saved.last.actionItems.map((a) => (a.task, a.owner, a.due)),
          [('A', 'Priya', null), ('C2', 'Meera', 'Friday')]);
      expect(done, 0);

      // A new style finished meanwhile: the editor closes, keeps theirs.
      final n = saved.length;
      await t.enterText(find.text('A'), 'A typed');
      await t.pumpWidget(app(const MeetingSummary(inShort: 'Fresh summary')));
      await t.pump();
      expect(done, 1);
      await t.pumpWidget(const SizedBox());
      await t.pump(SummaryEditor.autosaveDelay);
      expect(saved.length, n);
      await t.runAsync(env.dispose);
    });

    testWidgets('no change: nothing saved, no event', (t) async {
      final (saved, env) = await pump(t);
      await t.tap(find.text('Done'));
      await t.pumpWidget(const SizedBox());
      expect(saved, isEmpty);
      final ev = (await t.runAsync(
          () => env.analytics.recent(name: AnalyticsEvent.summaryEdited)))!;
      expect(ev, isEmpty);
      await t.runAsync(env.dispose);
    });
  });
}
