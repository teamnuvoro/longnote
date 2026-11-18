import 'dart:async';
// Flow tests for screens B (Notes), C (Recording) and D (Note): real
// router, real database and recorder (fake microphone), fake share/audio.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/app/routes.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/recording/recording_controller.dart';
import 'package:longnote/features/note/note_screen.dart';
import 'package:longnote/features/notes/notes_screen.dart';
import 'package:longnote/features/recording/recording_screen.dart';
import 'package:longnote/ui/widgets.dart';

import 'harness.dart';

/// A tappable (LnPressable / LnToggle) by its accessibility label.
Finder byLabel(String label) => find.byWidgetPredicate((w) =>
    (w is LnPressable && w.semanticLabel == label) ||
    (w is LnToggle && w.semanticLabel == label));

void main() {
  late Harness h;
  setUpAll(loadAppFonts);

  Future<void> boot(WidgetTester tester, {bool seed = true}) async {
    await tester.runAsync(() async {
      h = await Harness.create(
          entitlement: Entitlement(
              status: EntitlementStatus.trial,
              trialEndsAt: DateTime.now().add(const Duration(days: 3))));
      if (seed) await seedFigma(h);
    });
    phoneView(tester);
    mockClipboard();
    await tester.pumpWidget(h.app());
    await settle(tester);
  }

  tearDown(() async => h.dispose());

  /// Lets real I/O (file close, etc.) finish, then settles the UI.
  Future<void> drain(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await settle(tester);
  }

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
    await settle(tester);
  }

  testWidgets('Notes -> note -> Summary/Transcript -> Edit names -> save -> back',
      (tester) async {
    await boot(tester);
    expect(find.text('Waiting & needs attention'), findsOneWidget);
    expect(find.text('Trial · 3 days left'), findsOneWidget);

    await tap(tester, find.text('Q3 budget review with Priya'));
    expect(find.byType(NoteScreen), findsOneWidget);
    expect(find.text('DECISIONS'), findsOneWidget);
    expect(find.text('Send the new Q3 forecast to finance'), findsOneWidget);

    await tap(tester, find.text('Transcript'));
    expect(find.text('Arjun'), findsWidgets);
    expect(find.textContaining('Paused 2 min'), findsOneWidget);

    // Tap a line: playback seeks there and plays.
    await tap(tester, find.textContaining('Sorry, I’m back').first);
    expect(h.engines.last.calls, contains('play'));

    // Speakers off -> plain transcript.
    await tap(tester, byLabel('Speakers'));
    expect(find.text('Arjun'), findsNothing);
    await tap(tester, byLabel('Speakers'));

    await tap(tester, find.text('Edit names'));
    expect(find.text('We found 3 voices. Name them once and the transcript, summary and exports update.'),
        findsOneWidget);
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(2), 'Dev');
    await tap(tester, find.text('Save'));
    expect(find.text('Dev'), findsWidgets);
    expect(find.text('Speaker 3'), findsNothing);

    await tap(tester, find.text('Notes'));
    expect(find.byType(NoteScreen), findsNothing);
    expect(find.byType(NotesScreen), findsOneWidget);
  });

  testWidgets('Merge speakers joins two voices', (tester) async {
    await boot(tester);
    h.router.pushNamed(R.speakers, pathParameters: {'id': q3});
    await settle(tester);
    await tap(tester, byLabel('Merge speakers'));
    // "This voice" = Speaker 3, "same person as" = Priya.
    Finder chip(String t) =>
        find.descendant(of: find.byType(LnPillChip), matching: find.text(t));
    await tap(tester, chip('Speaker 3').first);
    await tap(tester, chip('Priya').last);
    await tap(tester, find.text('Merge'));
    final names = await tester.runAsync(() => h.services.speakers.names(q3));
    expect(names!.keys, unorderedEquals(['1', '2']));
  });

  testWidgets('Record opens a ready screen: nothing records until Start',
      (tester) async {
    await boot(tester, seed: false);
    final c = h.services.recorder;
    Future<int> count() async =>
        (await tester.runAsync(() => h.repo.all()))!.length;
    final start = find.byKey(const ValueKey('record-start'));

    // Record -> ready screen, nothing recording.
    await tap(tester, find.text('Record'));
    expect(find.byType(RecordingScreen), findsOneWidget);
    expect(find.text('New recording'), findsOneWidget);
    expect(find.text('Tap Start when you’re ready.'), findsOneWidget);
    expect(start, findsOneWidget);
    // The same screen as while recording: Start in the middle, Discard and
    // Stop & save in their places (greyed out, not tappable yet), the
    // language chip and Mark moment.
    expect(byLabel('Start'), findsOneWidget);
    expect(byLabel('Pause'), findsNothing);
    expect(byLabel('Stop & save'), findsOneWidget);
    expect(byLabel('Discard'), findsOneWidget);
    expect(find.text('Auto-detect'), findsOneWidget);
    expect(find.text('Mark moment'), findsOneWidget);
    expect(find.text('00:00:00'), findsOneWidget);
    await tap(tester, byLabel('Stop & save'));
    await tap(tester, byLabel('Discard'));
    await tap(tester, find.text('Mark moment'));
    expect(find.text('Discard this recording?'), findsNothing);
    expect(find.textContaining('Moment marked'), findsNothing);
    expect(find.byType(RecordingScreen), findsOneWidget);
    expect(c.state, CaptureState.idle);
    expect(await count(), 0);

    // Close: back on Notes, still nothing recorded.
    await tap(tester, byLabel('Close (nothing is recorded)'));
    expect(find.byType(RecordingScreen), findsNothing);
    expect(c.isActive, isFalse);
    expect(await count(), 0);

    // Record -> pick a language -> Start: the same screen goes live and the
    // note keeps the language picked before Start.
    await tap(tester, find.text('Record'));
    expect(c.state, CaptureState.idle);
    await tap(tester, find.text('Auto-detect'));
    await tap(tester, find.text('Bengali').last);
    expect(find.text('Bengali'), findsOneWidget);
    expect(c.state, CaptureState.idle);
    expect(await count(), 0);
    await tap(tester, start);
    expect(c.state, CaptureState.recording);
    expect(find.byType(RecordingScreen), findsOneWidget);
    expect(start, findsNothing);
    expect(byLabel('Pause'), findsOneWidget);
    expect(byLabel('Stop & save'), findsOneWidget);
    expect(await count(), 1);
    final note = await tester.runAsync(() => h.repo.get(c.current!.id));
    expect(note!.language, 'bn');
    await tap(tester, byLabel('Stop & save'));
    await drain(tester);
  });

  testWidgets('a start that hangs unlocks Close after 15 s', (tester) async {
    await boot(tester, seed: false);
    FakePcm.startGate = Completer<void>();
    addTearDown(() => FakePcm.startGate = null);
    await tap(tester, find.text('Record'));
    await tester.pump(const Duration(milliseconds: 500)); // open tap guard
    await tester.tap(find.byKey(const ValueKey('record-start')));
    await tester.pump();
    final close = byLabel('Close (nothing is recorded)');
    expect(tester.widget<LnPressable>(close).onPressed, isNull);
    await tester.pump(const Duration(seconds: 16));
    expect(find.text('Starting is taking long. Close and try again.'),
        findsOneWidget);
    expect(tester.widget<LnPressable>(close).onPressed, isNotNull);
    await tester.pump(const Duration(seconds: 3)); // toast goes away
    await tester.tap(close, warnIfMissed: true);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(RecordingScreen), findsNothing);
    FakePcm.startGate!.complete();
    await drain(tester);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Record -> pause -> resume -> stop -> note appears processing',
      (tester) async {
    await boot(tester, seed: false);
    expect(find.text('Your first note is one tap away'), findsOneWidget);

    await tap(tester, find.text('Record'));
    await tap(tester, find.byKey(const ValueKey('record-start')));
    expect(find.byType(RecordingScreen), findsOneWidget);
    final c = h.services.recorder;
    expect(c.state, CaptureState.recording);
    FakePcm.last!.audio.add(Uint8List(64000)); // 2 s of audio
    await drain(tester);
    c.tickFlush();
    await settle(tester);
    expect(find.text('Saved'), findsOneWidget);
    expect(find.text('00:00:02'), findsOneWidget);
    expect(find.text('You can lock your phone. Recording continues.'), findsOneWidget);

    await tap(tester, byLabel('Pause'));
    expect(c.state, CaptureState.paused);
    expect(find.textContaining('Nothing is recorded until you resume'), findsOneWidget);

    await tap(tester, byLabel('Resume'));
    expect(c.state, CaptureState.recording);

    // Minimise: back to Notes while recording, then the bar brings it back.
    await tap(tester, byLabel('Back to notes (keeps recording)'));
    expect(find.byType(RecordingScreen), findsNothing);
    expect(find.textContaining('Recording · '), findsOneWidget);
    await tap(tester, byLabel('Back to recording'));
    expect(find.byType(RecordingScreen), findsOneWidget);

    await tap(tester, find.text('Mark moment'));
    expect(find.textContaining('Moment marked'), findsOneWidget);

    await tap(tester, byLabel('Stop & save'));
    await drain(tester);
    expect(c.state, CaptureState.idle);
    expect(find.byType(NoteScreen), findsOneWidget);
    expect(find.text('Saved on your phone'), findsOneWidget);
    // First note processing: the one-time "note ready" ask.
    expect(find.text('Tell you when it’s ready?'), findsOneWidget);
    await tap(tester, find.text('Not now'));

    await tap(tester, find.text('Notes'));
    final all = await tester.runAsync(() => h.repo.all());
    expect(all, hasLength(1));
    expect(all!.first.processingStatus, ProcessingStatus.queued);
    expect(find.text(all.first.title), findsOneWidget);
    expect(find.text('Waiting to start'), findsOneWidget);
  });

  testWidgets('Discard asks again and deletes the recording', (tester) async {
    await boot(tester, seed: false);
    await tap(tester, find.text('Record'));
    await tap(tester, find.byKey(const ValueKey('record-start')));
    await tap(tester, byLabel('Discard'));
    expect(find.text('Discard this recording?'), findsOneWidget);
    await tap(tester, find.text('Keep recording'));
    expect(h.services.recorder.state, CaptureState.recording);
    await tap(tester, byLabel('Discard'));
    await tap(tester, find.text('Discard recording'));
    await drain(tester);
    expect(h.services.recorder.state, CaptureState.idle);
    expect(find.byType(RecordingScreen), findsNothing);
    final all = await tester.runAsync(() => h.repo.all());
    expect(all, isEmpty);
  });

  testWidgets('Phone call shows the honest banner and Resume now', (tester) async {
    await boot(tester, seed: false);
    await tap(tester, find.text('Record'));
    await tap(tester, find.byKey(const ValueKey('record-start')));
    final c = h.services.recorder;
    await c.pause();
    c.banner = 'Paused by a phone call or another app. Audio up to now is saved.';
    c.notifyListeners();
    await settle(tester);
    expect(find.text('Paused for a phone call'), findsOneWidget);
    expect(find.text('Resume now'), findsOneWidget);
    await tap(tester, byLabel('Resume now'));
    expect(c.state, CaptureState.recording);
  });

  testWidgets('Long-press -> rename, then long-press -> delete with confirm',
      (tester) async {
    await boot(tester);
    await tester.longPress(find.text('Design review — onboarding v2'));
    await settle(tester);
    expect(find.text('Rename'), findsOneWidget);
    await tap(tester, find.text('Rename'));
    await tester.enterText(find.byType(TextField).last, 'Design review v3');
    await tap(tester, find.text('Save'));
    expect(find.text('Design review v3'), findsOneWidget);

    await tester.longPress(find.text('Design review v3'));
    await settle(tester);
    await tap(tester, find.text('Delete note…'));
    expect(find.text('Delete this note?'), findsOneWidget);
    await tap(tester, find.text('Cancel'));
    expect(find.text('Delete this note?'), findsNothing);
    await tap(tester, find.text('Delete note…'));
    await tap(tester, find.text('Delete note'));
    expect(find.text('Design review v3'), findsNothing);
    expect(await tester.runAsync(() => h.repo.get(design)), isNull);
  });

  testWidgets('Delete from the note screen goes back to Notes', (tester) async {
    await boot(tester);
    await tap(tester, find.text('Q3 budget review with Priya'));
    await tap(tester, byLabel('More'));
    await tap(tester, find.text('Delete note…'));
    await tap(tester, find.text('Delete note'));
    expect(find.byType(NoteScreen), findsNothing);
    expect(find.text('Q3 budget review with Priya'), findsNothing);
    expect(find.byType(NotesScreen), findsOneWidget);
  });

  testWidgets('Long-press on a failed note -> copy summary is disabled, Retry works',
      (tester) async {
    await boot(tester);
    await tap(tester, find.text('Retry'));
    final n = await tester.runAsync(() => h.repo.get(lecture));
    expect(n!.processingStatus, ProcessingStatus.queued);
  });

  testWidgets('Search -> transcript hit -> opens the note at that time',
      (tester) async {
    await boot(tester);
    await tap(tester, find.byType(LnSearchField));
    await tester.enterText(find.byType(TextField), 'eighteen');
    await tester.pump(const Duration(milliseconds: 200));
    await settle(tester);
    expect(find.text('1 note · 1 match'), findsOneWidget);
    expect(find.text('Transcript · 14:19 · Arjun'), findsOneWidget);
    await tap(tester, find.text('Transcript · 14:19 · Arjun'));
    final screen = tester.widget<NoteScreen>(find.byType(NoteScreen));
    expect(screen.atMs, ms(0, 14, 19));
    expect(find.text('Edit names'), findsOneWidget); // transcript tab
    expect(find.text('14:19'), findsWidgets); // mini player position

    // Scope chips filter.
    await tap(tester, find.text('Notes'));
    await tap(tester, byLabel('Titles'));
    expect(find.text('No matches'), findsOneWidget);
  });

  testWidgets('Share sheet: every option does its job', (tester) async {
    await boot(tester);
    await tap(tester, find.text('Q3 budget review with Priya'));
    await tap(tester, byLabel('Share'));
    expect(find.text('Audio file'), findsOneWidget);

    await tap(tester, find.text('PDF'));
    await tap(tester, find.text('Summary').last);
    await tap(tester, find.text('Transcript').last);
    await tap(tester, byLabel('Copy summary'));
    expect(h.share.calls.where((c) => c.startsWith('text:transcript')).single,
        contains('Priya:'));

    await tap(tester, byLabel('Include speaker names'));
    await tap(tester, find.text('Transcript').last);
    await tap(tester, find.text('PDF'));

    await tap(tester, find.text('Audio file'));
    await tap(tester, find.text('M4A · smaller'));
    await tap(tester, find.text('Audio file'));
    await tap(tester, find.text('WAV · original quality'));

    final calls = h.share.calls.map((c) => c.split('\n').first).toList();
    expect(calls[0], 'pdf:names');
    expect(calls[1], startsWith('text:summary'));
    expect(calls[3], 'copy:summary');
    expect(h.share.calls[4], isNot(contains('Priya:')));
    expect(calls[5], 'pdf:no-names');
    expect(calls.sublist(6), ['m4a', 'wav']);

    await tap(tester, find.text('Done'));
    expect(find.text('Audio file'), findsNothing);
  });

  testWidgets('Change style -> apply saves on the note and re-summarizes',
      (tester) async {
    await boot(tester);
    await tap(tester, find.text('Q3 budget review with Priya'));
    await tap(tester, find.text('Change style'));
    await tap(tester, find.text('Lecture → study notes'));
    await tap(tester, find.text('Your own instructions'));
    await tester.enterText(find.byType(TextField).last, 'List every number');
    await tap(tester, find.text('Apply'));
    final n = await tester.runAsync(() => h.repo.get(q3));
    expect(n!.summaryStyle, 'lecture');
    expect(n.customInstructions, 'List every number');
    // No cloud in tests -> goes through the queue.
    expect(n.processingStatus, ProcessingStatus.queued);
    expect(find.text('Your own instructions'), findsOneWidget);
  });

  testWidgets('Mini player -> full player: play, skip, speed, moment',
      (tester) async {
    await boot(tester);
    await tap(tester, find.text('Q3 budget review with Priya'));
    await tap(tester, byLabel('Open player'));
    expect(find.text('Marked moments'), findsOneWidget);
    await tap(tester, byLabel('Play').last);
    final e = h.engines.single;
    expect(e.playing, isTrue);
    await tap(tester, byLabel('Forward 15 seconds'));
    expect(e.calls.last, startsWith('seek'));
    await tap(tester, byLabel('Speed 1.5×'));
    expect(e.speed, 1.5);
    await tap(tester, find.text('Budget number agreed'));
    expect(e.calls, contains('seek 4 ${ms(0, 22, 48) - 4 * (ms(1, 12, 40) ~/ 15)}'));
    await tester.drag(find.text('Marked moments'), const Offset(0, 600));
    await settle(tester);
    expect(find.text('Marked moments'), findsNothing);
  });

  testWidgets('Failed note: Try again and Transcribe on this phone',
      (tester) async {
    await boot(tester);
    await tap(tester, find.text('Lecture 7 — Organic chemistry'));
    expect(find.text('We couldn’t make the transcript'), findsOneWidget);
    await tap(tester, byLabel('Send the error report'));
    expect(h.share.calls.last, startsWith('text:error_report'));
    await tap(tester, find.text('Transcribe on this phone instead'));
    var n = await tester.runAsync(() => h.repo.get(lecture));
    expect(n!.transcriptionMode, TranscriptionMode.onDevice);
    expect(n.processingStatus, ProcessingStatus.queued);
    // The screen now shows the processing steps (on this phone).
    expect(find.text('Writing the transcript'), findsOneWidget);
  });
}
