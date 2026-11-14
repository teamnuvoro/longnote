import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'core/analytics/analytics.dart';
import 'core/audio/pcm_source.dart';
import 'core/billing/billing_service.dart';
import 'core/billing/paywall_gate.dart';
import 'core/billing/trial_reminder.dart';
import 'core/db/app_database.dart';
import 'core/export/share_service.dart';
import 'core/jobs/job_queue.dart';
import 'core/jobs/processing_pipeline.dart';
import 'core/models/recording.dart';
import 'core/recording/recording_controller.dart';
import 'core/recording/recording_repository.dart';
import 'core/recording/recovery_service.dart';
import 'core/summary/summary_service.dart';
import 'core/transcription/fake_transcriber.dart';
import 'core/transcription/transcriber.dart';
import 'core/transcription/whisper_transcriber.dart';

/// Everything the app needs, built once at launch. Passed down with provider.
class AppServices {
  AppServices._({
    required this.db,
    required this.kv,
    required this.repo,
    required this.analytics,
    required this.billing,
    required this.gate,
    required this.reminders,
    required this.reminderScheduler,
    required this.summaries,
    required this.share,
  });

  final AppDatabase db;
  final KvStore kv;
  final RecordingRepository repo;
  final Analytics analytics;
  final BillingService billing;
  final PaywallGate gate;
  final TrialReminderService reminders;
  final LocalNotificationScheduler reminderScheduler;
  final SummaryService summaries;
  final ShareService share;
  late final ProcessingJobQueue jobs;
  late final RecordingController recorder;

  /// Current whisper choice; changing it swaps the transcriber.
  final ValueNotifier<WhisperChoice> whisperChoice =
      ValueNotifier(WhisperChoice.baseEn);
  WhisperTranscriber? _whisper;
  bool useFakeTranscriber = false;

  /// Recordings recovered at this launch (shown once on Home).
  List<Recording> recoveredAtLaunch = const [];

  static const kvOnboardingDone = 'onboarding_done';
  static const kvWhisper = 'whisper_model';
  static const kvFakeTranscriber = 'dev_fake_transcriber';

  WhisperTranscriber get whisper {
    final c = whisperChoice.value;
    if (_whisper == null || _whisper!.choice != c) {
      _whisper = WhisperTranscriber(choice: c);
    }
    return _whisper!;
  }

  Transcriber currentTranscriber() =>
      useFakeTranscriber ? FakeTranscriber() : whisper;

  Future<void> setWhisperChoice(WhisperChoice c) async {
    whisperChoice.value = c;
    await kv.set(kvWhisper, c.name);
  }

  static Future<AppServices> boot() async {
    final support = await getApplicationSupportDirectory();
    final dbPath = p.join(support.path, 'longnote.db');
    final recRoot = Directory(p.join(support.path, 'recordings'))
      ..createSync(recursive: true);

    final db = await AppDatabase.open(factory: databaseFactory, path: dbPath);
    final kv = KvStore(db.db);
    final analytics = Analytics(db.db);
    final repo = RecordingRepository(db.db, RecordingStorage(recRoot.path));
    final billing = FakeBillingService(kv: kv);
    await billing.init();
    final scheduler = LocalNotificationScheduler();

    final s = AppServices._(
      db: db,
      kv: kv,
      repo: repo,
      analytics: analytics,
      billing: billing,
      gate: PaywallGate(kv),
      reminders: TrialReminderService(scheduler),
      reminderScheduler: scheduler,
      summaries: SummaryService.standard(kv),
      share: ShareService(repo: repo, analytics: analytics),
    );
    s.whisperChoice.value = WhisperChoice.parse(await kv.get(kvWhisper));
    s.useFakeTranscriber = await kv.getBool(kvFakeTranscriber);

    final pipeline = ProcessingPipeline(
      repo: repo,
      transcriber: s.currentTranscriber,
      summaries: s.summaries,
    );
    s.jobs = ProcessingJobQueue(
      db: db.db,
      repo: repo,
      analytics: analytics,
      processor: pipeline.process,
    );
    s.recorder = RecordingController(
      repo: repo,
      analytics: analytics,
      sourceFactory: RecordPcmSource.new,
      onFinished: s._onRecordingFinished,
    );

    // 1) Recover anything a crash/force-quit left behind, BEFORE new capture.
    final recovered =
        await RecoveryService(repo: repo, analytics: analytics).recoverAll();
    for (final r in recovered) {
      await s._afterRecording(r);
    }
    s.recoveredAtLaunch = recovered;

    // 2) Resume processing that was cut off.
    await s.jobs.resetInterrupted();
    await s.jobs.runDue();
    return s;
  }

  Future<void> _onRecordingFinished(Recording r) async {
    await _afterRecording(r);
    jobs.resume();
  }

  Future<void> _afterRecording(Recording r) async {
    await gate.onRecordingFinished(r.duration,
        wasEntitled: billing.entitlement.value.isActive);
    if (r.durationMs > 0) await jobs.enqueue(r.id);
  }

  /// Gate check + start. Returns false when the paywall must be shown.
  Future<bool> canStartRecording() => gate.canStart(billing.entitlement.value);

  Future<Recording> startRecording() async {
    jobs.pause(); // keep CPU/battery for capture
    try {
      return await recorder.start();
    } catch (_) {
      jobs.resume();
      rethrow;
    }
  }
}
