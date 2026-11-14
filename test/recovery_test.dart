import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/analytics/analytics.dart';
import 'package:longnote/core/audio/wav.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/recording/recovery_service.dart';
import 'package:path/path.dart' as p;

import 'helpers/test_env.dart';

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  Future<Recording> stuckRecording(String id,
      {RecordingStatus status = RecordingStatus.recording}) async {
    final r = Recording(
      id: id,
      title: 'Board meeting',
      createdAt: env.clock.now(),
      status: status,
      durationMs: 5000, // stale heartbeat value; recovery must not trust it
      heartbeatAt: env.clock.now().subtract(const Duration(seconds: 3)),
    );
    await env.repo.insert(r);
    Directory(env.repo.storage.dirFor(id)).createSync(recursive: true);
    return r;
  }

  test(
      'recording left in "recording" with a partial last segment is recovered '
      'as interrupted with the right duration', () async {
    final r = await stuckRecording('rec1');
    final dir = env.repo.storage.dirFor('rec1');

    // Segment 0: complete 2 s, closed properly, known in DB.
    final s0 = WavWriter.create(p.join(dir, 'seg_0000.wav'))..append(pcm(64000));
    s0.close();
    await env.repo.upsertSegment(AudioSegment(
        recordingId: 'rec1', index: 0, fileName: 'seg_0000.wav',
        dataBytes: 64000, closed: true));

    // Segment 1: 1.5 s written, last header flush said 1 s, app killed.
    // Its DB row was never written (crash right after rotation).
    final s1 = WavWriter.create(p.join(dir, 'seg_0001.wav'))
      ..append(pcm(32000));
    s1.flush(); // header says 32000
    s1.append(pcm(16001)); // more audio + a half sample, never flushed
    // no close(): process died

    // An open interruption gap (a call was in progress).
    await env.repo.addGap(RecordingGap(
        recordingId: 'rec1', atMs: 2500,
        startedAt: env.clock.now().subtract(const Duration(seconds: 10)),
        reason: 'interruption'));

    env.clock.advance(const Duration(minutes: 5)); // next launch
    final out = await RecoveryService(
            repo: env.repo, analytics: env.analytics, clock: env.clock)
        .recoverAll();

    expect(out, hasLength(1));
    final rec = (await env.repo.get(r.id))!;
    expect(rec.status, RecordingStatus.interrupted);
    // 64000 + 48000 bytes = 3.5 s (half sample dropped).
    expect(rec.durationMs, 3500);
    expect(rec.segmentCount, 2);
    expect(rec.note, startsWith('Interrupted - saved'));
    expect(rec.note, isNot(contains('continu'))); // never claims it kept recording

    final segs = await env.repo.segments('rec1');
    expect(segs.map((s) => (s.index, s.dataBytes, s.closed)),
        [(0, 64000, true), (1, 48000, true)]);

    // File header now matches the data; audio bytes intact.
    final bytes = File(p.join(dir, 'seg_0001.wav')).readAsBytesSync();
    expect(readWavSizes(bytes.sublist(0, 44))!.dataSize, 48000);
    expect(bytes.sublist(44, 44 + 32000), pcm(32000));

    // Gap closed at the last heartbeat.
    final gaps = await env.repo.gaps('rec1');
    expect(gaps.single.endedAt, isNotNull);

    final names = (await env.analytics.recent()).map((e) => e.name).toList();
    expect(names, containsAll([
      AnalyticsEvent.recordingInterrupted,
      AnalyticsEvent.recordingRecovered,
    ]));
  });

  test('paused recordings are recovered too; completed ones are left alone',
      () async {
    await stuckRecording('p', status: RecordingStatus.paused);
    (WavWriter.create(p.join(env.repo.storage.dirFor('p'), 'seg_0000.wav'))
          ..append(pcm(32000)))
        .flush();
    final done = Recording(
        id: 'done', title: 'x', createdAt: env.clock.now(),
        status: RecordingStatus.completed, durationMs: 1000);
    await env.repo.insert(done);

    final out = await RecoveryService(repo: env.repo, analytics: env.analytics)
        .recoverAll();
    expect(out.map((r) => r.id), ['p']);
    expect((await env.repo.get('p'))!.durationMs, 1000);
    expect((await env.repo.get('done'))!.status, RecordingStatus.completed);
  });

  test('a crash before any audio was written gives an honest empty note',
      () async {
    await stuckRecording('empty');
    File(p.join(env.repo.storage.dirFor('empty'), 'seg_0000.wav'))
        .writeAsBytesSync([82, 73]); // header half-written
    await RecoveryService(repo: env.repo, analytics: env.analytics)
        .recoverAll();
    final rec = (await env.repo.get('empty'))!;
    expect(rec.status, RecordingStatus.interrupted);
    expect(rec.durationMs, 0);
    expect(rec.note, 'Interrupted - no audio was saved');
  });

  test('a DB row whose file is missing counts as 0 bytes, nothing crashes',
      () async {
    await stuckRecording('gone');
    await env.repo.upsertSegment(AudioSegment(
        recordingId: 'gone', index: 0, fileName: 'seg_0000.wav',
        dataBytes: 999));
    await RecoveryService(repo: env.repo, analytics: env.analytics)
        .recoverAll();
    expect((await env.repo.get('gone'))!.durationMs, 0);
    expect((await env.repo.segments('gone')).single.dataBytes, 0);
  });

  test('interruptedNote wording', () {
    expect(interruptedNote(const Duration(minutes: 42)),
        'Interrupted - saved 42 min');
    expect(interruptedNote(const Duration(minutes: 125)),
        'Interrupted - saved 2 h 5 min');
  });
}
