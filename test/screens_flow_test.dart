// Flow tests for the A/E/F/G screens (paywall, Ask, Import, Settings).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:longnote/app/routes.dart';
import 'package:longnote/app/sheet_page.dart';
import 'package:longnote/app_services.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/cloud/api_error.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/features/ask/ask_chat_screen.dart';
import 'package:longnote/features/ask/ask_screen.dart';
import 'package:longnote/features/ask/choose_note_sheet.dart';
import 'package:longnote/features/ask/last_note.dart';
import 'package:longnote/features/import/import_controller.dart';
import 'package:longnote/features/notes/notes_screen.dart';
import 'package:longnote/features/paywall/trial_copy.dart';
import 'package:path/path.dart' as p;

import 'helpers/screens_harness.dart';

GoRouter _router(String location) => GoRouter(initialLocation: location, routes: [
      GoRoute(
        path: '/ask',
        name: R.ask,
        builder: (c, s) => const AskScreen(),
        routes: [
          GoRoute(
              path: 'choose',
              name: R.askChoose,
              pageBuilder: (c, s) =>
                  SheetPage<String>(key: s.pageKey, child: const ChooseNoteSheet())),
          GoRoute(
              path: ':id',
              name: R.askChat,
              builder: (c, s) => AskChatScreen(id: s.pathParameters['id']!)),
        ],
      ),
      // Stand-in for the note screen (another session builds it): shows what
      // the route received.
      GoRoute(
        path: '/notes/:id',
        name: R.note,
        builder: (c, s) => Scaffold(
            body: Text(
                'NOTE ${s.pathParameters['id']} ${s.uri.queryParameters['tab']} ${s.uri.queryParameters['at']}')),
      ),
    ]);

