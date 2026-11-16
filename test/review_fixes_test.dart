import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/jobs/job_queue.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/notes/search.dart';
import 'package:longnote/features/ask/last_note.dart';

import 'helpers/test_env.dart';

/// Fixes from docs/REVIEW-FABLE-2026-11-16.md.
void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  Future<void> add(String id,
      {RecordingStatus status = RecordingStatus.completed,
      ProcessingStatus p = ProcessingStatus.none,
      String title = 'Budget meeting'}) async {
    await env.repo.insert(Recording(
        id: id, title: title, createdAt: env.clock.now(),
        status: status, durationMs: 4000));
    if (p != ProcessingStatus.none) await env.repo.setProcessing(id, p);
  }

  ProcessingJobQueue queue() => ProcessingJobQueue(
        db: env.db.db,
        repo: env.repo,
        analytics: env.analytics,
        processor: (_, _) async {},
        clock: env.clock,
        autoSchedule: false,
      );

  test('A2: a note left "Writing summary" with no job is queued at launch',
      () async {
    await add('orphan', p: ProcessingStatus.summarizing);
    await add('fine', p: ProcessingStatus.done);
    await add('live', status: RecordingStatus.recording,
        p: ProcessingStatus.queued);
    final q = queue();
    await q.resetInterrupted();
    expect((await q.job('orphan'))?['state'], JobState.pending.name);
    expect(await q.job('fine'), isNull);
    expect(await q.job('live'), isNull);
  });

  test('C3: search never returns the note being recorded', () async {
    await add('done');
    await add('live', status: RecordingStatus.recording);
    for (final fts in [env.db.ftsEnabled, false]) {
      final hits = await NoteSearch(env.repo, ftsEnabled: fts).search('budget');
      expect(hits.map((h) => h.recordingId), ['done']);
    }
  });

  test('C5: Ask only on finished transcripts', () async {
    final n = Recording(
        id: 'x', title: 't', createdAt: env.clock.now(),
        status: RecordingStatus.completed);
    n.processingStatus = ProcessingStatus.summarizing;
    expect(askable(n), isFalse);
    n.processingStatus = ProcessingStatus.done;
    expect(askable(n), isTrue);
    n
      ..processingStatus = ProcessingStatus.failed
      ..transcriptSource = 'cloud';
    expect(askable(n), isTrue); // only the summary failed
    n.transcriptSource = null;
    expect(askable(n), isFalse);
  });
}
