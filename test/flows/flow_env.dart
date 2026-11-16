// Whole-app harness for the flow tests: the real router, real screens, real
// database, real job queue and real cloud pipeline. Only the edges are fake:
// the microphone, the Supabase server (FakeBackend over a MockClient), the
// native AAC encoder, the network monitor, notifications, the audio player,
// the file picker and things that leave the app (URLs, share sheet).
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:longnote/app/router.dart';
import 'package:longnote/app_services.dart';
import 'package:longnote/core/analytics/analytics.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/cloud/audio_encoder.dart';
import 'package:longnote/core/cloud/cloud_pieces.dart';
import 'package:longnote/core/cloud/cloud_pipeline.dart';
import 'package:longnote/core/cloud/longnote_api.dart';
import 'package:longnote/core/cloud/network_monitor.dart';
import 'package:longnote/core/cloud/supabase_auth.dart';
import 'package:longnote/core/cloud/tus_uploader.dart';
import 'package:longnote/core/audio/wav.dart';
import 'package:longnote/core/config.dart';
import 'package:longnote/core/notes/speakers.dart';
import 'package:longnote/core/summary/summary_models.dart';
import 'package:longnote/core/db/app_database.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/recording/recording_controller.dart';
import 'package:longnote/core/recording/recording_repository.dart';
import 'package:longnote/core/util/clock.dart';
import 'package:longnote/features/common/external.dart';
import 'package:longnote/features/common/screen_clock.dart';
import 'package:longnote/features/import/import_controller.dart';
import 'package:longnote/features/note/note_playback.dart';
import 'package:longnote/features/note/player_sheet.dart';
import 'package:longnote/main.dart';
import 'package:longnote/ui/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_backend.dart';
import '../helpers/screens_harness.dart' show FakeScheduler, FakePicker, FakeProbe;
import '../screens/harness.dart' show FakeEngine, FakePcm, FakeShare;

export '../helpers/fake_backend.dart';
export '../screens/harness.dart' show FakePcm;

/// A completer whose future completes in the real (root) zone: the pipeline
/// runs inside `tester.runAsync`, where futures made in the test's fake-async
/// zone would never fire.
Completer<void> _rootCompleter() => Zone.root.run(Completer<void>.new);

/// Holds HTTP requests that match a key (method like 'PATCH', or the end of
/// the path like 'summarize') until released, so a test can look at the
/// screen while the pipeline is in that step.
class GatedClient extends http.BaseClient {
  GatedClient(this.inner);
  final http.Client inner;
  final _gates = <String, Completer<void>>{};
  final _reached = <String, Completer<void>>{};

  void hold(String key) {
    _gates[key] = _rootCompleter();
    _reached[key] = _rootCompleter();
  }

  Future<void> reached(String key) => _reached[key]!.future;
  void release(String key) => _gates.remove(key)?.complete();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    for (final k in _gates.keys.toList()) {
      if (request.method == k || request.url.path.endsWith('/$k')) {
        final r = _reached[k]!;
        if (!r.isCompleted) r.complete();
        await _gates[k]?.future;
      }
    }
    return inner.send(request);
  }
}

/// The fake encoder, with a gate to hold the "compressing" step.
class GatedEncoder extends FakeAudioEncoder {
  Completer<void>? _gate;
  Completer<void>? _reached;
  void hold() {
    _gate = _rootCompleter();
    _reached = _rootCompleter();
  }

  Future<void> get reached => _reached!.future;
  void release() {
    _gate?.complete();
    _gate = null;
  }

  @override
  Future<EncodedAudio> encodeM4a({
    required List<String> inputs,
    required String output,
    int startMs = 0,
    int? durationMs,
  }) async {
    if (_gate != null) {
      if (!_reached!.isCompleted) _reached!.complete();
      await _gate!.future;
    }
    return super.encodeM4a(
        inputs: inputs, output: output, startMs: startMs, durationMs: durationMs);
  }
}

/// The repository, logging every processing status written (to check the
/// order of the steps).
class LoggingRepo extends RecordingRepository {
  LoggingRepo(super.db, super.storage);
  final statuses = <String, List<ProcessingStatus>>{};