void main() {
  late ScreensEnv env;
  setUpAll(loadAppFonts);
  setUp(() async => env = await ScreensEnv.create());
  tearDown(() => env.dispose());

  // ---------------------------------------------------------------- paywall
  group('paywall -> trial started -> Notes', () {
    Future<void> openPaywall(WidgetTester t) async {
      phoneView(t);
      await t.pumpWidget(env.app('/paywall?first=1'));
      await settle(t);
    }

    testWidgets('yearly preselected; monthly updates the price line', (t) async {
      await openPaywall(t);
      String line() => t
          .widget<Text>(find.byKey(const ValueKey('paywall-price-line')))
          .data!;
      expect(line(), contains(r'Free until Nov 19, then $59.99 a year'));
      expect(find.text('Wed, Nov 18'), findsOneWidget); // reminder: 26 h before
      expect(find.text('Thu, Nov 19'), findsOneWidget); // charge = trial end
      await t.tap(find.text('Monthly'));
      await t.pumpAndSettle();
      expect(line(), contains(r'then $9.99 a month'));
      expect(find.textContaining(r'You pay $9.99 for the month'), findsOneWidget);
      await t.tap(find.text('Yearly'));
      await t.pumpAndSettle();
      expect(line(), contains(r'$59.99 a year'));
    });

    testWidgets('a plan that arrives while the paywall is open closes it '
        '(StoreKit syncing after a reinstall)', (t) async {
      await openPaywall(t);
      expect(find.text('Start free trial'), findsOneWidget);
      // Not bought on this paywall: the store reports an existing plan.
      await t.runAsync(() => env.billing.purchase(monthlyPlan));
      await settle(t);
      expect(find.text('Start free trial'), findsNothing);
      expect(find.byType(NotesScreen), findsOneWidget);
      expect(find.text('You’re in. Your trial is on.'), findsNothing);
    });

    testWidgets('start trial -> allow -> reminder scheduled -> Notes', (t) async {
      await openPaywall(t);
      await t.tap(find.text('Monthly'));
      await t.pumpAndSettle();
      await t.tap(find.text('Start free trial'));
      await settle(t);
      expect(find.text('You’re in. Your trial is on.'), findsOneWidget);
      final e = env.billing.entitlement.value;
      expect(e.status, EntitlementStatus.trial);
      expect(e.planId, monthlyPlan.id);
      expect(env.scheduler.permissionAsks, 0, reason: 'asked only on A2');
      expect(find.text('Wed, Nov 18 · 8:24 AM'), findsOneWidget);

      await t.tap(find.text('Allow the reminder'));
      await settle(t);
      expect(env.scheduler.permissionAsks, 1);
      expect(env.scheduler.scheduled.single.at,
          e.trialEndsAt!.subtract(const Duration(hours: 26)));
      expect(env.scheduler.scheduled.single.body, contains(r'$9.99'));
      expect(find.byType(NotesScreen), findsOneWidget);
      expect(await env.services.kv.getBool(AppServices.kvFirstPaywallSeen), isTrue);
    });

    testWidgets('skip asks nothing and lands on Notes', (t) async {
      await openPaywall(t);
      await t.tap(find.text('Start free trial'));
      await settle(t);
      await t.tap(find.text('Skip — I’ll remember'));
      await settle(t);
      expect(env.scheduler.permissionAsks, 0);
      expect(env.scheduler.scheduled, isEmpty);
      expect(find.byType(NotesScreen), findsOneWidget);
      expect(env.billing.entitlement.value.planId, annualPlan.id);
    });

    testWidgets('A1 says "can remind"; G4 shows the reminder Off after Skip, tap turns it on',
        (t) async {
      await openPaywall(t);
      expect(find.text('We can remind you the trial is ending.'), findsOneWidget);
      await t.tap(find.text('Start free trial'));
      await settle(t);
      await t.tap(find.text('Skip — I’ll remember'));
      await settle(t);

      await t.pumpWidget(env.app('/settings/plan'));
      await settle(t);
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Wed, Nov 18'), findsNothing);
      await t.tap(find.text('Off'));
      await settle(t);
      expect(env.scheduler.permissionAsks, 1);
      expect(env.scheduler.scheduled, hasLength(1));
      expect(find.text('Off'), findsNothing);
      expect(find.text('Wed, Nov 18'), findsOneWidget);
    });

    testWidgets('G4 after Allow shows the scheduled reminder date', (t) async {
      await openPaywall(t);
      await t.tap(find.text('Start free trial'));
      await settle(t);
      await t.tap(find.text('Allow the reminder'));
      await settle(t);
      await t.pumpWidget(env.app('/settings/plan'));
      await settle(t);
      expect(find.text('Wed, Nov 18'), findsOneWidget);
      expect(find.text('Off'), findsNothing);
    });

    testWidgets('permission denied: no reminder, still Notes', (t) async {
      env.scheduler.grant = false;
      await openPaywall(t);
      await t.tap(find.text('Start free trial'));
      await settle(t);
      await t.tap(find.text('Allow the reminder'));
      await settle(t);
      expect(env.scheduler.scheduled, isEmpty);
      expect(find.byType(NotesScreen), findsOneWidget);
    });

    testWidgets('close buys nothing; links open', (t) async {
      await openPaywall(t);
      await t.tap(find.text('Terms'));
      await t.tap(find.text('Privacy'));
      await t.pump();
      expect(env.opened.map((u) => u.path), containsAll(['/longnote/terms', '/longnote/privacy']));
      await t.tap(find.text('Restore purchase'));
      await t.pumpAndSettle();
      expect(find.textContaining('No purchase found'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('Close'));
      await settle(t);
      expect(find.byType(NotesScreen), findsOneWidget);
      expect(env.billing.entitlement.value.isActive, isFalse);
    });
  });

  test('trial copy helpers', () {
    expect(monthlyEquivalent(annualPlan), r'$5 / mo');
    expect(yearlySavingPercent(annualPlan, monthlyPlan), 50);
    final d = TrialDates.from(figmaNow, annualPlan);
    expect(d.chargeAt, DateTime(2026, 11, 19, 10, 24));
    expect(d.reminderAt, DateTime(2026, 11, 18, 8, 24));
  });

  // -------------------------------------------------------------------- Ask
  group('Ask', () {
    Future<GoRouter> open(WidgetTester t, String loc) async {
      await env.seedFigmaNotes();
      phoneView(t);
      final r = _router(loc);
      await t.pumpWidget(env.app(loc, router: r));
      await settle(t);
      return r;
    }

    testWidgets('pick a note, starter, sources open the note at that time',
        (t) async {
      final r = await open(t, '/ask');
      expect(find.text('Q3 budget review with Priya'), findsOneWidget);

      await t.tap(find.text('Asking about'));
      await settle(t);
      expect(find.text('Choose a note'), findsWidgets);
      await t.tap(find.text('Weekly product sync')); // processing: disabled
      await t.pumpAndSettle();
      expect(find.text('Weekly product sync'), findsOneWidget);
      await t.tap(find.text('Design review — onboarding v2'));
      await settle(t);
      expect(find.text('Design review — onboarding v2'), findsOneWidget);
      expect(await env.services.kv.get(kvLastOpenedNote), 'design');

      await t.tap(find.text('What did we decide?'));
      await settle(t);
      expect(env.api.questions, ['What did we decide?']);
      expect(find.text('14:02'), findsOneWidget);
      expect(find.text('Who agreed to it?'), findsOneWidget); // follow-up chip
      final stored = await env.services.chat.list('design');
      expect(stored.length, 2);

      await t.tap(find.text('14:02'));
      await settle(t);
      expect(find.text('NOTE design transcript 842000'), findsOneWidget);
      expect(r.state.uri.toString(), '/notes/design?tab=transcript&at=842000');
    });

    testWidgets('limit reached, then Try again answers once', (t) async {
      await open(t, '/ask');
      env.api.failWith = ApiException('limit_reached', 'limit');
      await t.enterText(find.byKey(const ValueKey('ask-input')), 'Who owns the forecast?');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('ask-send')));
      await settle(t);
      expect(find.textContaining('You have used today’s questions'), findsOneWidget);
      env.api.failWith = null;
      await t.tap(find.text('Try again'));
      await settle(t);
      expect(find.text('From the note'), findsOneWidget);
      final stored = await env.services.chat.list('q3');
      expect(stored.where((m) => m.text == 'Who owns the forecast?').length, 1);
      expect(stored.length, 2);
    });

    testWidgets('offline says so in plain words', (t) async {
      await open(t, '/ask');
      env.api.failWith = const SocketException('no route');
      await t.tap(find.text('What is still open?'));
      await settle(t);
      expect(find.text('You are offline. Connect to the internet and try again.'),
          findsOneWidget);
    });

    testWidgets('opened from a note: that note is preselected', (t) async {
      await open(t, '/ask/sermon');
      expect(find.text('Sunday sermon — Grace Church'), findsOneWidget);
      expect(find.text('Back'), findsOneWidget);
    });
  });

  // ----------------------------------------------------------------- Import
  group('Import', () {
    testWidgets('Files -> F2 -> import -> note created and queued', (t) async {
      phoneView(t);
      env.picker.next = env.makeFile('Board meeting Nov 12.m4a', 3 * 1024 * 1024);
      await t.pumpWidget(env.app('/import'));
      await settle(t);
      await t.tap(find.text('Files'));
      await settle(t);
      expect(find.text('Board meeting Nov 12.m4a'), findsOneWidget);
      expect(find.text('2:05:40 · 3.0 MB'), findsOneWidget);
      await t.enterText(find.byType(TextField).last, 'Board meeting — Nov 12');
      await t.tap(find.text('Import and transcribe'));
      for (var i = 0; i < 400 && (await env.repo.all()).isEmpty; i++) {
        await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 2)));
        await t.pump();
      }
      await settle(t);

      final notes = await env.repo.all();
      final n = notes.single;
      expect(n.title, 'Board meeting — Nov 12');
      expect(n.source, 'imported');
      expect(n.durationMs, 7540000);
      expect(n.language, 'auto');
      expect(n.summaryStyle, 'meeting');
      expect(n.processingStatus, ProcessingStatus.queued);
      final f = File(p.join(env.repo.storage.dirFor(n.id), n.importFile!));
      expect(f.lengthSync(), 3 * 1024 * 1024);
      expect(find.text('Recent imports'), findsOneWidget);
    });

    testWidgets('a file without sound fails in plain words', (t) async {
      env.probe.ms = null;
      final c = ImportController.of(env.services);
      final m = env.makeFile('silence.mov', 2048);
      String? id;
      await t.runAsync(() async {
        id = await c.start(m, title: 'x', language: 'auto', summaryStyle: 'meeting');
      });
      expect(id, isNull);
      expect(c.jobs.single.error, 'We could not find any sound in this file.');
      expect(await env.repo.all(), isEmpty);
    });

    testWidgets('cancel removes the partial copy', (t) async {
      final c = ImportController.of(env.services);
      final m = env.makeFile('big.mp3', 4 * 1024 * 1024);
      String? id;
      await t.runAsync(() async {
        final f = c.start(m, title: 'big', language: 'auto', summaryStyle: 'meeting');
        c.cancel(c.jobs.single);
        id = await f;
      });
      expect(id, isNull);
      expect(c.jobs, isEmpty);
      expect(await env.repo.all(), isEmpty);
      expect(Directory(env.repo.storage.rootPath).listSync(), isEmpty);
    });
  });

  // --------------------------------------------------------------- Settings
  group('Settings', () {
    Future<void> openSettings(WidgetTester t) async {
      phoneView(t, dpr: 1);
      t.view.physicalSize = const Size(393, 1400); // everything on screen
      await env.billing.purchase(annualPlan);
      await t.pumpWidget(env.app('/settings'));
      await settle(t);
    }

    Future<void> back(WidgetTester t) async {
      await t.tap(find.byKey(const ValueKey('nav-back')).last);
      await settle(t);
      expect(find.text('Speaker labels'), findsOneWidget);
    }

    testWidgets('every row opens the right screen and back works', (t) async {
      await openSettings(t);
      expect(find.text('Longnote · Yearly'), findsOneWidget);

      await t.tap(find.text('Audio language'));
      await settle(t);
      expect(find.text('Search 60+ languages'), findsOneWidget);
      await t.enterText(find.byType(TextField), 'hin');
      await t.pumpAndSettle();
      expect(find.text('Hindi'), findsOneWidget);
      expect(find.text('Hinglish (Hindi + English)'), findsOneWidget);
      expect(find.text('English'), findsNothing);
      await t.tap(find.text('Hinglish (Hindi + English)'));
      await settle(t);
      expect(await env.services.settings.audioLanguage(), 'hi_en');
      expect(find.text('Hinglish (Hindi + English)'), findsOneWidget); // G1 value

      await t.tap(find.text('Summary language'));
      await settle(t);
      expect(find.text('Same as audio'), findsWidgets);
      await back(t);

      await t.tap(find.text('Transcription'));
      await settle(t);
      await t.tap(find.text('On this phone'));
      await t.pumpAndSettle();
      expect(await env.services.settings.transcriptionMode(), TranscriptionMode.onDevice);
      expect(find.text('Where your audio goes (On this phone)'), findsOneWidget);
      // v1: no iCloud switch (iOS default backup; owner, 16 Nov).
      expect(find.text('Back up recordings to iCloud'), findsNothing);
      expect(await env.services.settings.excludeFromBackup(), isFalse);
      await back(t);
      expect(find.text('On this phone'), findsOneWidget); // G1 value

      await t.tap(find.text('Manage'));
      await settle(t);
      expect(find.text(r'$59.99 a year'), findsOneWidget);
      expect(find.text('Thu, Nov 19'), findsOneWidget);
      await t.tap(find.text('Cancel or change plan'));
      await t.pump();
      expect(env.opened.last.toString(),
          'itms-apps://apps.apple.com/account/subscriptions');
      await back(t);

      await t.tap(find.text('What happens to your audio'));
      await settle(t);
      expect(find.textContaining('deleted from the provider'), findsOneWidget);
      await back(t);

      await t.tap(find.text('Summary style'));
      await settle(t);
      expect(find.text('Speaker labels'), findsOneWidget);
      await t.tapAt(const Offset(200, 20)); // scrim closes the sheet
      await settle(t);

      await t.tap(find.text('Speaker labels'));
      await t.pumpAndSettle();
      expect(await env.services.settings.speakerLabels(), isFalse);
    });

    testWidgets('help, legal, share, restore, version', (t) async {
      await openSettings(t);
      await t.tap(find.text('Contact us'));
      await t.pump();
      expect(env.opened.last.scheme, 'mailto');
      expect(env.opened.last.path, 'support@novaralabs.in');
      expect(env.opened.last.toString(), contains('subject=Longnote%20help'));
      await t.tap(find.text('Suggest a feature'));
      await t.pump();
      expect(env.opened.last.toString(), contains('feature%20idea'));
      // Rate opens the App Store's review page, not Apple's in-app prompt
      // (never shown in TestFlight, rate-limited in production).
      await t.tap(find.text('Rate Longnote'));
      await t.pump();
      expect(env.reviews, 0);
      expect(env.opened.last.toString(),
          'https://apps.apple.com/app/id6835017154?action=write-review');
      await t.tap(find.text('Share with a friend'));
      await t.pump();
      expect(env.shared.single, contains('Longnote'));
      await t.tap(find.text('Privacy policy'));
      await t.tap(find.text('Terms of use'));
      await t.pump();
      expect(env.opened.map((u) => u.path), containsAll(['/longnote/privacy', '/longnote/terms']));
      await t.tap(find.text('Restore purchases'));
      await t.pumpAndSettle();
      expect(find.text('Your yearly plan is active.'), findsOneWidget);
      expect(find.text('Version 1.0.0 (12)'), findsOneWidget);
    });
  });
}
