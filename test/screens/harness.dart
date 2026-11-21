import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:longnote/app/router.dart';
import 'package:longnote/app_services.dart';
import 'package:longnote/core/analytics/analytics.dart';
import 'package:longnote/core/audio/pcm_source.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/cloud/audio_encoder.dart';
import 'package:longnote/core/cloud/network_monitor.dart';
import 'package:longnote/core/db/app_database.dart';
import 'package:longnote/core/export/share_service.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/notes/moments.dart';
import 'package:longnote/core/notes/speakers.dart';
import 'package:longnote/core/recording/recording_controller.dart';
import 'package:longnote/core/recording/recording_repository.dart';
import 'package:longnote/core/summary/summary_models.dart';
import 'package:longnote/features/note/note_playback.dart';
import 'package:longnote/features/note/player_sheet.dart';
import 'package:longnote/main.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Loads the bundled fonts so goldens show the real Newsreader / Geist /
/// Geist Mono instead of the test font.
Future<void> loadAppFonts() async {
  const fonts = {
    'Newsreader': 'assets/fonts/newsreader/Newsreader-Variable.ttf',
    'Geist': 'assets/fonts/geist/Geist-Variable.ttf',
    'GeistMono': 'assets/fonts/geist_mono/GeistMono-Variable.ttf',
  };
  for (final e in fonts.entries) {
    final bytes = File(e.value).readAsBytesSync();
    final loader = FontLoader(e.key)
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }
}

/// Sets a 393 x 852 iPhone-sized view with the status bar / home indicator
/// insets of the Figma frames.
void phoneView(WidgetTester tester) {
  tester.view.physicalSize = const Size(393 * 3, 852 * 3);
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 54 * 3, bottom: 34 * 3);
  tester.view.viewPadding = const FakeViewPadding(top: 54 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
}

class FakeEngine implements AudioEngine {
  final _changes = StreamController<void>.broadcast();
  int _part = 0;
  Duration _pos = Duration.zero;
  bool _playing = false;
  double speed = 1;
  final calls = <String>[];

  @override
  Future<void> load(List<String> paths) async => calls.add('load');
  @override
  Future<void> play() async {
    _playing = true;
    calls.add('play');
    _changes.add(null);
  }

  @override
  Future<void> pause() async {
    _playing = false;
    calls.add('pause');
    _changes.add(null);
  }

  @override
  Future<void> seek(int partIndex, Duration position) async {
    _part = partIndex;
    _pos = position;
    calls.add('seek $partIndex ${position.inMilliseconds}');
    _changes.add(null);
  }

  @override
  Future<void> setSpeed(double s) async => speed = s;
  @override
  Stream<void> get changes => _changes.stream;
  @override
  int get partIndex => _part;
  @override
  Duration get position => _pos;
  @override
  bool get playing => _playing;
  @override
  bool get completed => false;
  @override
  void dispose() => _changes.close();
}

class FakeNetwork implements NetworkMonitor {
  @override
  Future<bool> isOnline() async => true;
  @override
  Stream<bool> get changes => const Stream.empty();
}

class TestBilling implements BillingService {
  TestBilling(Entitlement e) : _e = ValueNotifier(e);
  final ValueNotifier<Entitlement> _e;
  @override
  ValueListenable<Entitlement> get entitlement => _e;
  @override
  Future<void> init() async {}
  @override
  Future<List<Plan>> loadPlans() async => const [];
  @override
  Future<PurchaseResult> purchase(Plan plan) async =>
      PurchaseResult(success: false);
  @override
  Future<RestoreResult> restore() async => RestoreResult.none;
  @override
  Future<void> refresh() async {}
  @override
  bool get trialEligible => false;
}

/// Records share calls instead of opening the iOS share sheet.
class FakeShare extends ShareService {
  FakeShare({required super.repo, required super.analytics})
      : super(encoder: const _NoEncoder());
  final calls = <String>[];
  @override
  Future<void> copyText(String text, String kind, String recordingId) async =>
      calls.add('copy:$kind');
  @override
  Future<void> shareText(String text, String kind, Recording r, {Rect? origin}) async =>
      calls.add('text:$kind:$text');
  @override
  Future<void> sharePdf(Recording r,
          {MeetingSummary? summary,
          String? note,
          Rect? origin,
          Map<String, String>? speakerNames}) async =>
      calls.add('pdf:${speakerNames == null ? 'no-names' : 'names'}');
  @override
  Future<void> shareAudio(Recording r, {Rect? origin}) async => calls.add('wav');
  @override
  Future<void> shareAudioM4a(Recording r, {Rect? origin}) async => calls.add('m4a');
}

class _NoEncoder implements AudioEncoder {
  const _NoEncoder();
  @override
  Future<EncodedAudio> encodeM4a(
          {required List<String> inputs,
          required String output,
          int startMs = 0,
          int? durationMs}) =>
      throw UnimplementedError();
}

class FakePcm implements PcmSource {
  FakePcm() {
    last = this;
  }

