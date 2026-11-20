// Whole-app flow tests: real router, real screens, real database, real job
// queue and cloud pipeline driven by a fake server. Every tap checks that the
// right screen appears, and every back/close returns to the screen before it
// with its state intact. See flow_env.dart for what is faked.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/app_services.dart';
import 'package:longnote/core/analytics/analytics.dart';
import 'package:longnote/core/analytics/meta_sink.dart';
import 'package:longnote/core/analytics/remote_analytics.dart';
import 'package:longnote/core/analytics/tracking_consent.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/summary/summary_style.dart';
import 'package:longnote/features/ask/ask_chat_screen.dart';
import 'package:longnote/features/ask/ask_screen.dart';
import 'package:longnote/features/common/note_ready_ask.dart';
import 'package:longnote/core/audio/wav.dart';
import 'package:longnote/features/import/import_controller.dart';
import 'package:longnote/features/import/import_details_sheet.dart';
import 'package:longnote/features/import/import_screen.dart';
import 'package:longnote/features/note/summary_style_sheet.dart';
import 'package:longnote/features/settings/transcription_screen.dart';
import 'package:path/path.dart' as p;
import 'package:longnote/features/note/note_screen.dart';
import 'package:longnote/features/note/share_sheet.dart';
import 'package:longnote/features/note/transcript_view.dart';
import 'package:longnote/features/notes/note_actions_sheet.dart';
import 'package:longnote/features/notes/notes_screen.dart';
import 'package:longnote/features/notes/search_screen.dart';
import 'package:longnote/features/recording/recording_screen.dart';
import 'package:longnote/features/settings/audio_language_screen.dart';
import 'package:longnote/features/settings/plan_screen.dart';
import 'package:longnote/features/settings/settings_home_screen.dart';
import 'package:longnote/features/onboarding/onboarding_screen.dart';
import 'package:longnote/features/paywall/paywall_screen.dart';
import 'package:longnote/features/paywall/trial_started_screen.dart';
import 'package:longnote/ui/widgets.dart';

import '../helpers/fake_analytics.dart';
import '../helpers/screens_harness.dart' show loadAppFonts, phoneView;
import 'flow_env.dart';

/// Taps through the onboarding pages until "Allow microphone" shows. With
/// [pick], answers the two questions (lectures + talks, over 2 hours).
Future<void> passOnboardingPages(WidgetTester t, {bool pick = false}) async {
  for (var i = 0; i < 14; i++) {
    if (find.text('Allow microphone').evaluate().isNotEmpty) return;
    if (pick && find.byKey(const ValueKey('use-lectures')).evaluate().isNotEmpty) {
      await tapAndSettle(t, find.byKey(const ValueKey('use-lectures')));
      await tapAndSettle(t, find.byKey(const ValueKey('use-talks')));
    }
    if (pick && find.byKey(const ValueKey('length-over_2h')).evaluate().isNotEmpty) {
      await tapAndSettle(t, find.byKey(const ValueKey('length-over_2h')));
    }
    await tapAndSettle(t, find.byKey(OnboardingScreen.nextKey));
  }
  fail('onboarding never reached "Allow microphone"');
}

