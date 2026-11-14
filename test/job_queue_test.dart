import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/analytics/analytics.dart';
import 'package:longnote/core/audio/wav.dart';
import 'package:longnote/core/jobs/job_queue.dart';
import 'package:longnote/core/jobs/processing_pipeline.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/summary/local_extractive_summarizer.dart';
import 'package:longnote/core/summary/summary_service.dart';
import 'package:longnote/core/transcription/fake_transcriber.dart';
import 'package:path/path.dart' as p;

import 'helpers/test_env.dart';
import 'helpers/fakes.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  Future<List<String>> makeRecording(String id, {int segments = 2}) async {
    await env.repo.insert(Recording(
        id: id, title: 't', createdAt: env.clock.now(),
        status: RecordingStatus.completed, durationMs: segments * 2000));
    final dir = env.repo.storage.dirFor(id);
    final paths = <String>[];
    for (var i = 0; i < segments; i++) {
      final name = 'seg_000$i.wav';
      (WavWriter.create(p.join(dir, name))..append(pcm(64000, seed: i)))
          .close();
      await env.repo.upsertSegment(AudioSegment(
          recordingId: id, index: i, fileName: name,
          dataBytes: 64000, closed: true));
      paths.add(p.join(dir, name));
    }
    return paths;
  }

  ProcessingJobQueue queue(JobProcessor proc, {int max = 3}) =>
      ProcessingJobQueue(
        db: env.db.db,
        repo: env.repo,
        analytics: env.analytics,
        processor: proc,
        clock: env.clock,
        maxAutoAttempts: max,
        baseDelay: const Duration(seconds: 10),
        maxDelay: const Duration(seconds: 25),
        autoSchedule: false,
      );

  test('backoff doubles and is capped', () {
    final q = queue((_, _) async {});
    expect(q.backoffFor(1), const Duration(seconds: 10));
    expect(q.backoffFor(2), const Duration(seconds: 20));
    expect(q.backoffFor(3), const Duration(seconds: 25)); // capped
    expect(q.backoffFor(9), const Duration(seconds: 25));
  });

  test('failures retry with backoff, then succeed', () async {
    await makeRecording('r');
    var calls = 0;
    final q = queue((id, progress) async {
      calls++;
      if (calls < 3) throw Exception('boom $calls');
    });
    await q.enqueue('r');

    expect(await q.runDue(), 1); // attempt 1 fails
    expect((await env.repo.get('r'))!.processingStatus, ProcessingStatus.queued);
    expect(await q.runDue(), 0, reason: 'not due before backoff');

    env.clock.advance(const Duration(seconds: 9));
    expect(await q.runDue(), 0);
    env.clock.advance(const Duration(seconds: 1));
    expect(await q.runDue(), 1); // attempt 2 fails
    final job = (await q.job('r'))!;
    expect(job['attempts'], 2);
    expect(job['state'], 'pending');

    env.clock.advance(const Duration(seconds: 20));
    expect(await q.runDue(), 1); // attempt 3 succeeds
    expect((await env.repo.get('r'))!.processingStatus, ProcessingStatus.done);
    expect(calls, 3);

    final names = (await env.analytics.recent()).map((e) => e.name).toList();
    expect(names.where((n) => n == AnalyticsEvent.processingFailed), hasLength(2));
    expect(names.where((n) => n == AnalyticsEvent.processingRetried), hasLength(2));
  });

  test('after max attempts it is "failed"; manual retry starts over', () async {
    await makeRecording('r');
    var fail = true;
    final q = queue((_, _) async {
      if (fail) throw Exception('model download failed');
    }, max: 2);
    await q.enqueue('r');
    await q.runDue();
    env.clock.advance(const Duration(minutes: 1));
    await q.runDue();
    final r = (await env.repo.get('r'))!;
    expect(r.processingStatus, ProcessingStatus.failed);
    expect(r.processingError, contains('model download failed'));
    env.clock.advance(const Duration(hours: 1));
    expect(await q.runDue(), 0, reason: 'failed jobs wait for the user');

    fail = false;
    await q.retry('r');
    expect((await q.job('r'))!['attempts'], 0);
    expect(await q.runDue(), 1);
    expect((await env.repo.get('r'))!.processingStatus, ProcessingStatus.done);
    final retried = await env.analytics.recent(name: AnalyticsEvent.processingRetried);
    expect(retried.first.props['manual'], true);
  });

  test('processing failure NEVER deletes or changes audio', () async {
    final paths = await makeRecording('r', segments: 3);
    final before = [for (final f in paths) File(f).readAsBytesSync()];
    final fake = FakeTranscriber(failTimes: 100);
    final pipeline = ProcessingPipeline(
      repo: env.repo,
      transcriber: () => fake,
      summaries: SummaryService(
          kv: env.kv,
          apple: UnavailableSummarizer('apple'),
          cloud: UnavailableSummarizer('cloud'),
          local: LocalExtractiveSummarizer()),
    );
    final q = queue(pipeline.process, max: 3);
    await q.enqueue('r');
    for (var i = 0; i < 3; i++) {
      await q.runDue();
      env.clock.advance(const Duration(minutes: 1));
    }
    expect((await env.repo.get('r'))!.processingStatus, ProcessingStatus.failed);
    for (var i = 0; i < paths.length; i++) {
      expect(File(paths[i]).existsSync(), isTrue);
      expect(File(paths[i]).readAsBytesSync(), before[i]);
    }
    expect((await env.repo.segments('r')), hasLength(3));
  });

  test('pipeline resumes per segment: retry does not redo finished parts',
      () async {
    await makeRecording('r', segments: 3);
    final fake = _FailOnCall(2);
    final pipeline = ProcessingPipeline(
      repo: env.repo,
      transcriber: () => fake,
      summaries: SummaryService(
          kv: env.kv,
          apple: UnavailableSummarizer('apple'),
          cloud: UnavailableSummarizer('cloud'),
          local: LocalExtractiveSummarizer()),
    );
    final q = queue(pipeline.process);
    await q.enqueue('r');
    await q.runDue(); // part 1 ok, part 2 fails
    final segs = await env.repo.segments('r');
    expect(segs.map((s) => s.transcribed), [true, false, false]);
    env.clock.advance(const Duration(minutes: 1));
    await q.runDue(); // resumes at part 2
    expect((await env.repo.get('r'))!.processingStatus, ProcessingStatus.done);
    expect(fake.calls, 4, reason: '1 ok + 1 failed + 2 on resume, not 5');
    final lines = await env.repo.transcript('r');
    // Timestamps are offset by earlier parts (2 s each).
    expect(lines.map((l) => l.startMs).toList(), [0, 2000, 4000]);
    expect(await env.repo.summary('r'), isNotNull);
  });

  test('resetInterrupted puts running jobs back to pending', () async {
    await makeRecording('r');
    final q = queue((_, _) async {});
    await q.enqueue('r');
    await env.db.db.update('jobs', {'state': 'running'});
    await q.resetInterrupted();
    expect((await q.job('r'))!['state'], 'pending');
    expect(await q.runDue(), 1);
  });
}

/// Fails exactly once, on call number [failOn].
class _FailOnCall extends FakeTranscriber {
  _FailOnCall(this.failOn);
  final int failOn;
  bool _failed = false;

  @override
  Future<List<TranscriptLine>> transcribeFile(String wavPath,
      {required int offsetMs, required int segmentIndex}) async {
    if (!_failed && calls + 1 == failOn) {
      calls++;
      _failed = true;
      throw Exception('decoder crashed');
    }
    return super.transcribeFile(wavPath,
        offsetMs: offsetMs, segmentIndex: segmentIndex);
  }
}
