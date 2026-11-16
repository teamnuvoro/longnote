// Golden snapshots of the A/E/F/G screens at 393 x 852 with the bundled
// fonts and the Figma sample data. Update: flutter test --update-goldens
// test/screens_golden_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/features/ask/last_note.dart';
import 'package:longnote/features/import/import_controller.dart';

import 'helpers/screens_harness.dart';

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

  testWidgets('A1 paywall', (t) async {
    await shot(t, '/paywall?first=1', 'a1_paywall');
  });

  testWidgets('A2 trial started', (t) async {
    await env.billing.purchase(annualPlan);
    await shot(t, '/paywall/started', 'a2_trial_started');
  });

  testWidgets('E1 ask start', (t) async {
    await env.seedFigmaNotes();
    await env.services.kv.set(kvLastOpenedNote, 'q3');
    await shot(t, '/ask', 'e1_ask_start');
  });

  testWidgets('E2 ask answer', (t) async {
    await env.seedFigmaNotes();
    await env.seedFigmaChat();
    await env.services.kv.set(kvLastOpenedNote, 'q3');
    await shot(t, '/ask', 'e2_ask_answer');
  });

  testWidgets('E3 choose a note', (t) async {
    await env.seedFigmaNotes();
    await env.services.kv.set(kvLastOpenedNote, 'q3');
    await shot(t, '/ask/choose', 'e3_choose_note');
  });

  testWidgets('F1 import', (t) async {
    await shot(t, '/import', 'f1_import');
  });

  testWidgets('F2 import details', (t) async {
    final c = ImportController.of(env.services);
    c.pending = env.makeFile('Board meeting Nov 12.m4a', 1024)
      ..durationMs = 7540000
      ..probed = true;
    await shot(t, '/import/details', 'f2_import_details');
  });

  testWidgets('F3 import copying', (t) async {
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

  testWidgets('G1 settings', (t) async {
    await env.billing.purchase(annualPlan);
    await env.services.settings.setAudioLanguage('en');
    await shot(t, '/settings', 'g1_settings');
  });

  testWidgets('G2 audio language', (t) async {
    await env.services.settings.setAudioLanguage('en');
    await shot(t, '/settings/audio-language', 'g2_audio_language');
  });

  testWidgets('G3 transcription', (t) async {
    await shot(t, '/settings/transcription', 'g3_transcription');
  });

  testWidgets('G4 plan and billing', (t) async {
    await env.billing.purchase(annualPlan);
    await shot(t, '/settings/plan', 'g4_plan');
  });
}