  /// Ids in the order their processing first left "queued" / reached done.
  final started = <String>[];
  final finished = <String>[];

  /// Most jobs ever seen running at the same time.
  int maxRunning = 0;

  @override
  Future<void> setProcessing(String id, ProcessingStatus s,
      {String? error,
      String? progress,
      double? progressValue,
      String? errorCode,
      int? tries}) {
    final l = statuses.putIfAbsent(id, () => []);
    if (l.isEmpty || l.last != s) l.add(s);
    if (s != ProcessingStatus.queued && !started.contains(id)) started.add(id);
    if (s == ProcessingStatus.done && !finished.contains(id)) finished.add(id);
    return _countRunning().then((_) => super.setProcessing(id, s,
        error: error,
        progress: progress,
        progressValue: progressValue,
        errorCode: errorCode,
        tries: tries));
  }

  Future<void> _countRunning() async {
    final n = Sqflite.firstIntValue(await db
            .rawQuery("SELECT COUNT(*) FROM jobs WHERE state = 'running'")) ??
        0;
    if (n > maxRunning) maxRunning = n;
  }
}

class FlowEnv {
  FlowEnv._(this.dir, this.db, this.repo, this.clock, this.billing);

  final Directory dir;
  final AppDatabase db;
  final LoggingRepo repo;
  final FakeClock clock;
  final FakeBillingService billing;
  final server = FakeBackend();
  late GatedClient http = GatedClient(server.client);
  final encoder = GatedEncoder();
  final network = ManualNetworkMonitor();
  final scheduler = FakeScheduler();
  final picker = FakePicker();
  final probe = FakeProbe();
  final engines = <FakeEngine>[];
  final opened = <Uri>[];
  late FakeShare share;
  late AppServices services;
  late GoRouter router;

  static Future<FlowEnv> create({bool firstRun = false, bool trial = true}) async {
    sqfliteFfiInit();
    final dir = Directory.systemTemp.createTempSync('ln_flow_');
    final db = await AppDatabase.open(
        factory: databaseFactoryFfiNoIsolate, path: p.join(dir.path, 'db.sqlite'));
    final recRoot = Directory(p.join(dir.path, 'rec'))..createSync();
    final repo = LoggingRepo(db.db, RecordingStorage(recRoot.path));
    final n = DateTime.now();
    final clock = FakeClock(DateTime(n.year, n.month, n.day, 10, 24));
    final billing = FakeBillingService(kv: KvStore(db.db), clock: clock);
    await billing.init();
    final env = FlowEnv._(dir, db, repo, clock, billing);
    if (!firstRun) {
      final kv = KvStore(db.db);
      await kv.setBool(AppServices.kvOnboardingDone, true);
      await kv.setBool(AppServices.kvFirstPaywallSeen, true);
      if (trial) await billing.purchase(annualPlan);
    }
    env._build();
    screenNow = () => clock.now();
    ImportController.picker = env.picker;
    ImportController.probe = env.probe;
    External.openUrl = (u) async {
      env.opened.add(u);
      return true;
    };
    External.shareText = (t, {subject}) async {};
    PackageInfo.setMockInitialValues(
        appName: 'Longnote',
        packageName: 'com.novaralabs.longnote',
        version: '1.0.0',
        buildNumber: '12',
        buildSignature: '',
        installerStore: null);
    NotePlayback.engineFactory = () {
      final e = FakeEngine();
      env.engines.add(e);
      return e;
    };
    PlayerSheet.peaksLoader = (paths, ms) async => List.filled(58, 0.5);
    return env;
  }

  String get recRoot => p.join(dir.path, 'rec');

