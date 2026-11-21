// Amplitude screen and action events (docs/ANALYTICS.md) through the whole
// app: screen_viewed on every route change with no duplicates, and the
// paywall / settings / recording / search events with their props.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/app/routes.dart';
import 'package:longnote/core/analytics/analytics.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/recording/recording_controller.dart';
import 'package:longnote/features/paywall/paywall_screen.dart';
import 'package:longnote/ui/widgets.dart';

import '../helpers/fake_analytics.dart';
import '../helpers/screens_harness.dart' show loadAppFonts, phoneView;
import 'flow_env.dart';

void main() {
  late FlowEnv env;
  late FakeSink sink;
  setUpAll(loadAppFonts);
  tearDown(() async => env.dispose());

  Future<void> boot(WidgetTester t, {bool trial = true}) async {
    sink = FakeSink();
    await t.runAsync(
        () async => env = await FlowEnv.create(sinks: [sink], trial: trial));
    phoneView(t);
    mockPlatform();
    await env.pumpApp(t);
  }

  List<Object?> screens() => [
        for (final (n, p) in sink.events)
          if (n == AnalyticsEvent.screenViewed) p['screen']
      ];

  bool onTop<T>(WidgetTester t) {
    final f = find.byType(T);
    if (f.evaluate().isEmpty) return false;
    return ModalRoute.of(f.evaluate().last)?.isCurrent ?? false;
  }

  List<(String, Map<String, Object>)> named(String name) =>
      [for (final e in sink.events) if (e.$1 == name) e];

  testWidgets('screen_viewed: tabs, pushes, sheets and pops; no duplicates',
      (t) async {
    await boot(t);
    await t.runAsync(() => env.addNote('n1', 'Budget review',
        at: env.clock.now(), summary: 'We agreed.'));
    await settle(t);
    expect(screens(), [R.notes]);

    // Tab switches.
    await tapAndSettle(t, byLabel('Ask'));
    await tapAndSettle(t, byLabel('Settings'));
    // A push above the shell, then back.
    await tapAndSettle(t, find.text('Audio language'));
    await tapAndSettle(t, find.byKey(const ValueKey('nav-back')).last);
    // A sheet, then closed by its scrim.
    await tapAndSettle(t, find.text('Summary style'));
    await t.tapAt(const Offset(200, 20));
    await settle(t);
    // Back to Notes; a pushed note and a sheet over it; pops back.
    await tapAndSettle(t, byLabel('Notes'));
    env.router.pushNamed(R.note, pathParameters: {'id': 'n1'});
    await settle(t);
    env.router.pushNamed(R.noteActions, pathParameters: {'id': 'n1'});
    await settle(t);
    env.router.pop();
    await settle(t);
    env.router.pop();
    await settle(t);

    expect(screens(), [
      R.notes,
      R.ask,
      R.settings,
      R.audioLanguage,
      R.settings,
      R.defaultStyle,
      R.settings,
      R.notes,
      R.note,
      R.noteActions,
      R.note,
      R.notes,
    ]);
    final s = screens();
    for (var i = 1; i < s.length; i++) {
      expect(s[i], isNot(s[i - 1]), reason: 'duplicate at $i');
    }
    // A rebuild with no route change logs nothing.
    final before = sink.events.length;
    await t.pump(const Duration(seconds: 1));
    expect(sink.events.length, before);
  });

  testWidgets('paywall: plan, more, legal link, close button', (t) async {
    await boot(t, trial: false);
    env.router.pushNamed(R.paywall);
    await settle(t);
    await tapAndSettle(t, find.text('Monthly'));
    await tapAndSettle(t, find.text('Monthly')); // same plan: not logged again
    await tapAndSettle(t, find.text('See everything you get'));
    await tapAndSettle(t, find.text('Terms'));
    expect(env.opened.last.path, '/longnote/terms');
    await tapAndSettle(t, byLabel('Close'));

    expect(named(AnalyticsEvent.paywallPlanSelected).map((e) => e.$2), [
      {'plan': monthlyPlan.id, 'placement': 'second_recording'}
    ]);
    expect(sink.propsOf(AnalyticsEvent.paywallMoreOpened),
        {'placement': 'second_recording'});
    expect(sink.propsOf(AnalyticsEvent.legalLinkOpened),
        {'link': 'terms', 'from': 'paywall'});
    expect(sink.propsOf(AnalyticsEvent.paywallClosed),
        {'how': 'close_button', 'placement': 'second_recording'});
    expect(screens().last, R.notes);
  });

  testWidgets('settings: mode, rate, support; analytics off is the last event',
      (t) async {
    await boot(t);
    await tapAndSettle(t, byLabel('Settings'));
    await tapAndSettle(t, find.text('Transcription'));
    await tapAndSettle(t, find.text('On this phone'));
    expect(sink.propsOf(AnalyticsEvent.settingChanged),
        {'setting': 'transcription_mode', 'value': 'onDevice'});
    await tapAndSettle(t, find.byKey(const ValueKey('nav-back')).last);

    await tapAndSettle(t, find.text('Rate Longnote'));
    expect(env.opened.last.toString(),
        'https://apps.apple.com/app/id6835017154?action=write-review');
    expect(sink.names, contains(AnalyticsEvent.rateTapped));
    await tapAndSettle(t, find.text('Contact us'));
    expect(sink.propsOf(AnalyticsEvent.supportTapped), {'kind': 'help'});

    await tapAndSettle(t, find.byKey(const ValueKey('share-analytics')));
    expect(sink.names.last, AnalyticsEvent.shareAnalyticsOff);
    final n = sink.events.length;
    await tapAndSettle(t, find.text('What happens to your audio'));
    expect(sink.events.length, n, reason: 'nothing leaves once off');
    await tapAndSettle(t, find.byKey(const ValueKey('nav-back')).last);
    await tapAndSettle(t, find.byKey(const ValueKey('share-analytics')));
    expect(sink.names.last, AnalyticsEvent.settingChanged);
    expect(sink.propsOf(AnalyticsEvent.settingChanged),
        {'setting': 'share_analytics', 'value': 'on'});
  });

  testWidgets('recording: pause, resume, discard', (t) async {
    await boot(t);
    await tapAndSettle(t, find.text('Record'));
    await tapAndSettle(t, find.byKey(const ValueKey('record-start')));
    await env.speak(t, 3);
    await t.pump(const Duration(seconds: 1)); // past the double-tap guard
    final id = env.services.recorder.current!.id;
    await tapAndSettle(t, byLabel('Pause'));
    expect(env.services.recorder.state, CaptureState.paused);
    await tapAndSettle(t, byLabel('Resume'));
    await tapAndSettle(t, byLabel('Discard'));
    await tapAndSettle(t, find.text('Discard recording'));

    final local = await t.runAsync(() => env.services.analytics.recent());
    LoggedEvent ev(String name) => local!.firstWhere((e) => e.name == name);
    expect(ev(AnalyticsEvent.recordingPaused).recordingId, id);
    expect(ev(AnalyticsEvent.recordingResumed).recordingId, id);
    expect(ev(AnalyticsEvent.recordingDiscarded).recordingId, id);
    expect(ev(AnalyticsEvent.recordingDiscarded).props['duration_s'], 3);
  });

  testWidgets('free 30 s: capture pauses at the limit and the paywall '
      'opens; closing it saves the note and spends the seconds', (t) async {
    await boot(t, trial: false);
    await tapAndSettle(t, find.text('Record'));
    await tapAndSettle(t, find.byKey(const ValueKey('record-start')));
    final s = env.services;
    final id = s.recorder.current!.id;
    await env.speak(t, 20);
    expect(s.recorder.state, CaptureState.recording);
    await env.speak(t, 15); // 35 s: past the free 30
    await settle(t);
    expect(s.recorder.state, CaptureState.paused);
    expect(onTop<PaywallScreen>(t), isTrue);
    expect(find.text('Your free 30 seconds are up.'), findsOneWidget);
    expect(named(AnalyticsEvent.paywallViewed).last.$2['placement'],
        'free_limit');
    expect(named(AnalyticsEvent.freeLimitReached), hasLength(1));
    await tapAndSettle(t, byLabel('Close'));
    await settle(t);
    expect(s.recorder.isActive, isFalse);
    expect(await t.runAsync(() => env.repo.get(id)), isNotNull);
    expect(await t.runAsync(() => s.gate.freeSecondsUsed()), 30);
    expect(await t.runAsync(() => s.canStartRecording()), isFalse);
  });

  testWidgets('free 30 s: starting the trial on that paywall resumes the '
      'same recording', (t) async {
    await boot(t, trial: false);
    await tapAndSettle(t, find.text('Record'));
    await tapAndSettle(t, find.byKey(const ValueKey('record-start')));
    final s = env.services;
    final id = s.recorder.current!.id;
    await env.speak(t, 35);
    await settle(t);
    expect(onTop<PaywallScreen>(t), isTrue);
    await tapAndSettle(t, find.text('Start free trial'));
    await settle(t);
    if (find.text('Allow the reminder').evaluate().isNotEmpty) {
      await tapAndSettle(t, find.text('Allow the reminder'));
    }
    await settle(t);
    expect(s.recorder.current?.id, id);
    expect(s.recorder.state, CaptureState.recording);
    // On the trial now: more audio never pauses it again.
    await env.speak(t, 60);
    await settle(t);
    expect(s.recorder.state, CaptureState.recording);
    await t.runAsync(() => s.recorder.stop());
    await settle(t);
    expect(await t.runAsync(() => s.gate.freeSecondsUsed()), 0);
  });

  testWidgets('a Stop racing a Discard never spends the free seconds',
      (t) async {
    await boot(t, trial: false);
    await tapAndSettle(t, find.text('Record'));
    await tapAndSettle(t, find.byKey(const ValueKey('record-start')));
    await env.speak(t, 20); // under the 30 s free limit
    final s = env.services;
    final id = s.recorder.current!.id;
    // Discard confirmed, and a Stop lands while it is still running.
    await t.runAsync(() => Future.wait([
          s.discardRecording(),
          s.recorder.stop(),
        ]));
    await settle(t);
    expect(await t.runAsync(() => s.gate.freeSecondsUsed()), 0);
    expect(await env.pendingJobs(t), isEmpty);
    expect(await t.runAsync(() => env.repo.get(id)), isNull);
  });

  testWidgets('over 5 hours: no "Try again"; the phone, or cut the import',
      (t) async {
    await boot(t);
    for (final id in ['rec', 'imp']) {
      await t.runAsync(() => env.addNote(id, 'Long $id',
          at: env.clock.now(),
          status: ProcessingStatus.failed,
          errorCode: 'too_long',
          error: 'Transcription works for recordings up to 5 hours, and this '
              'one is longer.'));
    }
    await t.runAsync(() => env.db.db.update('recordings',
        {'source': 'imported', 'import_file': 'import.m4a'},
        where: 'id = ?', whereArgs: ['imp']));
    env.router.pushNamed(R.note, pathParameters: {'id': 'rec'});
    await settle(t);
    expect(find.text('Longer than 5 hours'), findsOneWidget);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Transcribe on this phone instead'), findsOneWidget);
    env.router.pop();
    await settle(t);
    env.router.pushNamed(R.note, pathParameters: {'id': 'imp'});
    await settle(t);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Transcribe on this phone instead'), findsNothing);
    expect(find.textContaining('Cut the file into parts'), findsOneWidget);
  });

  testWidgets('search_used: once per visit, a length bucket, never the text',
      (t) async {
    await boot(t);
    await t.runAsync(() => env.addNote('n1', 'Budget review',
        at: env.clock.now(), summary: 'We agreed.'));
    await settle(t);
    await tapAndSettle(t, find.byType(LnSearchField));
    await t.enterText(find.byType(EditableText), 'bud');
    await settle(t);
    await t.enterText(find.byType(EditableText), 'budget review');
    await settle(t);
    await tapAndSettle(t, byLabel('Cancel'));

    expect(named(AnalyticsEvent.searchUsed).map((e) => e.$2), [
      {'chars_bucket': '11+', 'opened': false}
    ]);
    for (final (_, p) in sink.events) {
      expect(p.values, isNot(contains('budget review')));
    }
  });
}