  /// The source of the current test recording (to feed it audio).
  static FakePcm? last;

  /// When set, start() waits on it (a stuck microphone / audio session).
  static Completer<void>? startGate;
  final audio = StreamController<Uint8List>();
  final ints = StreamController<InterruptionPhase>.broadcast();
  final lvl = StreamController<double>.broadcast();
  double _level = -40;

  /// One meter tick (a changed value, so listeners hear it).
  void tickLevel() => lvl.add(_level = _level == -40 ? -39 : -40);
  @override
  Future<bool> hasPermission({bool request = true}) async => true;
  @override
  Future<Stream<Uint8List>> start() async {
    final gate = startGate;
    if (gate != null) await gate.future;
    return audio.stream;
  }
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async => audio.close();
  @override
  Stream<double> levels() => lvl.stream;
  @override
  Stream<InterruptionPhase> interruptions() => ints.stream;
  @override
  Stream<bool> pausedChanges() => const Stream.empty();
  @override
  void dispose() {}
}

/// A recorder whose clock/elapsed can be set (goldens show 00:42:17
/// without 42 minutes of audio). Real capture logic is untouched.
class GoldenRecorder extends RecordingController {
  GoldenRecorder({required super.repo, required super.analytics})
      : super(sourceFactory: FakePcm.new, useTimers: false);
  Duration? fixedElapsed;
  @override
  Duration get elapsed => fixedElapsed ?? super.elapsed;
}

class Harness {
  Harness._(this.dir, this.db, this.repo, this.services, this.share);
  final Directory dir;
  final AppDatabase db;
  final RecordingRepository repo;
  final AppServices services;
  final FakeShare share;
  final engines = <FakeEngine>[];

  static Future<Harness> create({
    Entitlement? entitlement,
    RecordingController Function(AppServices s, RecordingRepository repo,
            Analytics analytics)?
        recorder,
  }) async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('longnote_screens_');
    final db = await AppDatabase.open(
        factory: databaseFactoryFfiNoIsolate, path: p.join(dir.path, 'db.sqlite'));
    final recRoot = Directory(p.join(dir.path, 'rec'))..createSync();
    final repo = RecordingRepository(db.db, RecordingStorage(recRoot.path));
    final analytics = Analytics(db.db);
    final share = FakeShare(repo: repo, analytics: analytics);
    final services = AppServices.forTesting(
      db: db,
      repo: repo,
      analytics: analytics,
      billing: TestBilling(entitlement ?? const Entitlement()),
      share: share,
      network: FakeNetwork(),
      recordingsRoot: recRoot.path,
      processor: (id, progress) async {},
      recorder: (s) =>
          recorder?.call(s, repo, analytics) ??
          RecordingController(
            repo: repo,
            analytics: analytics,
            sourceFactory: FakePcm.new,
            useTimers: false,
            onFinished: s.onRecordingFinishedForTesting,
          ),
    );
    await services.kv.setBool(AppServices.kvOnboardingDone, true);
    await services.kv.setBool(AppServices.kvFirstPaywallSeen, true);
    final h = Harness._(dir, db, repo, services, share);
    NotePlayback.engineFactory = () {
      final e = FakeEngine();
      h.engines.add(e);
      return e;
    };
    PlayerSheet.peaksLoader = (paths, ms) async => [
          for (var i = 0; i < 58; i++)
            0.15 + 0.85 * ((i * 37 % 23) / 23) * (0.6 + 0.4 * ((i % 5) / 5))
        ];
    return h;
  }

  late GoRouter router;

  Widget app({String location = '/notes'}) {
    router = buildRouter(initialLocation: location);
    return LongnoteApp(services: services, router: router);
  }

  Future<void> dispose() async {
    services.jobs.dispose();
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}

// ---- Figma content -----------------------------------------------------------

DateTime todayAt(int h, int m) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day, h, m);
}

DateTime yesterdayAt(int h, int m) =>
    todayAt(h, m).subtract(const Duration(days: 1));

int ms(int h, int m, int s) => ((h * 60 + m) * 60 + s) * 1000;

/// Inserts a note with [parts] segments that add up to [durationMs].
Future<Recording> addNote(
  Harness h, {
  required String id,
  required String title,
  required DateTime at,
  required int durationMs,
  int parts = 1,
  ProcessingStatus status = ProcessingStatus.done,
  double? progress,
  String? error,
  String? errorCode,
  int tries = 0,
  String language = 'en',
}) async {
  final r = Recording(
    id: id,
    title: title,
    createdAt: at,
    status: RecordingStatus.completed,
    durationMs: durationMs,
    segmentCount: parts,
    processingStatus: status,
    progress: progress,
    processingError: error,
    errorCode: errorCode,
    tries: tries,
    language: language,
    summaryStyle: 'meeting',
    transcriptSource: 'cloud',
    updatedAt: at,
  );
  await h.repo.insert(r);
  final per = durationMs ~/ parts;
  for (var i = 0; i < parts; i++) {
    final len = i == parts - 1 ? durationMs - per * (parts - 1) : per;
    await h.repo.upsertSegment(AudioSegment(
        recordingId: id,
        index: i,
        fileName: 'seg_${i.toString().padLeft(4, '0')}.wav',
        dataBytes: len * 32,
        closed: true));
  }
  return r;
}

