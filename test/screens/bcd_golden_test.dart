// Golden snapshots of screens B1-B4, C1-C4, D1-D8 at 393 x 852 with the real
// bundled fonts and Figma content. Update: flutter test --update-goldens
// test/screens/bcd_golden_test.dart
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/app/routes.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/recording/recording_controller.dart';
import 'package:longnote/features/recording/recording_screen.dart';
import 'package:longnote/main.dart';

import 'harness.dart';

// Goldens are made on Linux; macOS (CI) rasterises text differently, so they
// are skipped there.
final _skip = !Platform.isLinux;

void main() {
  setUpAll(loadAppFonts);

  late Harness h;
  GoldenRecorder? rec;

  Future<void> make({bool seed = true, bool recorder = false}) async {
    h = await Harness.create(
      entitlement: Entitlement(
          status: EntitlementStatus.trial,
          trialEndsAt: DateTime.now().add(const Duration(days: 2, minutes: -5))),
      recorder: recorder
          ? (s, repo, a) => rec = GoldenRecorder(repo: repo, analytics: a)
          : null,
    );
    if (seed) await seedFigma(h);
  }

  tearDown(() async {
    rec = null;
    await h.dispose();
  });

  // Real (blurred) shadows like the device; reset before the test ends.
  Future<void> shot(WidgetTester tester, String name) async {
    try {
      await expectLater(
          find.byType(LongnoteApp), matchesGoldenFile('../goldens/$name.png'));
    } finally {
      debugDisableShadows = true;
    }
  }

  Future<void> open(WidgetTester tester, [String location = '/notes']) async {
    phoneView(tester);
    debugDisableShadows = false;
    await tester.pumpWidget(h.app(location: location));
    await settle(tester);
  }

  Future<void> push(WidgetTester tester, String name,
      {Map<String, String> params = const {},
      Map<String, String> query = const {}}) async {
    h.router.pushNamed(name, pathParameters: params, queryParameters: query);
    await settle(tester);
  }

  // ---- B ---------------------------------------------------------------------
  testWidgets('B1 notes home', skip: _skip, (tester) async {
    await tester.runAsync(() => make());
    await open(tester);
    await shot(tester, 'b1_notes');
  });

  testWidgets('B2 empty', skip: _skip, (tester) async {
    await tester.runAsync(() => make(seed: false));
    await open(tester);
    await shot(tester, 'b2_empty');
  });

  testWidgets('B3 search', skip: _skip, (tester) async {
    await tester.runAsync(() => make());
    await open(tester);
    await push(tester, R.search);
    await tester.enterText(find.byType(TextField), 'budget');
    await tester.pump(const Duration(milliseconds: 200));
    await settle(tester);
    await shot(tester, 'b3_search');
  });

  testWidgets('B4 note actions', skip: _skip, (tester) async {
    await tester.runAsync(() => make());
    await open(tester);
    await push(tester, R.noteActions, params: {'id': q3});
    await shot(tester, 'b4_actions');
  });

  // ---- C ---------------------------------------------------------------------
  Future<void> recording(WidgetTester tester,
      {required CaptureState state, required Duration elapsed, String? banner}) async {
    await tester.runAsync(() => make(recorder: true));
    final r = Recording(
        id: 'live',
        title: 'Weekly product sync',
        createdAt: todayAt(10, 24),
        status: RecordingStatus.recording);
    await h.repo.insert(r);
    await h.repo.setNoteOptions('live', language: 'en');
    rec!
      ..current = r
      ..state = state
      ..banner = banner
      ..lastSavedAt = DateTime.now()
      ..fixedElapsed = elapsed;
    RecordingLevels.history
      ..clear()
      ..['live'] = [
        for (var i = 0; i < 60; i++)
          (0.1 + 0.9 * (((i * 53) % 29) / 29) * (0.5 + 0.5 * ((i % 7) / 7)))
      ];
    await open(tester);
    await push(tester, R.record);
  }

  testWidgets('C0 ready to record', skip: _skip, (tester) async {
    await tester.runAsync(() => make(recorder: true));
    await open(tester);
    await push(tester, R.record, query: {RecordingScreen.readyParam: '1'});
    await shot(tester, 'c0_ready');
  });

  testWidgets('C1 recording', skip: _skip, (tester) async {
    await recording(tester,
        state: CaptureState.recording, elapsed: const Duration(minutes: 42, seconds: 17));
    await shot(tester, 'c1_recording');
  });

  testWidgets('C2 paused', skip: _skip, (tester) async {
    await recording(tester,
        state: CaptureState.paused, elapsed: const Duration(minutes: 31, seconds: 5));
    await shot(tester, 'c2_paused');
  });

  testWidgets('C3 phone call', skip: _skip, (tester) async {
    await recording(tester,
        state: CaptureState.paused,
        elapsed: const Duration(minutes: 31, seconds: 5),
        banner: 'Paused by a phone call or another app. Audio up to now is saved.');
    await shot(tester, 'c3_call');
  });

  testWidgets('C4 discard', skip: _skip, (tester) async {
    await recording(tester,
        state: CaptureState.recording, elapsed: const Duration(minutes: 42, seconds: 17));
    await push(tester, R.discard);
    await shot(tester, 'c4_discard');
  });

  // ---- D ---------------------------------------------------------------------
  testWidgets('D1 processing', skip: _skip, (tester) async {
    await tester.runAsync(() => make());
    await open(tester);
    await push(tester, R.note, params: {'id': weekly});
    await shot(tester, 'd1_processing');
  });

  testWidgets('D2 summary', skip: _skip, (tester) async {
    await tester.runAsync(() => make());
    await open(tester);
    await push(tester, R.note, params: {'id': q3});
    await shot(tester, 'd2_summary');
  });

  Future<void> transcript(WidgetTester tester) async {
    await tester.runAsync(() => make());
    await open(tester);
    await push(tester, R.note,
        params: {'id': q3},
        query: {'tab': 'transcript', 'at': '${ms(0, 14, 19)}'});
  }

  testWidgets('D3 transcript', skip: _skip, (tester) async {
    await transcript(tester);
    await shot(tester, 'd3_transcript');
  });

  testWidgets('D4 speakers', skip: _skip, (tester) async {
    await transcript(tester);
    await push(tester, R.speakers, params: {'id': q3});
    await shot(tester, 'd4_speakers');
  });

  testWidgets('D5 share', skip: _skip, (tester) async {
    await tester.runAsync(() => make());
    await open(tester);
    await push(tester, R.note, params: {'id': q3});
    await push(tester, R.share, params: {'id': q3});
    await shot(tester, 'd5_share');
  });

  testWidgets('D6 summary style', skip: _skip, (tester) async {
    await tester.runAsync(() => make());
    await open(tester);
    await push(tester, R.note, params: {'id': q3});
    await push(tester, R.summaryStyle, params: {'id': q3});
    await shot(tester, 'd6_style');
  });

  testWidgets('D7 player', skip: _skip, (tester) async {
    await transcript(tester);
    await push(tester, R.player, params: {'id': q3});
    await shot(tester, 'd7_player');
  });

  testWidgets('D8 failed', skip: _skip, (tester) async {
    await tester.runAsync(() => make());
    await open(tester);
    await push(tester, R.note, params: {'id': lecture});
    await shot(tester, 'd8_failed');
  });
}