void main() {
  late FlowEnv env;
  setUpAll(loadAppFonts);
  tearDown(() async => env.dispose());

  Future<void> boot(WidgetTester t,
      {bool firstRun = false, String location = '/notes'}) async {
    await t.runAsync(() async => env = await FlowEnv.create(firstRun: firstRun));
    phoneView(t);
    mockPlatform();
    await env.pumpApp(t, location: location);
  }

  bool onTop<T>(WidgetTester t) {
    final f = find.byType(T);
    if (f.evaluate().isEmpty) return false;
    final route = ModalRoute.of(f.evaluate().last);
    return route?.isCurrent ?? false;
  }

  testWidgets('first run: onboarding -> paywall -> start trial -> A2 -> Notes (B2)',
      (t) async {
    await boot(t, firstRun: true, location: '/onboarding');
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.text('Where your audio goes'), findsNothing); // not yet
    // Skipping both questions is allowed; the privacy page says where audio goes.
    for (var i = 0; i < 7; i++) {
      await tapAndSettle(t, find.byKey(OnboardingScreen.nextKey));
    }
    expect(find.text('Where your audio goes'), findsOneWidget);
    expect(find.textContaining('speech-to-text provider'), findsOneWidget);
    expect(find.textContaining('Transcripts are made on this phone'), findsNothing);
    // Back goes one page back, then forward again.
    await tapAndSettle(t, find.byWidgetPredicate(
        (w) => w is LnIconButton && w.semanticLabel == 'Back'));
    expect(find.text('Where your audio goes'), findsNothing);
    await tapAndSettle(t, find.byKey(OnboardingScreen.nextKey));
    await passOnboardingPages(t);
    await tapAndSettle(t, find.text('Allow microphone'));
    expect(await env.services.kv.get(OnboardingScreen.kvUses), '');
    expect(await env.services.kv.get(OnboardingScreen.kvLength), isNull);
    // No answer: the default summary style stays "Meeting notes".
    expect(await env.services.settings.defaultStyle(), SummaryStyle.meeting);

    expect(onTop<PaywallScreen>(t), isTrue);
    await tapAndSettle(t, find.text('Start free trial'));
    expect(onTop<TrialStartedScreen>(t), isTrue);
    expect(env.billing.entitlement.value.status, EntitlementStatus.trial);

    await tapAndSettle(t, find.text('Allow the reminder'));
    expect(env.scheduler.permissionAsks, 1);
    expect(onTop<NotesScreen>(t), isTrue);
    expect(find.text('Your first note is one tap away'), findsOneWidget);
    expect(find.text('Trial · 3 days left'), findsOneWidget);
    expect(find.byType(LnTabBar), findsOneWidget);
    expect(await env.services.kv.getBool(AppServices.kvFirstPaywallSeen), isTrue);
    // Back from Notes does not return to the paywall.
    expect(env.router.canPop(), isFalse);
  });

  testWidgets('first run with analytics: no ATT prompt (v1); '
      'events reach Amplitude + Meta with no note content', (t) async {
    final sink = FakeSink();
    final fb = FakeMetaEvents();
    final att = FakeTrackingConsent(answer: AttStatus.authorized);
    final meta = MetaSink(fb, enabled: true, attAuthorized: false);
    await t.runAsync(() async => env = await FlowEnv.create(
        firstRun: true, sinks: [sink, meta], tracking: att, meta: meta));
    phoneView(t);
    mockPlatform();
    await env.pumpApp(t, location: '/onboarding');
    await passOnboardingPages(t, pick: true);
    await tapAndSettle(t, find.text('Allow microphone'));
    expect(att.prompts, 0); // no "Allow tracking?" in v1
    expect(onTop<PaywallScreen>(t), isTrue);
    await tapAndSettle(t, find.text('Start free trial'));
    await tapAndSettle(t, find.text('Allow the reminder'));
    expect(onTop<NotesScreen>(t), isTrue);

    // One onboarding_step per page (Amplitude only), then the rest.
    expect(sink.names.where((n) => n == AnalyticsEvent.onboardingStep).length,
        10);
    expect(fb.calls.where((c) => c.contains('step')), isEmpty);
    // Every screen and action, in order (screen_viewed on each route change,
    // including the pop back to the paywall under A2).
    expect(sink.names.where((n) => n != AnalyticsEvent.onboardingStep), [
      AnalyticsEvent.screenViewed,
      AnalyticsEvent.micPermission,
      AnalyticsEvent.summaryStyleChanged,
      AnalyticsEvent.onboardingCompleted,
      AnalyticsEvent.screenViewed,
      AnalyticsEvent.paywallViewed,
      AnalyticsEvent.paywallPurchaseTapped,
      AnalyticsEvent.paywallPurchaseResult,
      AnalyticsEvent.trialStarted,
      AnalyticsEvent.screenViewed,
      AnalyticsEvent.notificationPermission,
      AnalyticsEvent.screenViewed,
      AnalyticsEvent.paywallClosed,
      AnalyticsEvent.screenViewed,
    ]);
    expect(
        [
          for (final (n, p) in sink.events)
            if (n == AnalyticsEvent.screenViewed) p['screen']
        ],
        ['onboarding', 'paywall', 'trialStarted', 'paywall', 'notes']);
    expect(sink.propsOf(AnalyticsEvent.micPermission),
        {'result': 'allowed', 'from': 'onboarding'});
    expect(sink.propsOf(AnalyticsEvent.summaryStyleChanged),
        {'style': 'lecture', 'from': 'onboarding'});
    expect(sink.propsOf(AnalyticsEvent.paywallPurchaseResult), {
      'plan': annualPlan.id,
      'placement': 'first_run',
      'result': 'purchased',
    });
    expect(sink.propsOf(AnalyticsEvent.notificationPermission),
        {'result': 'allowed', 'from': 'trial_started'});
    expect(sink.propsOf(AnalyticsEvent.paywallClosed),
        {'how': 'purchased', 'placement': 'first_run'});
    expect(sink.propsOf(AnalyticsEvent.onboardingCompleted),
        {
          'mic': 'allowed',
          'use_meetings': false,
          'use_lectures': true,
          'use_interviews': false,
          'use_calls': false,
          'use_talks': true,
          'use_doctor': false,
          'use_other': false,
          'first_use': 'lectures',
          'length': 'over_2h',
        });
    // The first answer (lectures) became the default summary style.
    expect(await env.services.settings.defaultStyle(), SummaryStyle.lecture);
    expect(fb.advertiserId, isFalse); // never the IDFA
    // The trial goes to Meta from the server (Apple's notification), not the app.
    expect(fb.calls, contains('CompleteRegistration'));
    expect(fb.calls, isNot(contains('StartTrial')));
    expect(fb.calls, isNot(contains('Subscribe')));
    expect(sink.propsOf(AnalyticsEvent.trialStarted)['source'], 'app');
    for (final (name, props) in sink.events) {
      for (final k in props.keys) {
        expect(isPiiKey(k), isFalse, reason: '$name: $k');
      }
    }
  });

  // ---------------------------------------------------------------- Notes home
  int tabIndex(WidgetTester t) => t.widget<LnTabBar>(find.byType(LnTabBar)).currentIndex;
  Future<void> back(WidgetTester t) async {
    final nav = find.byKey(const ValueKey('nav-back'));
    if (nav.evaluate().isNotEmpty) return tapAndSettle(t, nav.last);
    for (final l in ['Notes', 'Back', 'Settings']) {
      final f = byLabel(l).hitTestable();
      if (f.evaluate().isNotEmpty) return tapAndSettle(t, f.first);
    }
    fail('no back control on screen');
  }

  testWidgets('Notes home: every tappable goes to the right place; back returns',
      (t) async {
    await t.runAsync(() async => env = await FlowEnv.create());
    await t.runAsync(() => env.seedHome());
    phoneView(t);
    mockPlatform();
    await env.pumpApp(t);
    expect(find.text('Waiting & needs attention'), findsOneWidget);

    // Trial chip -> G4 (above the tab bar) -> back to Notes, Notes tab.
    await tapAndSettle(t, find.text('Trial · 3 days left'));
    expect(onTop<PlanScreen>(t), isTrue);
    expect(find.byType(LnTabBar).hitTestable(), findsNothing);
    await back(t);
    expect(onTop<NotesScreen>(t), isTrue);
    expect(tabIndex(t), 0);

    // Search -> B3 -> Cancel.
    await tapAndSettle(t, find.byType(LnSearchField));
    expect(onTop<SearchScreen>(t), isTrue);
    await tapAndSettle(t, byLabel('Cancel'));
    expect(onTop<NotesScreen>(t), isTrue);

    // Attention row Retry -> queued again (leaves the attention list).
    expect(find.text('Lecture 7 — Organic chemistry'), findsOneWidget);
    await tapAndSettle(t, find.text('Retry'));
    expect((await env.note(t, 'lecture')).processingStatus, ProcessingStatus.queued);
    expect(find.text('Retry'), findsNothing);
    expect(find.text('Waiting to start'), findsOneWidget);

    // Waiting row -> its note (D1, waiting for internet).
    await tapAndSettle(t, find.text('Client call — Rivera & Co'));
    expect(onTop<NoteScreen>(t), isTrue);
    expect(find.text('Waiting for internet'), findsOneWidget);
    await tapAndSettle(t, byLabel('Notes'));
    expect(onTop<NotesScreen>(t), isTrue);

    // Processing row -> D1.
    await tapAndSettle(t, find.text('Weekly product sync'));
    expect(find.text('Writing the transcript'), findsOneWidget);
    await back(t);

    // Note row -> D2 -> back.
    await tapAndSettle(t, find.text('Q3 budget review with Priya'));
    expect(onTop<NoteScreen>(t), isTrue);
    expect(find.text('Priya and Arjun agreed to cut paid ads by 20%.'), findsOneWidget);
    await tapAndSettle(t, byLabel('Notes'));
    expect(onTop<NotesScreen>(t), isTrue);

    // Long-press -> B4 -> Share or export -> D5 -> Done -> Notes.
    await t.longPress(find.text('Q3 budget review with Priya'));
    await settle(t);
    expect(onTop<NoteActionsSheet>(t), isTrue);
    await tapAndSettle(t, find.text('Share or export…'));
    expect(onTop<ShareSheet>(t), isTrue);
    await tapAndSettle(t, find.text('Done'));
    expect(onTop<NotesScreen>(t), isTrue);

    // Long-press -> Rename.
    await t.longPress(find.text('Q3 budget review with Priya'));
    await settle(t);
    await tapAndSettle(t, find.text('Rename'));
    await t.enterText(find.byType(TextField).last, 'Q3 budget — final');
    await tapAndSettle(t, find.text('Save'));
    expect(find.text('Q3 budget — final'), findsOneWidget);
    expect(onTop<NotesScreen>(t), isTrue);

    // Record pill -> C1 -> minimise -> bar -> C1 -> Stop -> D1 -> back.
    await tapAndSettle(t, find.text('Record'));
    await tapAndSettle(t, find.byKey(const ValueKey('record-start')));
    expect(onTop<RecordingScreen>(t), isTrue);
    await env.speak(t, 2);
    await tapAndSettle(t, byLabel('Back to notes (keeps recording)'));
    expect(onTop<NotesScreen>(t), isTrue);
    expect(find.textContaining('Recording · 0:0'), findsOneWidget);
    await tapAndSettle(t, byLabel('Back to recording'));
    expect(onTop<RecordingScreen>(t), isTrue);
    await tapAndSettle(t, byLabel('Stop & save'));
    await settle(t);
    // First note processing: the one-time "note ready" ask, over D1.
    expect(find.byType(NoteReadyAskSheet), findsOneWidget);
    expect(find.byType(NoteScreen), findsOneWidget);
    await dismissNotificationAsk(t);
    expect(onTop<NoteScreen>(t), isTrue);
    expect(env.scheduler.permissionAsks, 0, reason: '"Not now" asks iOS nothing');
    await tapAndSettle(t, byLabel('Notes'));
    expect(onTop<NotesScreen>(t), isTrue);
    expect(find.textContaining('Recording · '), findsNothing);
    expect(find.text('Record'), findsOneWidget);
  });

  testWidgets('tabs keep their own state and scroll position', (t) async {
    await t.runAsync(() async => env = await FlowEnv.create());
    await t.runAsync(() => env.seedHome(older: 30));
    phoneView(t);
    mockPlatform();
    await env.pumpApp(t);

    ScrollPosition pos(Type screen) => t
        .state<ScrollableState>(find
            .descendant(of: find.byType(screen), matching: find.byType(Scrollable))
            .first)
        .position;

    await t.drag(find.byType(CustomScrollView).first, const Offset(0, -900));
    await settle(t);
    final notesOffset = pos(NotesScreen).pixels;
    expect(notesOffset, greaterThan(500));

    await tapAndSettle(t, byLabel('Ask'));
    expect(onTop<AskScreen>(t), isTrue);
    expect(tabIndex(t), 1);
    await tapAndSettle(t, byLabel('Import'));
    expect(onTop<ImportScreen>(t), isTrue);
    expect(tabIndex(t), 2);
    await tapAndSettle(t, byLabel('Settings'));
    expect(onTop<SettingsHomeScreen>(t), isTrue);
    await t.drag(find.byType(Scrollable).last, const Offset(0, -300));
    await settle(t);
    await t.ensureVisible(find.text('Audio language'));
    await settle(t);
    final settingsOffset = pos(SettingsHomeScreen).pixels;
    expect(settingsOffset, greaterThan(100));

    // G2 above the shell (no tab bar), back keeps the Settings scroll.
    await tapAndSettle(t, find.text('Audio language'));
    expect(onTop<AudioLanguageScreen>(t), isTrue);
    expect(find.byType(LnTabBar).hitTestable(), findsNothing);
    await back(t);
    expect(onTop<SettingsHomeScreen>(t), isTrue);
    expect(pos(SettingsHomeScreen).pixels, settingsOffset);

    await tapAndSettle(t, byLabel('Notes'));
    expect(onTop<NotesScreen>(t), isTrue);
    expect(pos(NotesScreen).pixels, notesOffset);
    await tapAndSettle(t, byLabel('Settings'));
    expect(pos(SettingsHomeScreen).pixels, settingsOffset);

    // Ask keeps the note picked there while other tabs are used.
    await tapAndSettle(t, byLabel('Ask'));
    await tapAndSettle(t, byLabel('Choose a note').first);
    await tapAndSettle(t, find.text('Older note 3').last);
    expect(find.text('Older note 3'), findsOneWidget);
    await tapAndSettle(t, byLabel('Import'));
    await tapAndSettle(t, byLabel('Ask'));
    expect(onTop<AskScreen>(t), isTrue);
    expect(find.text('Older note 3'), findsOneWidget);
  });

  Finder answer(String text) => find.byWidgetPredicate(
      (w) => w is SelectableText && w.data == text);

  // ------------------------------------------------- record -> processed note
  testWidgets(
      'record -> minimise -> back -> stop -> processing steps in order -> '
      'summary -> transcript -> names -> Ask -> source -> share -> Notes',
      (t) async {
    await boot(t);
    expect(find.text('Your first note is one tap away'), findsOneWidget);

    await tapAndSettle(t, find.text('Record'));
    await tapAndSettle(t, find.byKey(const ValueKey('record-start')));
    expect(onTop<RecordingScreen>(t), isTrue);
    expect(env.services.recorder.isActive, isTrue);
    await env.speak(t, 3);
    await tapAndSettle(t, byLabel('Back to notes (keeps recording)'));
    expect(onTop<NotesScreen>(t), isTrue);
    expect(find.textContaining('Recording · 0:0'), findsOneWidget);
    // The live note is not listed twice (it is the bar).
    expect(find.textContaining('Recording ${env.clock.now().day}'), findsNothing);
    await tapAndSettle(t, byLabel('Back to recording'));
    expect(onTop<RecordingScreen>(t), isTrue);
    await env.speak(t, 1);

    env.encoder.hold();
    await tapAndSettle(t, byLabel('Stop & save'));
    final id = env.repo.statuses.keys.single;
    // The one-time "note ready" ask, over D1. Allow -> iOS prompt.
    await dismissNotificationAsk(t, allow: true);
    expect(env.scheduler.permissionAsks, 1);
    expect(onTop<NoteScreen>(t), isTrue);
    expect(find.text('Waiting to start'), findsOneWidget);

    // compressing
    late Future<int> run;
    await t.runAsync(() async {
      run = env.services.jobs.runDue();
      await Future.any([env.encoder.reached, run]);
    });
    await settle(t);
    expect(find.text('Preparing the audio'), findsOneWidget);

    // uploading
    env.http.hold('PATCH');
    env.encoder.release();
    await t.runAsync(() => env.http.reached('PATCH'));
    await settle(t);
    expect(find.text('Uploading securely'), findsOneWidget);
    expect(find.text('Encrypted in transit'), findsOneWidget);
    env.http.release('PATCH');

    // transcribing (the server is still working: the job polls later)
    await t.runAsync(() => run);
    await settle(t);
    expect(find.text('Uploaded securely'), findsOneWidget);
    expect(find.text('Finding who spoke'), findsOneWidget);
    // Notes shows it as a processing row meanwhile.

    // summarizing
    env.clock.advance(const Duration(seconds: 5));
    env.http.hold('summarize');
    await t.runAsync(() async {
      run = env.services.jobs.runDue();
      await env.http.reached('summarize');
    });
    await settle(t);
    // The transcript is readable while the summary is written.
    expect(find.text('Transcript'), findsOneWidget);
    expect(find.text('Writing summary'), findsOneWidget);
    env.http.release('summarize');
    await t.runAsync(() => run);
    await settle(t);

    expect(env.repo.statuses[id], [
      ProcessingStatus.queued,
      ProcessingStatus.compressing,
      ProcessingStatus.uploading,
      ProcessingStatus.queuedOnServer,
      ProcessingStatus.transcribing,
      ProcessingStatus.summarizing,
      ProcessingStatus.done,
    ]);
    expect(env.server.starts, 1);

    // done: D2 summary
    expect(find.text('Part 1 in short.'), findsOneWidget);
    expect(find.text('Summary'), findsOneWidget);
    await tapAndSettle(t, find.text('Transcript'));
    expect(find.text('We decided to launch on Monday.'), findsOneWidget);
    expect(find.text('Speaker 1'), findsWidgets);

    // Edit names (D4) -> Save -> names in the transcript.
    await tapAndSettle(t, find.text('Edit names'));
    await t.enterText(find.byType(TextField).first, 'Arjun');
    await t.enterText(find.byType(TextField).at(1), 'Priya');
    await tapAndSettle(t, find.text('Save'));
    expect(onTop<NoteScreen>(t), isTrue);
    expect(find.text('Arjun'), findsWidgets);
    expect(find.text('Speaker 1'), findsNothing);

    // Ask from the note (E2), answer with source chips.
    await tapAndSettle(t, find.text('Ask'));
    expect(onTop<AskChatScreen>(t), isTrue);
    final title = (await env.note(t, id)).title;
    expect(find.text(title), findsWidgets);
    await t.enterText(find.byKey(const ValueKey('ask-input')), 'Who sends the budget?');
    await t.pump();
    await tapAndSettle(t, find.byKey(const ValueKey('ask-send')));
    expect(answer('Priya sends it on Friday.'), findsOneWidget);
    final chip = find.byWidgetPredicate((w) =>
        w is LnPressable &&
        (w.semanticLabel ?? '').startsWith('Open the transcript at') &&
        w.semanticLabel!.endsWith('Priya'));
    expect(chip, findsOneWidget);
    await tapAndSettle(t, chip);
    // The note again, on the transcript, at the source's turn.
    expect(onTop<NoteScreen>(t), isTrue);
    expect(find.text('Priya will send the budget by Friday.'), findsOneWidget);
    final hit = t.widget<TurnRow>(find.ancestor(
        of: find.text('Priya will send the budget by Friday.'),
        matching: find.byType(TurnRow)));
    expect(hit.highlighted, isTrue);
    expect(t.widget<LnMiniPlayer>(find.byType(LnMiniPlayer).last).position,
        const Duration(milliseconds: 1600));
    await back(t); // -> E2, conversation still there
    expect(onTop<AskChatScreen>(t), isTrue);
    expect(answer('Priya sends it on Friday.'), findsOneWidget);
    await back(t); // -> note (transcript tab kept)
    expect(onTop<NoteScreen>(t), isTrue);
    expect(find.text('We decided to launch on Monday.'), findsOneWidget);

    // Share (D5) -> PDF -> Done -> note -> Notes.
    await tapAndSettle(t, byLabel('Share'));
    expect(onTop<ShareSheet>(t), isTrue);
    await tapAndSettle(t, find.text('Done'));
    expect(onTop<NoteScreen>(t), isTrue);
    await back(t);
    expect(onTop<NotesScreen>(t), isTrue);
    expect(tabIndex(t), 0);
    expect(find.text('Part 1 in short.'), findsOneWidget); // preview
  });

  // ----------------------------------------------------------------- queueing
  /// Record [seconds] of audio from Notes and come back to Notes.
  Future<String> recordNote(WidgetTester t, {int seconds = 2}) async {
    final before = (await t.runAsync(() => env.repo.all()))!.map((n) => n.id).toSet();
    await tapAndSettle(t, find.text('Record'));
    await tapAndSettle(t, find.byKey(const ValueKey('record-start')));
    expect(onTop<RecordingScreen>(t), isTrue);
    await env.speak(t, seconds);
    await tapAndSettle(t, byLabel('Stop & save'));
    await dismissNotificationAsk(t);
    expect(onTop<NoteScreen>(t), isTrue);
    await back(t);
    expect(onTop<NotesScreen>(t), isTrue);
    final after = (await t.runAsync(() => env.repo.all()))!;
    return after.firstWhere((n) => !before.contains(n.id)).id;
  }

  Future<void> bootStarted(WidgetTester t) async {
    await boot(t);
    await env.start(t);
  }

  testWidgets('three notes back to back: one job at a time, in order', (t) async {
    await bootStarted(t);
    // The clock does not move: all three are queued in the same millisecond.
    final a = await recordNote(t);
    final b = await recordNote(t);
    final c = await recordNote(t);
    for (final id in [a, b, c]) {
      expect((await env.note(t, id)).processingStatus, ProcessingStatus.queued);
    }
    expect(find.text('Waiting to start'), findsNWidgets(3));

    await env.drainQueue(t);
    expect(env.repo.started, [a, b, c]);
    expect(env.repo.finished, [a, b, c]);
    expect(env.repo.maxRunning, 1);
    expect(env.server.starts, 3);
    for (final id in [a, b, c]) {
      expect((await env.note(t, id)).processingStatus, ProcessingStatus.done);
    }
    expect(find.text('Part 1 in short.'), findsNWidgets(3));
  });

  testWidgets('a failure on note 2 does not block note 3; note 2 retries',
      (t) async {
    await bootStarted(t);
    final a = await recordNote(t);
    final b = await recordNote(t);
    final c = await recordNote(t);
    env.server.failOnFirstPoll.add(b);

    // Run until note 3 is done.
    for (var i = 0; i < 10 && !env.repo.finished.contains(c); i++) {
      await env.runQueue(t);
      env.clock.advance(const Duration(seconds: 5));
    }
    expect(env.repo.finished, [a, c]);
    final n2 = await env.note(t, b);
    expect(n2.tries, 1);
    expect(n2.processingStatus, ProcessingStatus.queued);
    expect(find.text('Trying again soon'), findsOneWidget);

    await env.drainQueue(t);
    expect(env.repo.finished, [a, c, b]);
    expect((await env.note(t, b)).tries, 0);
  });

  testWidgets('offline: head note waits for the network, then resumes by itself',
      (t) async {
    await bootStarted(t);
    env.network.online = false;
    final a = await recordNote(t);
    await env.runQueue(t);
    expect((await env.note(t, a)).processingStatus, ProcessingStatus.waitingForNetwork);
    // Notes: in "Waiting & needs attention", no Retry button.
    expect(find.text('Waiting & needs attention'), findsOneWidget);
    expect(find.text('Saved on phone · uploads when online'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(env.server.tusCreates, 0);

    // Back online: the network listener wakes the job; nothing is tapped.
    env.network.online = true;
    await settle(t);
    await env.drainQueue(t);
    expect((await env.note(t, a)).processingStatus, ProcessingStatus.done);
    expect(find.text('Waiting & needs attention'), findsNothing);
    expect(env.server.starts, 1);
  });

  testWidgets('app killed mid-upload: restart resumes, no duplicate upload/job/lines',
      (t) async {
    await bootStarted(t);
    final a = await recordNote(t, seconds: 3);

    // Kill the app while the first chunk is on its way.
    env.http.hold('PATCH');
    await t.runAsync(() async {
      unawaited(env.services.jobs.runDue()); // never finishes: the app dies
      await env.http.reached('PATCH');
    });
    expect((await env.note(t, a)).processingStatus, ProcessingStatus.uploading);
    await env.restart(t);

    // The new launch picked it up from the same upload URL.
    await env.drainQueue(t);
    expect((await env.note(t, a)).processingStatus, ProcessingStatus.done);
    expect(env.server.tusCreates, 1);
    expect(env.server.starts, 1);
    final lines = await t.runAsync(() => env.repo.transcript(a));
    expect(lines, hasLength(2));
    expect(find.text('Part 1 in short.'), findsOneWidget);

    // Killed again while the server job runs: no second job, no new upload.
    final b = await recordNote(t);
    await env.runQueue(t); // uploads, starts, defers (polling)
    expect((await env.note(t, b)).processingStatus, ProcessingStatus.transcribing);
    await env.restart(t);
    await env.drainQueue(t);
    expect((await env.note(t, b)).processingStatus, ProcessingStatus.done);
    expect(env.server.starts, 2);
    expect(env.server.tusCreates, 2);
    expect(await t.runAsync(() => env.repo.transcript(b)), hasLength(2));
    expect((await t.runAsync(() => env.repo.all()))!, hasLength(2));
  });

  testWidgets('recording while a job runs pauses processing; it resumes after',
      (t) async {
    await bootStarted(t);
    final a = await recordNote(t);
    final b = await recordNote(t);

    // Note A is uploading when the user starts another recording.
    env.http.hold('PATCH');
    late Future<int> run;
    await t.runAsync(() async {
      run = env.services.jobs.runDue();
      await env.http.reached('PATCH');
    });
    await tapAndSettle(t, find.text('Record'));
    await tapAndSettle(t, find.byKey(const ValueKey('record-start')));
    expect(onTop<RecordingScreen>(t), isTrue);
    env.http.release('PATCH');
    await t.runAsync(() => run);
    // A finished its step; B did not start while recording.
    expect(env.repo.started, [a]);
    env.clock.advance(const Duration(minutes: 1));
    await env.runQueue(t);
    expect(env.repo.started, [a]);
    expect((await env.note(t, b)).processingStatus, ProcessingStatus.queued);

    await env.speak(t, 1);
    await tapAndSettle(t, byLabel('Stop & save'));
    await env.drainQueue(t);
    expect(env.repo.finished.take(2), [a, b]);
    expect(env.repo.finished, hasLength(3));
  });

  // ------------------------------------------------------------------- import
  /// File copies run on real I/O; let them finish.
  Future<void> finishCopies(WidgetTester t) async {
    final c = ImportController.of(env.services);
    for (var i = 0; i < 50 && c.jobs.isNotEmpty; i++) {
      await settle(t, rounds: 1);
    }
    expect(c.jobs, isEmpty);
    await t.pump(const Duration(milliseconds: 500));
    await settle(t);
  }

  testWidgets('Import: Files -> F2 -> F3 copying -> note in Notes -> processed',
      (t) async {
    await bootStarted(t);
    final wav = p.join(env.dir.path, 'picked', 'Board meeting Nov 12.wav');
    await t.runAsync(() async {
      Directory(p.dirname(wav)).createSync(recursive: true);
      (WavWriter.create(wav)..append(Uint8List(32000 * 5))).close();
    });
    env.picker.next = PickedMedia(
        path: wav, name: 'Board meeting Nov 12.wav', bytes: File(wav).lengthSync());
    env.probe.ms = 5000;

    await tapAndSettle(t, byLabel('Import'));
    expect(onTop<ImportScreen>(t), isTrue);
    await tapAndSettle(t, find.text('Files'));
    expect(onTop<ImportDetailsSheet>(t), isTrue);
    expect(find.text('Board meeting Nov 12'), findsWidgets); // name field
    // F3: the copy card shows while the file is copied (real file I/O only
    // runs when we let it).
    await t.tap(find.text('Import and transcribe'));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(onTop<ImportScreen>(t), isTrue);
    expect(find.textContaining('Copying to this phone'), findsOneWidget);
    await settle(t);
    // Copied: the note is queued, listed under Recent imports.
    await finishCopies(t);
    await dismissNotificationAsk(t);
    expect(find.text('Recent imports'), findsOneWidget);
    expect(find.text('Board meeting Nov 12'), findsOneWidget);

    await tapAndSettle(t, byLabel('Notes'));
    expect(find.text('Board meeting Nov 12'), findsOneWidget);
    expect(find.text('Waiting to start'), findsOneWidget);
    await env.drainQueue(t);
    final note = (await t.runAsync(() => env.repo.all()))!.single;
    expect(note.source, 'imported');
    expect(note.processingStatus, ProcessingStatus.done);
    expect(env.encoder.calls.single.inputs.single, endsWith('import.wav'));
    expect(find.text('Part 1 in short.'), findsOneWidget);
    await tapAndSettle(t, find.text('Board meeting Nov 12'));
    expect(onTop<NoteScreen>(t), isTrue);
    expect(find.text('Part 1 in short.'), findsOneWidget);
  });

  testWidgets('the "note ready" ask also comes once after the first import',
      (t) async {
    await bootStarted(t);
    final wav = p.join(env.dir.path, 'a.wav');
    await t.runAsync(() async =>
        (WavWriter.create(wav)..append(Uint8List(32000))).close());
    env.picker.next = PickedMedia(path: wav, name: 'a.wav', bytes: File(wav).lengthSync());
    await tapAndSettle(t, byLabel('Import'));
    await tapAndSettle(t, find.text('Files'));
    await tapAndSettle(t, find.text('Import and transcribe'));
    await finishCopies(t);
    expect(find.byType(NoteReadyAskSheet), findsOneWidget);
    await tapAndSettle(t, find.text('Notify me'));
    expect(env.scheduler.permissionAsks, 1);
    expect(await env.services.kv.getBool(AppServices.kvNotificationsAsked), isTrue);

    // Never again: next recording goes straight to its note.
    await tapAndSettle(t, byLabel('Notes'));
    await tapAndSettle(t, find.text('Record'));
    await tapAndSettle(t, find.byKey(const ValueKey('record-start')));
    await env.speak(t, 1);
    await tapAndSettle(t, byLabel('Stop & save'));
    await t.pump(const Duration(seconds: 1));
    await settle(t);
    expect(find.byType(NoteReadyAskSheet), findsNothing);
    expect(onTop<NoteScreen>(t), isTrue);
  });

  // ----------------------------------------------------------------- settings
  testWidgets('Settings: audio language and summary style apply to the next note',
      (t) async {
    await bootStarted(t);
    await tapAndSettle(t, byLabel('Settings'));
    await tapAndSettle(t, find.text('Audio language'));
    expect(onTop<AudioLanguageScreen>(t), isTrue);
    await t.enterText(find.byType(TextField).first, 'Hindi');
    await settle(t);
    await tapAndSettle(t, find.text('Hindi').last);
    expect(onTop<SettingsHomeScreen>(t), isTrue);
    expect(find.text('Hindi'), findsOneWidget); // row value

    await tapAndSettle(t, find.text('Summary style'));
    expect(onTop<SummaryStyleSheet>(t), isTrue);
    await tapAndSettle(t, byLabel('Lecture → study notes'));
    await tapAndSettle(t, find.text('Save'));
    expect(onTop<SettingsHomeScreen>(t), isTrue);
    expect(find.textContaining('Lecture'), findsOneWidget);

    await tapAndSettle(t, byLabel('Notes'));
    final id = await recordNote(t);
    final n = await env.note(t, id);
    expect(n.language, 'hi');
    expect(n.summaryStyle, 'lecture');
    await env.drainQueue(t);
    expect(env.server.calls('transcribe-start').single['language'], 'hi');
    expect(env.server.calls('summarize').single['style'], 'lecture');
  });

  testWidgets('Settings: "On this phone" -> the next note is transcribed on the phone',
      (t) async {
    await bootStarted(t);
    await tapAndSettle(t, byLabel('Settings'));
    await tapAndSettle(t, find.text('Transcription'));
    expect(onTop<TranscriptionScreen>(t), isTrue);
    expect(find.byType(LnTabBar).hitTestable(), findsNothing);
    await tapAndSettle(t, find.text('On this phone'));
    await back(t);
    expect(onTop<SettingsHomeScreen>(t), isTrue);
    expect(find.text('On this phone'), findsOneWidget);

    await tapAndSettle(t, byLabel('Notes'));
    final id = await recordNote(t);
    await tapAndSettle(t, find.textContaining('Recording '));
    expect(find.textContaining('Your audio stays on this phone'), findsOneWidget);
    await env.drainQueue(t);
    final n = await env.note(t, id);
    expect(n.processingStatus, ProcessingStatus.done);
    expect(n.transcriptSource, 'on_device');
    expect(env.server.tusCreates, 0);
    expect(env.server.starts, 0);
    expect(env.encoder.calls, isEmpty);
    expect(await t.runAsync(() => env.repo.transcript(id)), isNotEmpty);
    expect(find.text('Summary'), findsOneWidget);
  });

  // --------------------------------------------------------------- deep links
  testWidgets('deep links: D1 "what happens to your audio" -> G3; plan card -> G4',
      (t) async {
    await bootStarted(t);
    final id = await recordNote(t);
    await tapAndSettle(t, find.textContaining('Recording '));
    expect(onTop<NoteScreen>(t), isTrue);
    await tapAndSettle(t, byLabel('What happens to your audio'));
    expect(onTop<TranscriptionScreen>(t), isTrue);
    expect(find.byType(LnTabBar).hitTestable(), findsNothing);
    await back(t);
    expect(onTop<NoteScreen>(t), isTrue);
    await back(t);
    expect(onTop<NotesScreen>(t), isTrue);
    expect(tabIndex(t), 0, reason: 'G3 from a note must not switch tabs');
    expect((await env.note(t, id)).processingStatus, ProcessingStatus.queued);

    await tapAndSettle(t, byLabel('Settings'));
    await tapAndSettle(t, find.text('Manage'));
    expect(onTop<PlanScreen>(t), isTrue);
    await back(t);
    expect(onTop<SettingsHomeScreen>(t), isTrue);
    expect(tabIndex(t), 3);
  });

  testWidgets('C1 language chip and a rename while recording survive Stop',
      (t) async {
    await bootStarted(t);
    await tapAndSettle(t, find.text('Record'));
    await tapAndSettle(t, find.byKey(const ValueKey('record-start')));
    await env.speak(t, 1);
    final id = env.services.recorder.current!.id;
    await t.runAsync(() => env.repo.setNoteOptions(id, language: 'fr'));
    await t.runAsync(() => env.repo.rename(id, 'Cours de chimie'));
    await settle(t);
    await env.speak(t, 1);
    await tapAndSettle(t, byLabel('Stop & save'));
    await dismissNotificationAsk(t);
    final n = await env.note(t, id);
    expect(n.language, 'fr');
    expect(n.title, 'Cours de chimie');
    expect(n.summaryStyle, 'meeting');
    expect(find.text('Cours de chimie'), findsOneWidget);
  });

  testWidgets('fast double taps push one screen, not two', (t) async {
    await t.runAsync(() async => env = await FlowEnv.create());
    await t.runAsync(() => env.seedHome(older: 3));
    phoneView(t);
    mockPlatform();
    await env.pumpApp(t);

    int count(Type t) => find.byType(t, skipOffstage: false).evaluate().length;
    final row = find.text('Q3 budget review with Priya');
    // Second tap before the next frame (the page has not moved yet).
    await t.tap(row);
    await t.tap(row, warnIfMissed: false);
    await settle(t);
    expect(count(NoteScreen), 1);
    await back(t);
    expect(count(NoteScreen), 0);

    // Two different rows in quick succession: still one screen.
    await t.tap(find.text('Older note 0'));
    await t.pump(const Duration(milliseconds: 16));
    await t.tap(find.text('Older note 1'), warnIfMissed: false);
    await settle(t);
    expect(count(NoteScreen), 1);
    await back(t);

    // Search, Record: same.
    await t.tap(find.byType(LnSearchField));
    await t.pump(const Duration(milliseconds: 40));
    await t.tap(find.byType(LnSearchField), warnIfMissed: false);
    await settle(t);
    expect(count(SearchScreen), 1);
    await tapAndSettle(t, byLabel('Cancel'));
    final pill = t.getCenter(find.text('Record'));
    await t.tapAt(pill);
    await t.pump(const Duration(milliseconds: 40));
    await t.tapAt(pill);
    await settle(t);
    expect(count(RecordingScreen), 1);
  });
}
