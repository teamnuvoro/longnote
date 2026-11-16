// Simulator QA run 2: start a recording, let ~10 s reach the disk, then end
// the app like a force-quit from the app switcher (SIGKILL: nothing runs
// after it). Run 3 checks that the recording was kept and processed.
import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/features/notes/notes_screen.dart';
import 'package:longnote/features/recording/recording_screen.dart';

import 'support/file_pcm_source.dart';
import 'support/qa_harness.dart';

void main() {
  qaRunTest('QA run 2: force-quit while recording', (qa) async {
    const s = 'Force-quit';
    await qa.check('E1', 'App reopens on Notes (second launch)', () async {
      await qa.launch();
      await passFirstRunIfShown(qa);
      await qa.expectOnTop<NotesScreen>();
    }, section: s);

    await qa.check('E2', 'Record ~10 s, then force-quit the app while recording',
        () async {
      FilePcmSource.nextPath = Qa.audio('killed.wav');
      await qa.tap(find.text('Record'));
      await qa.expectOnTop<RecordingScreen>();
      await qa.waitUntil(() async => FilePcmSource.current?.finished ?? false,
          what: 'the clip to play', timeout: const Duration(seconds: 40));
      // The recorder syncs to disk every second.
      await qa.wait(const Duration(milliseconds: 1500));
      final c = qa.services.recorder;
      expect(c.isActive, isTrue);
      qa.note('recording ${c.current!.id}: ${c.elapsed.inMilliseconds} ms when killed');
    }, section: s, needs: ['E1']);

    if (qa.services.recorder.isActive) await qa.forceQuit();
  });
}
