// Smoothness checks: a long Notes list scrolls with only the visible rows
// built, and an hour of recording ticks with Notes on screen rebuilds only the
// recording bar (not the list).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/features/notes/notes_screen.dart';
import 'package:longnote/ui/widgets.dart';

import '../helpers/screens_harness.dart' show loadAppFonts, phoneView;
import 'flow_env.dart';

void main() {
  late FlowEnv env;
  setUpAll(loadAppFonts);
  tearDown(() async {
    debugOnRebuildDirtyWidget = null;
    await env.dispose();
  });

  Future<void> boot(WidgetTester t) async {
    await t.runAsync(() async => env = await FlowEnv.create());
    phoneView(t);
    mockPlatform();
  }

  /// [n] finished notes, [perDay] per day (rows only; no audio files).
  Future<void> seedMany(WidgetTester t, int n, {required int perDay}) =>
      t.runAsync(() async {
        final now = env.clock.now();
        await env.db.db.transaction((txn) async {
          for (var i = 0; i < n; i++) {
            final at = now.subtract(Duration(days: i ~/ perDay, minutes: i % perDay));
            await txn.insert(
                'recordings',
                Recording(
                  id: 'n$i',
                  title: 'Note number $i',
                  createdAt: at,
                  status: RecordingStatus.completed,
                  durationMs: 60000 + i,
                  processingStatus: ProcessingStatus.done,
                ).toMap());
          }
        });
        env.repo.changed();
      });

  int built(Type t) => find.byType(t, skipOffstage: false).evaluate().length;

  testWidgets('500 notes: lazy rows, smooth scroll to the end and back', (t) async {
    await boot(t);
    // 250 on one day: a day group must not build all its rows at once.
    await seedMany(t, 500, perDay: 250);
    var rowBuilds = 0;
    debugOnRebuildDirtyWidget = (e, _) {
      if (e.widget is LnNoteRow) rowBuilds++;
    };
    await env.pumpApp(t);
    expect(find.text('Note number 0'), findsOneWidget);
    expect(built(LnNoteRow), lessThan(30));
    expect(rowBuilds, lessThan(40));

    final list = find.byType(CustomScrollView).first;
    var maxBuilt = 0;
    for (var i = 0; i < 40; i++) {
      await t.fling(list, const Offset(0, -2500), 4000);
      await t.pumpAndSettle();
      if (built(LnNoteRow) > maxBuilt) maxBuilt = built(LnNoteRow);
      if (find.text('Note number 499').evaluate().isNotEmpty) break;
    }
    expect(find.text('Note number 499'), findsOneWidget);
    expect(maxBuilt, lessThan(30), reason: 'only visible rows (+cache) are built');
    expect(t.takeException(), isNull);

    for (var i = 0; i < 40; i++) {
      await t.fling(list, const Offset(0, 2500), 4000);
      await t.pumpAndSettle();
      if (find.text('Note number 0').evaluate().isNotEmpty) break;
    }
    expect(find.text('Note number 0'), findsOneWidget);
    expect(find.text('Notes'), findsWidgets);
  });

  testWidgets('an hour of recording ticks on Notes does not rebuild the list',
      (t) async {
    await boot(t);
    await seedMany(t, 40, perDay: 5);
    await env.pumpApp(t);
    await tapAndSettle(t, find.text('Record'));
    await tapAndSettle(t, find.byKey(const ValueKey('record-start')));
    await env.speak(t, 1);
    await tapAndSettle(t, byLabel('Back to notes (keeps recording)'));
    expect(find.byType(NotesScreen), findsOneWidget);

    var notesBuilds = 0, rowBuilds = 0, barBuilds = 0;
    debugOnRebuildDirtyWidget = (e, _) {
      final w = e.widget;
      if (w is NotesScreen) notesBuilds++;
      if (w is LnNoteRow) rowBuilds++;
      if (w.runtimeType.toString() == '_RecordButton') barBuilds++;
    };

    final rec = env.services.recorder;
    for (var sec = 1; sec <= 3600; sec++) {
      if (sec % 60 == 0) {
        // A minute of audio reaches disk (new 5-min parts open on the way).
        FakePcm.last!.audio.add(Uint8List(32000 * 60));
        await t.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      rec.tickFlush(); // every second: "saved" + the timer
      if (sec % 5 == 0) await t.runAsync(rec.tickHeartbeat);
      await t.pump(const Duration(seconds: 1));
    }
    expect(find.textContaining('Recording · 1:00:'), findsOneWidget);
    // The bar follows the clock; the list stays put (also when a new
    // 5-minute part opens, 12 times an hour).
    expect(barBuilds, greaterThanOrEqualTo(3600));
    expect(notesBuilds, 0);
    expect(rowBuilds, 0);
    expect(rec.elapsed.inMinutes, 60);
  });
}
