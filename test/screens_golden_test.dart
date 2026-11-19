// Golden snapshots of the A/E/F/G screens at 393 x 852 with the bundled
// fonts and the Figma sample data. Update: flutter test --update-goldens
// test/screens_golden_test.dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/features/ask/last_note.dart';
import 'package:longnote/features/import/import_controller.dart';
import 'package:longnote/features/onboarding/onboarding_screen.dart';

import 'helpers/screens_harness.dart';

// Goldens were made on Linux; text rasterises differently on macOS (CI), so
// they only compare on Linux.
final _skip = !Platform.isLinux;

void main() {
  late ScreensEnv env;

  setUpAll(loadAppFonts);
  setUp(() async {
    env = await ScreensEnv.create();
  });
  tearDown(() => env.dispose());

  Future<void> shot(WidgetTester tester, String location, String name) async {
    phoneView(tester);
    await tester.pumpWidget(env.app(location));
    await settle(tester);
    await expectLater(
        find.byType(MaterialApp), matchesGoldenFile('goldens/$name.png'));
  }

  testWidgets('A1 paywall', skip: _skip, (t) async {
    await shot(t, '/paywall?first=1', 'a1_paywall');
  });

  testWidgets('A1 paywall, the longer part below the plans', skip: _skip, (t) async {
    phoneView(t);
    await t.pumpWidget(env.app('/paywall?first=1'));
    await settle(t);
    await t.ensureVisible(find.text('See everything you get'));
    await settle(t);
    await t.tap(find.text('See everything you get'));
    await settle(t);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/a1_paywall_more.png'));
    await t.ensureVisible(find.text('Can I try it without paying?'));
    await settle(t);
    await t.tap(find.text('Can I try it without paying?'));
    await settle(t);
    await expectLater(find.byType(MaterialApp),
        matchesGoldenFile('goldens/a1_paywall_faq.png'));
  });

  testWidgets('A0 onboarding, every screen (lectures, 1-2 hours)', skip: _skip,
      (t) async {
    phoneView(t);
    await t.pumpWidget(env.app('/onboarding'));
    const names = [
      'welcome', 'uses', 'length', 'hours', 'summary', 'speakers', 'ask',
      'privacy', 'ready', 'mic',
    ];
    for (var i = 0; i < names.length; i++) {
      await settle(t);
      if (names[i] == 'uses') {
        await t.tap(find.byKey(const ValueKey('use-lectures')));
        await t.tap(find.byKey(const ValueKey('use-meetings')));
      }
      if (names[i] == 'length') {
        await t.tap(find.byKey(const ValueKey('length-1_2h')));
      }
      await settle(t);
      await expectLater(find.byType(MaterialApp),
          matchesGoldenFile('goldens/a0_onboarding_${i.toString().padLeft(2, '0')}_${names[i]}.png'));
      if (i < names.length - 1) {
        await t.tap(find.byKey(OnboardingScreen.nextKey));
      }
    }
  });

  testWidgets('A2 trial started', skip: _skip, (t) async {
    await env.billing.purchase(annualPlan);
    await shot(t, '/paywall/started', 'a2_trial_started');
  });

  testWidgets('E1 ask start', skip: _skip, (t) async {
    await env.seedFigmaNotes();
    await env.services.kv.set(kvLastOpenedNote, 'q3');
    await shot(t, '/ask', 'e1_ask_start');
  });

  testWidgets('E2 ask answer', skip: _skip, (t) async {
    await env.seedFigmaNotes();
    await env.seedFigmaChat();
    await env.services.kv.set(kvLastOpenedNote, 'q3');
    await shot(t, '/ask', 'e2_ask_answer');
  });

  testWidgets('E3 choose a note', skip: _skip, (t) async {
    await env.seedFigmaNotes();
    await env.services.kv.set(kvLastOpenedNote, 'q3');
    await shot(t, '/ask/choose', 'e3_choose_note');
  });

  testWidgets('F1 import', skip: _skip, (t) async {
    await shot(t, '/import', 'f1_import');
  });

  testWidgets('F2 import details', skip: _skip, (t) async {
    final c = ImportController.of(env.services);
    c.pending = env.makeFile('Board meeting Nov 12.m4a', 1024)
      ..durationMs = 7540000
      ..probed = true;
    await shot(t, '/import/details', 'f2_import_details');
  });

  testWidgets('F3 import copying', skip: _skip, (t) async {
    final c = ImportController.of(env.services);
    c.jobs.add(ImportJob(
        id: 'x', title: 'Board meeting — Nov 12', totalBytes: 118 * 1024 * 1024)
      ..copiedBytes = 53 * 1024 * 1024);
    for (final (id, title, ms) in [
      ('pod', 'Podcast ep. 41 — interview.mp3', 3492000),
      ('lec', 'Lecture 5 (video).mov', 5467000),
    ]) {
      await env.repo.insert(Recording(
          id: id,
          title: title,
          createdAt: id == 'pod' ? figmaNow : figmaNow.subtract(const Duration(days: 1)),
          status: RecordingStatus.completed,
          durationMs: ms,
          source: 'imported',
          importFile: 'import.mp3',
          processingStatus: ProcessingStatus.done));
    }
    await shot(t, '/import', 'f3_import_copying');
  });

  testWidgets('G1 settings', skip: _skip, (t) async {
    await env.billing.purchase(annualPlan);
    await env.services.settings.setAudioLanguage('en');
    await shot(t, '/settings', 'g1_settings');
  });

  testWidgets('G2 audio language', skip: _skip, (t) async {
    await env.services.settings.setAudioLanguage('en');
    await shot(t, '/settings/audio-language', 'g2_audio_language');
  });

  testWidgets('G3 transcription', skip: _skip, (t) async {
    await shot(t, '/settings/transcription', 'g3_transcription');
  });

  testWidgets('G4 plan and billing', skip: _skip, (t) async {
    await env.billing.purchase(annualPlan);
    // Figma draws the reminder as scheduled (the user allowed it on A2).
    final e = env.billing.entitlement.value;
    await env.services.reminders.onTrialStarted(annualPlan, e.trialEndsAt!);
    await shot(t, '/settings/plan', 'g4_plan');
  });
}
