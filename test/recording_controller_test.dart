import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/analytics/analytics.dart';
import 'package:longnote/core/audio/pcm_source.dart';
import 'package:longnote/core/audio/wav.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/recording/recording_controller.dart';
import 'package:longnote/core/recording/recovery_service.dart';

import 'helpers/test_env.dart';

class FakePcmSource implements PcmSource {
  FakePcmSource({this.permission = true});
  final bool permission;
  final audio = StreamController<Uint8List>();
  final ints = StreamController<InterruptionPhase>.broadcast();
  final paused = <String>[];
  @override
  Future<bool> hasPermission({bool request = true}) async => permission;
  @override
  Future<Stream<Uint8List>> start() async => audio.stream;
  @override
  Future<void> pause() async => paused.add('pause');
  @override
  Future<void> resume() async => paused.add('resume');
  @override
  Future<void> stop() async => audio.close();
  @override
  Stream<double> levels() => const Stream.empty();
  @override
  Stream<InterruptionPhase> interruptions() => ints.stream;
  @override
  Stream<bool> pausedChanges() => const Stream.empty();
  @override
  void dispose() {}
}

void main() {
  late TestEnv env;
  setUp(() async => env = await TestEnv.create());
  tearDown(() async => env.dispose());

  Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));

  Future<void> waitFor(bool Function() cond) async {
    for (var i = 0; i < 200 && !cond(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(cond(), isTrue, reason: 'condition not reached in time');
  }

  RecordingController make(FakePcmSource src, {List<Recording>? finished}) =>
      RecordingController(
        repo: env.repo,
        analytics: env.analytics,
        sourceFactory: () => src,
        clock: env.clock,
        useTimers: false,
        onFinished: (r) async => finished?.add(r),
      );

  test('records, marks an interruption gap, stops -> completed with audio',
      () async {
    final src = FakePcmSource();
    final finished = <Recording>[];
    final c = make(src, finished: finished);
    final rec = await c.start();
    expect(c.state, CaptureState.recording);
    expect((await env.repo.get(rec.id))!.status, RecordingStatus.recording);

    src.audio.add(pcm(32000)); // 1 s
    await pump();
    env.clock.advance(const Duration(seconds: 1));
    c.tickFlush();
    await c.tickHeartbeat();
    expect((await env.repo.get(rec.id))!.durationMs, 1000);

    // Phone call.
    src.ints.add(InterruptionPhase.began);
    await waitFor(() => c.state == CaptureState.paused);
    expect(c.banner, contains('phone call'));
    env.clock.advance(const Duration(minutes: 2));
    src.ints.add(InterruptionPhase.endedResumable);
    await waitFor(() => c.state == CaptureState.recording);
    expect(c.banner, contains('was not recorded'));

    src.audio.add(pcm(32000, seed: 3)); // 1 more second
    await pump();
    final done = await c.stop();
    expect(done!.status, RecordingStatus.completed);
    expect(done.durationMs, 2000);
    expect(finished.single.id, rec.id);

    final gaps = await env.repo.gaps(rec.id);
    expect(gaps.single.atMs, 1000);
    expect(gaps.single.endedAt!.difference(gaps.single.startedAt),
        const Duration(minutes: 2));

    final seg = (await env.repo.segments(rec.id)).single;
    expect(seg.dataBytes, 64000);
    expect(seg.closed, isTrue);
    final file = File(env.repo.storage.segmentPath(rec.id, seg.fileName));
    expect(readWavSizes(file.readAsBytesSync().sublist(0, 44))!.dataSize, 64000);

    final names = (await env.analytics.recent()).map((e) => e.name).toList();
    expect(names, containsAll([
      AnalyticsEvent.recordingStarted,
      AnalyticsEvent.recordingInterrupted,
      AnalyticsEvent.recordingCompleted,
    ]));
  });

  test('user pause/resume', () async {
    final src = FakePcmSource();
    final c = make(src);
    final rec = await c.start();
    await c.pause();
    expect((await env.repo.get(rec.id))!.status, RecordingStatus.paused);
    await c.resume();
    expect((await env.repo.get(rec.id))!.status, RecordingStatus.recording);
    expect(src.paused, ['pause', 'resume']);
    await c.stop();
  });

  test('no mic permission -> no recording row, state back to idle', () async {
    final c = make(FakePcmSource(permission: false));
    await expectLater(c.start(), throwsStateError);
    expect(c.state, CaptureState.idle);
    expect(await env.repo.count(), 0);
  });

  test('simulated kill mid-recording is recovered on next launch', () async {
    final src = FakePcmSource();
    final c = make(src);
    final rec = await c.start();
    src.audio.add(pcm(48000)); // 1.5 s
    await pump();
    env.clock.advance(const Duration(seconds: 1));
    c.tickFlush();
    src.audio.add(pcm(16000)); // 0.5 s more, not flushed
    await pump();
    // App is killed here: no stop(). Next launch:
    final out = await RecoveryService(repo: env.repo, analytics: env.analytics)
        .recoverAll();
    expect(out.single.id, rec.id);
    final r = (await env.repo.get(rec.id))!;
    expect(r.status, RecordingStatus.interrupted);
    expect(r.durationMs, 2000, reason: 'bytes written before the kill are kept');
  });
}
