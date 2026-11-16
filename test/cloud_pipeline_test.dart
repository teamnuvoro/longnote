import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:longnote/core/audio/wav.dart';
import 'package:longnote/core/cloud/cloud_pieces.dart';
import 'package:longnote/core/cloud/cloud_pipeline.dart';
import 'package:longnote/core/cloud/longnote_api.dart';
import 'package:longnote/core/cloud/network_monitor.dart';
import 'package:longnote/core/cloud/supabase_auth.dart';
import 'package:longnote/core/cloud/tus_uploader.dart';
import 'package:longnote/core/config.dart';
import 'package:longnote/core/jobs/job_queue.dart';
import 'package:longnote/core/jobs/note_processor.dart';
import 'package:longnote/core/jobs/processing_pipeline.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/notes/speakers.dart';
import 'package:longnote/core/settings/app_settings.dart';
import 'package:longnote/core/summary/local_extractive_summarizer.dart';
import 'package:longnote/core/summary/summary_models.dart';
import 'package:longnote/core/summary/summary_service.dart';
import 'package:longnote/core/transcription/fake_transcriber.dart';
import 'package:path/path.dart' as p;

import 'helpers/fake_backend.dart';
import 'helpers/fakes.dart';
import 'helpers/test_env.dart';

class _Notifier implements NoteReadyNotifier {
  final ready = <String>[];
  @override
  Future<void> noteReady(Recording note) async => ready.add(note.id);
}

