import 'dart:io';

import 'package:path/path.dart' as p;

import '../analytics/analytics.dart';
import '../audio/segment_writer.dart';
import '../audio/wav.dart';
import '../config.dart';
import '../models/recording.dart';
import '../util/clock.dart';
import 'recording_repository.dart';

/// Honest note for a recovered recording. We never claim recording continued
/// after the app was closed: iOS stops it.
String interruptedNote(Duration saved) => saved.inMilliseconds == 0
    ? 'Interrupted - no audio was saved'
    : 'Interrupted - saved ${formatMinutes(saved)}';

/// Runs once at launch, before any new recording can start. Finds recordings
/// that were still "recording"/"paused" (the app was killed, crashed, or the
/// phone restarted), repairs their WAV files and marks them interrupted.
class RecoveryService {
  RecoveryService({
    required this.repo,
    required this.analytics,
    Clock clock = const SystemClock(),
  }) : _clock = clock;

  final RecordingRepository repo;
  final Analytics analytics;
  final Clock _clock;

  Future<List<Recording>> recoverAll() async {
    final stuck = await repo.withStatus(
        [RecordingStatus.recording, RecordingStatus.paused]);
    final out = <Recording>[];
    for (final r in stuck) {
      out.add(await recoverOne(r));
    }
    return out;
  }

  Future<Recording> recoverOne(Recording r) async {
    final dir = Directory(repo.storage.dirFor(r.id));
    final known = {for (final s in await repo.segments(r.id)) s.index: s};

    // Files on disk are the source of truth: a rotation may have created a
    // new file just before the crash, before its DB row was written.
    final onDisk = <int, String>{};
    if (dir.existsSync()) {
      for (final f in dir.listSync().whereType<File>()) {
        final idx = segmentIndexFromName(p.basename(f.path));
        if (idx != null) onDisk[idx] = p.basename(f.path);
      }
    }

    var totalBytes = 0;
    var repairedFiles = 0;
    final indices = {...known.keys, ...onDisk.keys}.toList()..sort();
    for (final idx in indices) {
      final name = onDisk[idx];
      if (name == null) {
        // Row without file: nothing to recover for this part.
        final s = known[idx]!
          ..dataBytes = 0
          ..closed = true;
        await repo.upsertSegment(s);
        continue;
      }
      final res = repairWav(p.join(dir.path, name));
      if (res.repaired) repairedFiles++;
      totalBytes += res.dataBytes;
      await repo.upsertSegment(AudioSegment(
        recordingId: r.id,
        index: idx,
        fileName: name,
        dataBytes: res.dataBytes,
        closed: true,
        transcribed: known[idx]?.transcribed ?? false,
      ));
    }

    final saved =
        Duration(milliseconds: totalBytes * 1000 ~/ AppConfig.bytesPerSecond);
    // Close any gap left open by a call that was in progress.
    final endAt = r.heartbeatAt ?? _clock.now();
    await repo.closeOpenGaps(r.id, endAt);

    r
      ..status = RecordingStatus.interrupted
      ..durationMs = saved.inMilliseconds
      ..segmentCount = indices.length
      ..note = interruptedNote(saved);
    await repo.update(r);

    final props = {
      'saved_ms': saved.inMilliseconds,
      'segments': indices.length,
      'repaired_files': repairedFiles,
      'last_heartbeat_age_s': r.heartbeatAt == null
          ? null
          : _clock.now().difference(r.heartbeatAt!).inSeconds,
    };
    await analytics.log(AnalyticsEvent.recordingInterrupted,
        recordingId: r.id, props: {'cause': 'app_closed', ...props});
    await analytics.log(AnalyticsEvent.recordingRecovered,
        recordingId: r.id, props: props);
    return r;
  }
}