Future<void> addSummary(Harness h, String id, MeetingSummary s) =>
    h.repo.saveSummary(id, s.encode(), 'cloud', style: 'meeting');

const q3 = 'q3';
const weekly = 'weekly';
const design = 'design';
const sermon = 'sermon';
const client = 'client';
const lecture = 'lecture';

/// The notes drawn in B1 / D1-D8.
Future<void> seedFigma(Harness h) async {
  await addNote(h,
      id: weekly,
      title: 'Weekly product sync',
      at: todayAt(11, 30),
      durationMs: ms(0, 48, 10),
      parts: 10,
      status: ProcessingStatus.transcribing,
      progress: 0.64);
  await addNote(h,
      id: q3,
      title: 'Q3 budget review with Priya',
      at: todayAt(10, 24),
      durationMs: ms(1, 12, 40),
      parts: 15);
  await addNote(h,
      id: client,
      title: 'Client call — Rivera & Co',
      at: todayAt(9, 5),
      durationMs: ms(0, 22, 4),
      status: ProcessingStatus.waitingForNetwork);
  await addNote(h,
      id: design,
      title: 'Design review — onboarding v2',
      at: yesterdayAt(16, 0),
      durationMs: ms(0, 36, 5));
  await addNote(h,
      id: lecture,
      title: 'Lecture 7 — Organic chemistry',
      at: yesterdayAt(14, 0),
      durationMs: ms(1, 48, 12),
      parts: 22,
      status: ProcessingStatus.failed,
      error: 'The connection kept dropping during upload.',
      errorCode: 'network',
      tries: 4);
  await addNote(h,
      id: sermon,
      title: 'Sunday sermon — Grace Church',
      at: yesterdayAt(9, 0),
      durationMs: ms(2, 41, 18),
      parts: 33);

  await addSummary(
      h,
      q3,
      const MeetingSummary(
        inShort:
            'Priya and Arjun agreed to cut paid ads by 20% in Q3 and move the money to the referral programme. The forecast is still on track for October if referrals convert at 4%.',
        decisions: [
          'Cut paid ads by 20% from July 1.',
          'Move \$18,000 to the referral programme.',
        ],
        actionItems: [
          ActionItem(
              task: 'Send the new Q3 forecast to finance',
              owner: 'Priya',
              due: 'Fri, Nov 21'),
          ActionItem(task: 'Set up referral tracking in the dashboard', owner: 'Arjun'),
        ],
      ));
  await addSummary(
      h,
      design,
      const MeetingSummary(
          inShort:
              'Three changes approved; the paywall copy goes back to legal before launch.'));
  await addSummary(
      h,
      sermon,
      const MeetingSummary(
          inShort:
              'On patience: three stories, and the question to take into the week.'));

  // Q3 transcript with three voices and a call gap.
  final lines = [
    TranscriptLine(
        startMs: ms(0, 14, 2),
        endMs: ms(0, 14, 18),
        speaker: '1',
        language: 'en',
        text:
            'If the budget stays flat we still hit the number in October. But only if referrals hold at four percent.'),
    TranscriptLine(
        startMs: ms(0, 14, 19),
        endMs: ms(0, 14, 40),
        speaker: '2',
        language: 'en',
        text:
            'They’re at four point two this month. I’d move the eighteen thousand now rather than wait for August.'),
    TranscriptLine(
        startMs: ms(0, 16, 40),
        endMs: ms(0, 16, 50),
        speaker: '3',
        language: 'en',
        text: 'Sorry, I’m back. Did we agree on the ads number?'),
    TranscriptLine(
        startMs: ms(0, 17, 2),
        endMs: ms(0, 17, 20),
        speaker: '1',
        language: 'en',
        text: 'Twenty percent, starting July first. Arjun owns the tracking.'),
  ];
  await h.repo.saveSegmentTranscript(q3, 0, lines);
  final speakers = SpeakerStore(h.repo);
  await speakers.ensure(q3, ['1', '2', '3']);
  await speakers.rename(q3, '1', 'Priya');
  await speakers.rename(q3, '2', 'Arjun');
  final gap = await h.repo.addGap(RecordingGap(
      recordingId: q3,
      atMs: ms(0, 14, 41),
      startedAt: todayAt(10, 38),
      reason: 'interruption'));
  await h.repo.endGap(gap, todayAt(10, 40));
  final moments = MomentStore(h.repo);
  await moments.add(q3, ms(0, 22, 48), label: 'Budget number agreed');
  await moments.add(q3, ms(0, 41, 5), label: 'Referral targets');
}

/// Pumps a few frames (sheets/routes animate in ≤ 300 ms).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  await tester.pumpAndSettle();
}

/// Shorthand for platform clipboard in tests.
void mockClipboard() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
}
