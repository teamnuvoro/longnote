// Harness for the A/E/F/G screen tests: real database (FFI, no isolate, so
// futures finish inside widget tests), fake billing clock, fake notification
// scheduler, fake Ask server, fake picker/probe, bundled fonts, Figma data.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:longnote/app/router.dart';
import 'package:longnote/app_services.dart';
import 'package:longnote/core/analytics/analytics.dart';
import 'package:longnote/core/billing/billing_service.dart';
import 'package:longnote/core/billing/trial_reminder.dart';
import 'package:longnote/core/cloud/longnote_api.dart';
import 'package:longnote/core/cloud/supabase_auth.dart';
import 'package:longnote/core/db/app_database.dart';
import 'package:longnote/core/models/recording.dart';
import 'package:longnote/core/notes/chat.dart';
import 'package:longnote/core/recording/recording_controller.dart';
import 'package:longnote/core/recording/recording_repository.dart';
import 'package:longnote/core/util/clock.dart';
import 'package:longnote/features/common/external.dart';
import 'package:longnote/features/common/screen_clock.dart';
import 'package:longnote/features/import/import_controller.dart';
import 'package:longnote/ui/theme.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'fake_backend.dart' show testConfig;

/// Figma's "today": Sun, Nov 16 2026, 10:24 AM.
final figmaNow = DateTime(2026, 11, 16, 10, 24);

class FakeScheduler extends LocalNotificationScheduler {
  bool grant = true;
  int permissionAsks = 0;
  final scheduled = <({int id, DateTime at, String body})>[];

  @override
  Future<bool> requestPermission() async {
    permissionAsks++;
    return grant;
  }

  @override
  Future<void> schedule(
      {required int id,
      required DateTime at,
      required String title,
      required String body}) async {
    scheduled.add((id: id, at: at, body: body));
  }

  @override
  Future<void> cancel(int id) async {}

  @override
  Future<void> showNow(
      {required int id,
      required String title,
      required String body,
      String? payload}) async {}
}

class FakeAskApi extends LongnoteApi {
  FakeAskApi(KvStore kv)
      : super(config: testConfig, auth: SupabaseAuth(config: testConfig, kv: kv));

  final questions = <String>[];
  Object? failWith;
  AskReply reply = AskReply(
    answer: 'Subject: Q3 budget — what we agreed\n'
        'Hi Priya, Arjun,\n\nThanks for today.',
    found: true,
    sources: const [
      AskSource(speaker: 'Priya', startMs: 842000),
      AskSource(speaker: 'Arjun', startMs: 859000),
    ],
    truncated: false,
  );

  @override
  Future<AskReply> ask({
    required List<Map<String, Object?>> turns,
    required String question,
    List<Map<String, String>> history = const [],
  }) async {
    questions.add(question);
    final f = failWith;
    if (f != null) throw f;
    return reply;
  }
}

class FakePicker implements MediaPicker {
  PickedMedia? next;
  @override
  Future<PickedMedia?> pickFile() async => next;
  @override
  Future<PickedMedia?> pickVideo() async => next;
}

class FakeProbe implements MediaProbe {
  int? ms = 7540000; // 2:05:40
  @override
  Future<int?> durationMs(String path) async => ms;
}

class ScreensEnv {
  ScreensEnv._(this.dir, this.db, this.services, this.scheduler, this.api,
      this.clock, this.picker, this.probe);

  final Directory dir;
  final AppDatabase db;
  final AppServices services;
  final FakeScheduler scheduler;
  final FakeAskApi api;
  final FakeClock clock;
  final FakePicker picker;
  final FakeProbe probe;
  final opened = <Uri>[];
  final shared = <String>[];
  int reviews = 0;

  RecordingRepository get repo => services.repo;
  FakeBillingService get billing => services.billing as FakeBillingService;

  static Future<ScreensEnv> create({bool withApi = true}) async {
    sqfliteFfiInit();
    final dir = Directory.systemTemp.createTempSync('ln_screens_');
    final db = await AppDatabase.open(
        factory: databaseFactoryFfiNoIsolate, path: p.join(dir.path, 'db.sqlite'));
    final kv = KvStore(db.db);
    final clock = FakeClock(figmaNow);
    final billing = FakeBillingService(kv: kv, clock: clock);
    await billing.init();
    final rec = Directory(p.join(dir.path, 'recordings'))..createSync();
    final repo = RecordingRepository(db.db, RecordingStorage(rec.path));
    final scheduler = FakeScheduler();
    final api = FakeAskApi(kv);
    final services = AppServices.forTesting(
      db: db,
      repo: repo,
      analytics: Analytics(db.db, clock: clock),
      billing: billing,
      scheduler: scheduler,
      recordingsRoot: rec.path,
      api: withApi ? api : null,
    );
    services.recorder = RecordingController(
      repo: repo,
      analytics: services.analytics,
      sourceFactory: () => throw UnsupportedError('no microphone in tests'),
      useTimers: false,
    );
    final env = ScreensEnv._(dir, db, services, scheduler, api, clock,
        FakePicker(), FakeProbe());
    screenNow = () => clock.now();
    ImportController.picker = env.picker;
    ImportController.probe = env.probe;
    External.openUrl = (u) async {
      env.opened.add(u);
      return true;
    };
    External.shareText = (t, {subject}) async => env.shared.add(t);
    External.requestReview = () async {
      env.reviews++;
      return true;
    };
    PackageInfo.setMockInitialValues(
        appName: 'Longnote',
        packageName: 'com.novaralabs.longnote',
        version: '1.0.0',
        buildNumber: '12',
        buildSignature: '',
        installerStore: null);
    return env;
  }

