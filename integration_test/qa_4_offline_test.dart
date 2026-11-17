// Simulator QA run 4: the backend is unreachable (the host blocked the
// Supabase hosts BEFORE this launch). Record and stop: the note must wait in
// "Waiting & needs attention". Then the host unblocks and the note must
// upload and finish by itself, with no tap.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/features/common/note_ready_ask.dart';
import 'package:longnote/features/note/note_screen.dart';
import 'package:longnote/features/notes/notes_screen.dart';
import 'package:longnote/features/recording/recording_screen.dart';
import 'package:path/path.dart' as p;

import 'support/file_pcm_source.dart';
import 'support/qa_harness.dart';

void main() {
  qaRunTest('QA run 4: server unreachable, then back', (qa) async {
    const s = 'Server unreachable';
    late Recording note;

    await qa.check('J1', 'App opens while the backend is blocked', () async {
      final state = File(p.join(Qa.outDir, 'requests', 'blocked-state'));
      qa.note('host: ${state.existsSync() ? state.readAsStringSync().trim() : 'no block record'}');
      await qa.launch();
      await passFirstRunIfShown(qa);
      await qa.expectOnTop<NotesScreen>();
    }, section: s);

    await qa.check('J2', 'Record ~10 s and stop: the note waits in "Waiting & needs '
        'attention"', () async {
      FilePcmSource.nextPath = Qa.audio('offline.wav');
      await qa.tap(find.text('Record'));
      await qa.tap(find.byKey(const ValueKey('record-start')));
      await qa.expectOnTop<RecordingScreen>();
      await qa.waitUntil(() async => FilePcmSource.current?.finished ?? false,
          what: 'the clip to play', timeout: const Duration(seconds: 40));
      await qa.tap(byLabel('Stop & save'));
      await qa.expectOnTop<NoteScreen>(timeout: const Duration(seconds: 5));
      await qa.wait(const Duration(seconds: 1));
      if (find.byType(NoteReadyAskSheet).evaluate().isNotEmpty) {
        await qa.tap(find.text('Not now'));
      }
      note = await qa.newestNote();
      final seen = await qa.waitForStatus(note.id, ProcessingStatus.waitingForNetwork,
          timeout: const Duration(seconds: 120));
      qa.note('statuses: ${seen.map((s) => s.name).join(' > ')}');
      final n = (await qa.services.repo.get(note.id))!;
      qa.note('shown: "${n.processingProgress}" / "${n.processingError}" (${n.errorCode})');
      await qa.shot('note-waiting');
      await qa.back();
      await qa.expectOnTop<NotesScreen>();
      await qa.waitFor(find.text('Waiting & needs attention'));
      await qa.waitFor(find.text(note.title));
    }, section: s, needs: ['J1'], timeout: const Duration(minutes: 4));

    await qa.check('J3', 'Backend reachable again: the note uploads and finishes by '
        'itself (no tap)', () async {
      await qa.hostRequest('unblock');
      final sw = Stopwatch()..start();
      final seen = await qa.waitForStatus(note.id, ProcessingStatus.done,
          timeout: const Duration(minutes: 5));
      qa.note('done ${sw.elapsed.inSeconds} s after the unblock; '
          'statuses: ${seen.map((s) => s.name).join(' > ')}');
      await qa.waitGone(find.text('Waiting & needs attention'),
          timeout: const Duration(seconds: 10));
      await qa.tap(find.text(note.title));
      await qa.expectOnTop<NoteScreen>();
      await qa.waitFor(find.text('Summary'));
      await qa.shot('note-done');
      await qa.back();
    }, section: s, needs: ['J2'], timeout: const Duration(minutes: 6));
  });
}