  /// Builds every service over the database (first launch, or an app
  /// restart: new objects, same DB and files).
  void _build() {
    final analytics = Analytics(db.db, clock: clock);
    share = FakeShare(repo: repo, analytics: analytics);
    final auth = SupabaseAuth(
        config: testConfig, kv: KvStore(db.db), client: http, clock: clock);
    final api = LongnoteApi(config: testConfig, auth: auth, client: http);
    services = AppServices.forTesting(
      db: db,
      repo: repo,
      analytics: analytics,
      billing: billing,
      share: share,
      network: network,
      scheduler: scheduler,
      recordingsRoot: recRoot,
      clock: clock,
      auth: auth,
      api: api,
      recorder: (s) => RecordingController(
        repo: repo,
        analytics: analytics,
        sourceFactory: FakePcm.new,
        useTimers: false,
        clock: clock,
        onFinished: s.onRecordingFinishedForTesting,
      ),
      cloud: (s, notifier) {
        return CloudPipeline(
          repo: repo,
          settings: s.settings,
          auth: auth,
          api: api,
          tus: TusUploader(
              endpoint: testConfig.tusEndpoint,
              anonKey: testConfig.anonKey,
              client: http,
              chunkSize: 4000),
          encoder: encoder,
          network: network,
          pieces: CloudPieceStore(db.db),
          notifier: notifier,
          clock: clock,
        );
      },
    );
    // "On this phone" mode uses the app's deterministic fake transcriber.
    services.useFakeTranscriber = true;
  }

  /// Kills the app (drops every object, keeps DB + files) and launches it
  /// again on [location].
  Future<void> restart(WidgetTester t, {String location = '/notes'}) async {
    await t.pumpWidget(const SizedBox());
    services.dispose();
    // A dead process: requests held by the old client never finish.
    http = GatedClient(server.client);
    _build();
    await start(t);
    await pumpApp(t, location: location);
  }

  /// What [AppServices.boot] does after building the services.
  Future<void> start(WidgetTester t) => t.runAsync(() async {
        await services.start();
        await services.startupRun;
      });

  Future<void> pumpApp(WidgetTester t, {String location = '/notes'}) async {
    router = buildRouter(initialLocation: location);
    await t.pumpWidget(LongnoteApp(services: services, router: router));
    await settle(t);
  }

  Future<void> dispose() async {
    screenNow = DateTime.now;
    services.dispose();
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  // ---- driving the queue ------------------------------------------------------

  /// Runs every job that is due now (real I/O), then settles the UI.
  Future<void> runQueue(WidgetTester t) async {
    await t.runAsync(() => services.jobs.runDue());
    await settle(t);
  }

  Future<List<Map<String, Object?>>> pendingJobs(WidgetTester t) async =>
      (await t.runAsync(() => db.db.query('jobs',
          where: 'state = ?', whereArgs: ['pending'], orderBy: 'next_attempt_at')))!;

  /// Runs the queue, jumping the clock to each next due time, until no job
  /// is pending (or [rounds] is used up).
  Future<void> drainQueue(WidgetTester t, {int rounds = 30}) async {
    for (var i = 0; i < rounds; i++) {
      await runQueue(t);
      final pending = await pendingJobs(t);
      if (pending.isEmpty) return;
      final at = DateTime.fromMillisecondsSinceEpoch(
          pending.first['next_attempt_at'] as int);
      if (at.isAfter(clock.now())) clock.current = at;
    }
  }

  Future<Recording> note(WidgetTester t, String id) async =>
      (await t.runAsync(() => repo.get(id)))!;

  /// Feeds [seconds] of audio to the live recording and lets it reach disk.
  Future<void> speak(WidgetTester t, int seconds) async {
    FakePcm.last!.audio.add(Uint8List(32000 * seconds));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    services.recorder.tickFlush();
    await t.pump();
  }
}

/// Lets real I/O finish, then settles frames.
Future<void> settle(WidgetTester tester, {int rounds = 3}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));
  }
}

/// Taps, then settles (scrolls the target into view first).
Future<void> tapAndSettle(WidgetTester t, Finder f) async {
  if (f.hitTestable().evaluate().isEmpty) {
    await t.ensureVisible(f);
    await t.pumpAndSettle();
  }
  await t.tap(f);
  await settle(t);
}

/// A tappable by its accessibility label.
Finder byLabel(String label) => find.byWidgetPredicate((w) =>
    (w is LnPressable && w.semanticLabel == label) ||
    (w is LnToggle && w.semanticLabel == label));

void mockPlatform() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
}

// ---- seed data ------------------------------------------------------------------