void main() {
  late TestEnv env;
  late FakeBackend server;
  late FakeAudioEncoder encoder;
  late ManualNetworkMonitor network;
  late _Notifier notifier;

  setUp(() async {
    env = await TestEnv.create();
    server = FakeBackend();
    encoder = FakeAudioEncoder();
    network = ManualNetworkMonitor();
    notifier = _Notifier();
  });
  tearDown(() async => env.dispose());

  /// A finished recording with [segments] WAV parts of [msEach] ms.
  Future<List<String>> makeRecording(String id,
      {int segments = 1, int msEach = 4000}) async {
    await env.repo.insert(Recording(
        id: id,
        title: 'Weekly sync',
        createdAt: env.clock.now(),
        status: RecordingStatus.completed,
        durationMs: segments * msEach));
    final dir = env.repo.storage.dirFor(id);
    final paths = <String>[];
    for (var i = 0; i < segments; i++) {
      final name = 'seg_000$i.wav';
      final bytes = msEach * AppConfig.bytesPerSecond ~/ 1000;
      (WavWriter.create(p.join(dir, name))..append(pcm(bytes, seed: i))).close();
      await env.repo.upsertSegment(AudioSegment(
          recordingId: id, index: i, fileName: name, dataBytes: bytes, closed: true));
      paths.add(p.join(dir, name));
    }
    return paths;
  }

  /// Everything a fresh app launch builds (new objects, same DB + files).
  ({ProcessingJobQueue queue, CloudPipeline pipeline, NoteProcessor processor})
      boot({CloudPipelineConfig config = const CloudPipelineConfig(), int chunk = 1000}) {
    final auth = SupabaseAuth(
        config: testConfig, kv: env.kv, client: server.client, clock: env.clock);
    final api = LongnoteApi(config: testConfig, auth: auth, client: server.client);
    final pieces = CloudPieceStore(env.db.db);
    final pipeline = CloudPipeline(
      repo: env.repo,
      settings: AppSettings(env.kv),
      auth: auth,
      api: api,
      tus: TusUploader(
          endpoint: testConfig.tusEndpoint,
          anonKey: testConfig.anonKey,
          client: server.client,
          chunkSize: chunk),
      encoder: encoder,
      network: network,
      pieces: pieces,
      notifier: notifier,
      config: config,
      clock: env.clock,
    );
    final processor = NoteProcessor(
      repo: env.repo,
      settings: AppSettings(env.kv),
      pieces: pieces,
      cloud: pipeline,
      onDevice: ProcessingPipeline(
        repo: env.repo,
        transcriber: () => FakeTranscriber(),
        summaries: SummaryService(
            kv: env.kv,
            apple: UnavailableSummarizer('apple'),
            cloud: UnavailableSummarizer('cloud'),
            local: LocalExtractiveSummarizer()),
      ),
    );
    final queue = ProcessingJobQueue(
      db: env.db.db,
      repo: env.repo,
      analytics: env.analytics,
      processor: processor.process,
      clock: env.clock,
      autoSchedule: false,
    );
    return (queue: queue, pipeline: pipeline, processor: processor);
  }

  Future<Recording> note(String id) async => (await env.repo.get(id))!;

  test('happy path: compress, upload, start, poll, save speakers, ack, summary',
      () async {
    final wavs = await makeRecording('n1');
    final before = File(wavs.first).readAsBytesSync();
    final app = boot();
    await app.queue.enqueue('n1');

    expect(await app.queue.runDue(), 1);
    var r = await note('n1');
    expect(r.processingStatus, ProcessingStatus.transcribing);
    expect(server.tusCreates, 1);
    expect(server.objects.keys.single, 'user-1/n1.m4a');
    expect(server.objects.values.single.length, 8000, reason: '4 s * 2 bytes/ms');
    expect(server.patches, 8, reason: '1000-byte chunks');
    final start = server.calls('transcribe-start').single;
    expect(start['client_note_id'], 'n1');
    expect(start['audio_path'], 'user-1/n1.m4a');
    expect(start['audio_seconds'], 4.0);
    expect(start['language'], 'auto');

    expect(await app.queue.runDue(), 0, reason: 'next poll is 5 s later');
    env.clock.advance(const Duration(seconds: 5));
    expect(await app.queue.runDue(), 1);

    r = await note('n1');
    expect(r.processingStatus, ProcessingStatus.done);
    expect(r.transcriptSource, 'cloud');
    final lines = await env.repo.transcript('n1');
    expect(lines.map((l) => l.speaker), ['1', '2']);
    expect(lines.first.language, 'en');
    final speakers = await SpeakerStore(env.repo).list('n1');
    expect(speakers.map((s) => s.name), ['Speaker 1', 'Speaker 2']);
    expect(speakers.map((s) => s.colorIndex), [0, 1]);
    expect(server.jobs.values.single.acked, isTrue);

    final sum = (await env.repo.summary('n1'))!;
    expect(sum.engine, 'cloud');
    final parsed = MeetingSummary.parse(sum.json);
    expect(parsed.inShort, 'Part 1 in short.');
    expect(parsed.actionItems.single.owner, 'Priya');
    final summarizeBody = server.calls('summarize').single;
    expect(summarizeBody['style'], 'meeting');
    expect(summarizeBody['output_language'], 'same');
    expect(summarizeBody['transcript'], contains('Speaker 2: Priya will send'));

    // Every function call carried the user's token, never the anon key.
    for (final req in server.requests.where((r) => r.url.path.startsWith('/functions'))) {
      expect(req.headers['Authorization'], startsWith('Bearer at-user-1'));
    }
    expect(notifier.ready, ['n1']);
    expect(File(wavs.first).readAsBytesSync(), before, reason: 'audio untouched');
    expect(server.signups, 1);
  });

  test('offline: waits for network without using tries, resumes when online',
      () async {
    await makeRecording('n1');
    final app = boot();
    network.online = false;
    await app.queue.enqueue('n1');
    await app.queue.runDue();
    var r = await note('n1');
    expect(r.processingStatus, ProcessingStatus.waitingForNetwork);
    expect(r.errorCode, 'network');
    expect(r.processingStatus.needsAttention, isTrue);
    expect(r.tries, 0);
    expect(server.requests, isEmpty);

    network.online = true;
    await app.queue.wakeNetworkWaiters();
    expect(await app.queue.runDue(), 1);
    expect((await note('n1')).processingStatus, ProcessingStatus.transcribing);
  });

  test('network drop mid-upload, app restart: resumes from the server offset',
      () async {
    await makeRecording('n1');
    server.dropOnPatch = 4;
    final first = boot();
    await first.queue.enqueue('n1');
    await first.queue.runDue();
    var r = await note('n1');
    expect(r.processingStatus, ProcessingStatus.waitingForNetwork);
    expect(r.tries, 0);
    expect(server.uploads.values.single.bytes.length, 3000);

    // App killed and reopened: new objects, same DB.
    final second = boot();
    await second.queue.resetInterrupted();
    await second.queue.pokeAll();
    expect(await second.queue.runDue(), 1);
    r = await note('n1');
    expect(r.processingStatus, ProcessingStatus.transcribing);
    expect(server.tusCreates, 1, reason: 'same upload URL, resumed');
    expect(server.objects['user-1/n1.m4a']!.length, 8000);
    expect(server.signups, 1, reason: 'session persisted');
    expect(encoder.calls, hasLength(1), reason: 'm4a reused');
  });

  test('server failure then automatic retry with backoff', () async {
    await makeRecording('n1');
    server.startFailures = 1;
    final app = boot();
    await app.queue.enqueue('n1');
    await app.queue.runDue();
    var r = await note('n1');
    expect(r.processingStatus, ProcessingStatus.queued);
    expect(r.errorCode, 'upstream_failed');
    expect(r.tries, 1);
    expect(r.processingError, contains('Try again'));

    env.clock.advance(const Duration(seconds: 10));
    await app.queue.runDue();
    expect((await note('n1')).processingStatus, ProcessingStatus.transcribing);
    expect(server.tusCreates, 1, reason: 'upload not repeated');
    env.clock.advance(const Duration(seconds: 5));
    await app.queue.runDue();
    r = await note('n1');
    expect(r.processingStatus, ProcessingStatus.done);
    expect(r.tries, 0);
  });

  test('limit_reached: shows the reason and retries after the UTC reset',
      () async {
    await makeRecording('n1');
    server.limitScope = 'user_day';
    final app = boot();
    await app.queue.enqueue('n1');
    await app.queue.runDue();
    final r = await note('n1');
    expect(r.processingStatus, ProcessingStatus.failed);
    expect(r.errorCode, 'limit_reached');
    expect(r.processingError, contains('Daily limit'));
    expect(r.tries, 0);

    env.clock.advance(const Duration(hours: 1));
    expect(await app.queue.runDue(), 0, reason: 'waits for the reset');
    await app.queue.pokeAll();
    expect(await app.queue.runDue(), 0, reason: 'app start does not burn the limit');

    server.limitScope = null;
    env.clock.advance(const Duration(days: 1));
    expect(await app.queue.runDue(), 1);
    expect((await note('n1')).processingStatus, ProcessingStatus.transcribing);
  });

  test('over the 5-hour cap: split into pieces, transcribe each, stitch with offsets',
      () async {
    // Scaled down: cap 10 s, pieces of 8 s; 3 parts of 6 s = 18 s.
    await makeRecording('n1', segments: 3, msEach: 6000);
    server.turnsFor = (client) => [
          {'speaker': '1', 'start_ms': 100, 'end_ms': 900, 'text': 'Hello from $client', 'language': 'en'},
        ];
    final app = boot(
        config: const CloudPipelineConfig(maxSingleMs: 10000, pieceMs: 8000));
    await app.queue.enqueue('n1');
    await app.queue.runDue();
    final pieces = await CloudPieceStore(env.db.db).list('n1');
    expect(pieces.map((x) => x.clientId), ['n1_p1', 'n1_p2', 'n1_p3']);
    expect(pieces.map((x) => x.startMs), [0, 8000, 16000]);
    expect(pieces.map((x) => x.durationMs), [8000, 8000, 2000]);
    expect(encoder.calls[1].inputs.map(p.basename), ['seg_0001.wav', 'seg_0002.wav']);
    expect(encoder.calls[1].startMs, 2000);
    expect(encoder.calls[1].durationMs, 8000);
    expect(server.calls('transcribe-start').map((b) => b['audio_seconds']),
        [8.0, 8.0, 2.0]);

    env.clock.advance(const Duration(seconds: 5));
    await app.queue.runDue();
    expect((await note('n1')).processingStatus, ProcessingStatus.done);
    final lines = await env.repo.transcript('n1');
    expect(lines.map((l) => l.startMs), [100, 8100, 16100]);
    expect(lines.map((l) => l.speaker), ['1:1', '2:1', '3:1']);
    final names = await SpeakerStore(env.repo).names('n1');
    expect(names['2:1'], 'Speaker 1 (part 2)');
  });

  test('app restart mid-poll: keeps polling the same job, no re-upload', () async {
    await makeRecording('n1');
    server.pollsUntilDone = 3;
    final first = boot();
    await first.queue.enqueue('n1');
    await first.queue.runDue();
    expect((await note('n1')).processingStatus, ProcessingStatus.transcribing);

    final second = boot();
    await second.queue.resetInterrupted();
    await second.queue.pokeAll();
    expect(await second.queue.runDue(), 1, reason: 'polled at once on start');
    expect((await note('n1')).processingStatus, ProcessingStatus.transcribing);
    env.clock.advance(const Duration(seconds: 5));
    await second.queue.runDue();
    expect((await note('n1')).processingStatus, ProcessingStatus.done);
    expect(server.tusCreates, 1);
    expect(server.starts, 1);
    expect(server.jobs, hasLength(1));
  });

  test('polling slows after a minute and says "still processing" after 2 h',
      () async {
    await makeRecording('n1');
    server.pollsUntilDone = 1000;
    final app = boot();
    await app.queue.enqueue('n1');
    await app.queue.runDue();
    Future<int> waitMs() async => ((await app.queue.job('n1'))!['next_attempt_at'] as int) -
        env.clock.now().millisecondsSinceEpoch;
    expect(await waitMs(), 5000);
    env.clock.advance(const Duration(seconds: 61));
    await app.queue.runDue();
    expect(await waitMs(), 15000);
    env.clock.advance(const Duration(hours: 2));
    await app.queue.runDue();
    expect(await waitMs(), 600000);
    expect((await note('n1')).processingProgress, contains('Still processing'));
  });

  test('transcription failed on the server: uploads again and succeeds', () async {
    await makeRecording('n1');
    server.failOnFirstPoll.add('n1');
    final app = boot();
    await app.queue.enqueue('n1');
    await app.queue.runDue();
    var r = await note('n1');
    expect(r.processingStatus, ProcessingStatus.queued);
    expect(r.tries, 1);
    env.clock.advance(const Duration(seconds: 10));
    await app.queue.runDue();
    expect(server.tusCreates, 2, reason: 'the server deleted the audio');
    env.clock.advance(const Duration(seconds: 5));
    await app.queue.runDue();
    expect((await note('n1')).processingStatus, ProcessingStatus.done);
  });

  test('after all tries: failed; "Transcribe on this phone instead" uses whisper',
      () async {
    await makeRecording('n1');
    encoder.fail = true;
    final app = boot();
    await app.queue.enqueue('n1');
    for (var i = 0; i < AppConfig.maxAutoAttempts; i++) {
      await app.queue.runDue();
      env.clock.advance(const Duration(minutes: 11));
    }
    final failed = await note('n1');
    expect(failed.processingStatus, ProcessingStatus.failed);
    expect(failed.errorCode, 'encode_failed');
    expect(failed.tries, AppConfig.maxAutoAttempts);

    await app.processor.transcribeOnPhoneInstead('n1', app.queue);
    await app.queue.runDue();
    final r = await note('n1');
    expect(r.processingStatus, ProcessingStatus.done);
    expect(r.transcriptionMode, TranscriptionMode.onDevice);
    expect(r.transcriptSource, 'on_device');
    final lines = await env.repo.transcript('n1');
    expect(lines, isNotEmpty);
    expect(lines.every((l) => l.speaker == null), isTrue);
  });

  test('bad request is not retried', () async {
    await makeRecording('n1');
    server.startFailures = 1;
    server.startFailureCode = 'bad_request';
    final app = boot();
    await app.queue.enqueue('n1');
    await app.queue.runDue();
    final r = await note('n1');
    expect(r.processingStatus, ProcessingStatus.failed);
    expect(r.errorCode, 'bad_request');
  });
}