  Future<void> dispose() async {
    screenNow = DateTime.now;
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }

  /// Notes as drawn in the Figma file (E3 list).
  Future<void> seedFigmaNotes() async {
    Recording n(String id, String title, DateTime at, Duration d,
            ProcessingStatus st) =>
        Recording(
            id: id,
            title: title,
            createdAt: at,
            status: RecordingStatus.completed,
            durationMs: d.inMilliseconds,
            processingStatus: st);
    final today = figmaNow;
    await repo.insert(n('lecture', 'Lecture 6 — Organic chemistry',
        DateTime(2026, 11, 10, 9), const Duration(hours: 1, minutes: 52, seconds: 30),
        ProcessingStatus.done));
    await repo.insert(n('sermon', 'Sunday sermon — Grace Church',
        DateTime(2026, 11, 15, 11), const Duration(hours: 2, minutes: 41, seconds: 18),
        ProcessingStatus.done));
    await repo.insert(n('design', 'Design review — onboarding v2',
        DateTime(2026, 11, 15, 16), const Duration(minutes: 36, seconds: 5),
        ProcessingStatus.done));
    await repo.insert(n('weekly', 'Weekly product sync',
        today.subtract(const Duration(minutes: 30)), const Duration(minutes: 48),
        ProcessingStatus.transcribing));
    await repo.insert(n('q3', 'Q3 budget review with Priya',
        today.subtract(const Duration(hours: 2)),
        const Duration(hours: 1, minutes: 12, seconds: 40), ProcessingStatus.done));
    for (final (key, name, color) in [('1', 'Priya', 0), ('2', 'Arjun', 1)]) {
      await db.db.insert('speakers', {
        'recording_id': 'q3',
        'speaker_key': key,
        'display_name': name,
        'color_index': color,
      });
    }
    await db.db.insert('transcript_lines', {
      'recording_id': 'q3',
      'speaker': '1',
      'start_ms': 842000,
      'end_ms': 850000,
      'text': 'Let us cut paid ads by twenty percent.',
      'seg_idx': 0,
    });
  }

  /// The E2 conversation from the Figma frame.
  Future<void> seedFigmaChat() async {
    await services.chat.add(ChatMessage(
        recordingId: 'q3',
        role: ChatRole.user,
        text: 'Draft a follow-up email',
        createdAt: figmaNow));
    await services.chat.add(ChatMessage(
        recordingId: 'q3',
        role: ChatRole.assistant,
        text: 'Subject: Q3 budget — what we agreed\n'
            'Hi Priya, Arjun,\n\n'
            'Thanks for today. We agreed to cut paid ads by 20% from July 1 and move \$18,000 to the referral programme.\n\n'
            'Next steps:\n'
            '• Priya sends the new Q3 forecast to finance by Fri, Nov 21.\n'
            '• Arjun sets up referral tracking in the dashboard.',
        sources: const [
          AskSource(speaker: 'Priya', startMs: 842000),
          AskSource(speaker: 'Arjun', startMs: 859000),
          AskSource(speaker: 'Priya', startMs: 1368000),
        ],
        found: true,
        createdAt: figmaNow.add(const Duration(seconds: 5))));
  }

  /// A file on disk to import.
  PickedMedia makeFile(String name, int bytes) {
    final f = File(p.join(dir.path, 'picked', name))
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(bytes, 7));
    return PickedMedia(path: f.path, name: name, bytes: bytes);
  }

  Widget app(String location, {GoRouter? router}) => MultiProvider(
        providers: [
          Provider<AppServices>.value(value: services),
          ChangeNotifierProvider.value(value: services.repo),
          ChangeNotifierProvider.value(value: services.recorder),
        ],
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: lnLightTheme(),
          routerConfig: router ?? buildRouter(initialLocation: location),
        ),
      );
}

bool _fontsLoaded = false;

/// Loads the bundled fonts so goldens show real text.
Future<void> loadAppFonts() async {
  if (_fontsLoaded) return;
  _fontsLoaded = true;
  for (final (family, file) in [
    ('Newsreader', 'assets/fonts/newsreader/Newsreader-Variable.ttf'),
    ('Geist', 'assets/fonts/geist/Geist-Variable.ttf'),
    ('GeistMono', 'assets/fonts/geist_mono/GeistMono-Variable.ttf'),
  ]) {
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.sublistView(File(file).readAsBytesSync())));
    await loader.load();
  }
}

/// iPhone 15-ish frame: 393 x 852, status bar 54, home indicator 34.
void phoneView(WidgetTester tester, {double dpr = 2}) {
  tester.view.devicePixelRatio = dpr;
  tester.view.physicalSize = Size(393 * dpr, 852 * dpr);
  tester.view.padding = FakeViewPadding(top: 54 * dpr, bottom: 34 * dpr);
  tester.view.viewPadding = FakeViewPadding(top: 54 * dpr, bottom: 34 * dpr);
  addTearDown(tester.view.reset);
}

/// Lets real I/O (SVG assets, file copies) finish, then settles frames.
Future<void> settle(WidgetTester tester, {int rounds = 3}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pumpAndSettle();
  }
}