extension FlowSeed on FlowEnv {
  /// A finished note with real WAV parts on disk ([seconds] of audio each).
  Future<void> addNote(
    String id,
    String title, {
    required DateTime at,
    int parts = 1,
    int seconds = 4,
    ProcessingStatus status = ProcessingStatus.done,
    String? error,
    String? errorCode,
    int tries = 0,
    String? summary,
    List<(String speaker, int startMs, String text)> turns = const [],
  }) async {
    await repo.insert(Recording(
      id: id,
      title: title,
      createdAt: at,
      status: RecordingStatus.completed,
      durationMs: parts * seconds * 1000,
      segmentCount: parts,
      processingStatus: status,
      processingError: error,
      errorCode: errorCode,
      tries: tries,
      language: 'en',
      summaryStyle: 'meeting',
      transcriptSource: turns.isEmpty ? null : 'cloud',
      updatedAt: at,
    ));
    final dir = repo.storage.dirFor(id);
    Directory(dir).createSync(recursive: true);
    for (var i = 0; i < parts; i++) {
      final name = 'seg_${i.toString().padLeft(4, '0')}.wav';
      final bytes = seconds * AppConfig.bytesPerSecond;
      (WavWriter.create(p.join(dir, name))..append(Uint8List(bytes))).close();
      await repo.upsertSegment(AudioSegment(
          recordingId: id, index: i, fileName: name, dataBytes: bytes, closed: true));
    }
    if (turns.isNotEmpty) {
      await repo.saveSegmentTranscript(id, 0, [
        for (final (sp, start, text) in turns)
          TranscriptLine(
              startMs: start,
              endMs: start + 1500,
              text: text,
              speaker: sp,
              language: 'en',
              segmentIndex: 0)
      ]);
      await SpeakerStore(repo).ensure(id, {for (final t in turns) t.$1});
    }
    if (summary != null) {
      await repo.saveSummary(
          id, MeetingSummary(inShort: summary, keyPoints: const ['Point one']).encode(), 'cloud',
          style: 'meeting');
    }
    if (status != ProcessingStatus.done && status != ProcessingStatus.none) {
      await db.db.insert(
          'jobs',
          {
            'recording_id': id,
            'state': status == ProcessingStatus.failed ? 'failed' : 'pending',
            'attempts': tries,
            'next_attempt_at': clock.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
            'updated_at': clock.now().millisecondsSinceEpoch,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// B1-like home: two notes needing attention, one processing, a finished
  /// note with speakers, and [older] finished notes on earlier days.
  Future<void> seedHome({int older = 20}) async {
    final now = clock.now();
    await addNote('q3', 'Q3 budget review with Priya',
        at: now.subtract(const Duration(minutes: 30)),
        summary: 'Priya and Arjun agreed to cut paid ads by 20%.',
        turns: const [
          ('1', 0, 'If the budget stays flat we still hit the number.'),
          ('2', 2000, 'I would move the eighteen thousand now.'),
          ('1', 4000, 'Twenty percent, starting July first.'),
        ]);
    await addNote('weekly', 'Weekly product sync',
        at: now.subtract(const Duration(minutes: 10)),
        status: ProcessingStatus.transcribing);
    await addNote('client', 'Client call — Rivera & Co',
        at: now.subtract(const Duration(hours: 1)),
        status: ProcessingStatus.waitingForNetwork);
    await addNote('lecture', 'Lecture 7 — Organic chemistry',
        at: now.subtract(const Duration(days: 1)),
        status: ProcessingStatus.failed,
        error: 'The connection kept dropping during upload.',
        errorCode: 'network',
        tries: 4);
    for (var i = 0; i < older; i++) {
      await addNote('old$i', 'Older note $i',
          at: now.subtract(Duration(days: 2 + i)), summary: 'Summary of note $i.');
    }
  }
}

/// Answers the one-time "note ready" notification ask, if it is showing.
Future<void> dismissNotificationAsk(WidgetTester t, {bool allow = false}) async {
  await t.pump(const Duration(milliseconds: 500));
  await settle(t);
  final f = find.text(allow ? 'Notify me' : 'Not now');
  if (f.evaluate().isNotEmpty) await tapAndSettle(t, f);
}
