import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'core/analytics/analytics.dart';
import 'core/audio/pcm_source.dart';
import 'core/billing/billing_service.dart';
import 'core/billing/paywall_gate.dart';
import 'core/billing/trial_reminder.dart';
import 'core/cloud/audio_encoder.dart';
import 'core/cloud/backend_config.dart';
import 'core/cloud/cloud_pieces.dart';
import 'core/cloud/cloud_pipeline.dart';
import 'core/cloud/longnote_api.dart';
import 'core/cloud/network_monitor.dart';
import 'core/cloud/supabase_auth.dart';
import 'core/cloud/tus_uploader.dart';
import 'core/db/app_database.dart';
import 'core/export/share_service.dart';
import 'core/jobs/job_queue.dart';
import 'core/jobs/note_processor.dart';
import 'core/jobs/processing_pipeline.dart';
import 'core/models/recording.dart';
import 'core/notes/ask_service.dart';
import 'core/notes/chat.dart';
import 'core/notes/moments.dart';
import 'core/notes/search.dart';
import 'core/notes/speakers.dart';
import 'core/recording/recording_controller.dart';
import 'core/recording/recording_repository.dart';
import 'core/recording/recovery_service.dart';
import 'core/settings/app_settings.dart';
import 'core/summary/summary_service.dart';
import 'core/util/backup_exclusion.dart';
import 'core/util/clock.dart';
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
    required this.settings,
    required this.network,
    required this.recordingsRoot,
    this.auth,
    this.api,
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
  final AppSettings settings;
  final NetworkMonitor network;
  final String recordingsRoot;

  /// Null when the backend is not configured in this build.
  final SupabaseAuth? auth;
  final LongnoteApi? api;

  late final ProcessingJobQueue jobs;
  late final RecordingController recorder;
  late final NoteProcessor processor;
  CloudPipeline? cloud;
  late final SpeakerStore speakers = SpeakerStore(repo);
  late final MomentStore moments = MomentStore(repo);
  late final ChatStore chat = ChatStore(repo);
  late final NoteSearch search = NoteSearch(repo, ftsEnabled: db.ftsEnabled);
  AskService? get ask => api == null ? null : AskService(repo: repo, api: api!);

  /// True while the app is on screen (no "note ready" notification then).
  bool get inForeground => _lifecycle == AppLifecycleState.resumed;
  AppLifecycleState? _lifecycle = AppLifecycleState.resumed;
  StreamSubscription<bool>? _netSub;
  AppLifecycleListener? _lifecycleListener;

  /// Current whisper choice; changing it swaps the transcriber.
  final ValueNotifier<WhisperChoice> whisperChoice =
      ValueNotifier(WhisperChoice.baseEn);
  WhisperTranscriber? _whisper;
  bool useFakeTranscriber = false;

  /// Recordings recovered at this launch (shown once on Home).
  List<Recording> recoveredAtLaunch = const [];

  static const kvOnboardingDone = 'onboarding_done';

  /// The paywall is shown once after onboarding (onboarding -> paywall -> app).
  static const kvFirstPaywallSeen = 'first_paywall_seen';
  static const kvWhisper = 'whisper_model';
  static const kvFakeTranscriber = 'dev_fake_transcriber';

  /// Set once the notification permission was asked (A2 trial reminder or
  /// the "note ready" ask), so it is never asked twice.
  static const kvNotificationsAsked = 'notifications_asked';

  /// True when the user's first note has just started processing and the
  /// notification permission was never asked: the note screen (or Import)
  /// asks once, with a plain sentence ([answerNoteReadyAsk]).
  final ValueNotifier<bool> noteReadyAskDue = ValueNotifier(false);

  /// A note the user made (recording stopped / file imported) was queued.
  Future<void> noteQueuedByUser() async {
    if (await kv.getBool(kvNotificationsAsked)) return;
    noteReadyAskDue.value = true;
  }

  /// The answer to the "note ready" ask. [allow] = show iOS's permission
  /// prompt. Returns whether notifications are allowed.
  Future<bool> answerNoteReadyAsk({required bool allow}) async {
    noteReadyAskDue.value = false;
    await kv.setBool(kvNotificationsAsked, true);
    if (!allow) return false;
    try {
      return await reminderScheduler.requestPermission();
    } catch (_) {
      return false;
    }
  }

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

  /// Widget tests: services over an already-open database, with fakes for
  /// the platform parts. Not used by the app.
  @visibleForTesting
  static AppServices forTesting({
    required AppDatabase db,
    required RecordingRepository repo,
    required Analytics analytics,
    required BillingService billing,
    required String recordingsRoot,
    ShareService? share,
    NetworkMonitor? network,
    RecordingController Function(AppServices s)? recorder,
    LocalNotificationScheduler? scheduler,
    JobProcessor? processor,
    SupabaseAuth? auth,
    LongnoteApi? api,
    CloudPipeline Function(AppServices s, NoteReadyNotifier notifier)? cloud,
    Clock clock = const SystemClock(),
  }) {
    final kv = KvStore(db.db);
    final settings = AppSettings(kv);
    final sched = scheduler ?? LocalNotificationScheduler();
    final s = AppServices._(
      db: db,
      kv: kv,
      repo: repo,
      analytics: analytics,
      billing: billing,
      gate: PaywallGate(kv),
      reminders: TrialReminderService(sched, kv: kv, clock: clock),
      reminderScheduler: sched,
      summaries: SummaryService.standard(kv, api: api),
      share: share ?? ShareService(repo: repo, analytics: analytics),
      settings: settings,
      network: network ?? ManualNetworkMonitor(),
      recordingsRoot: recordingsRoot,
      auth: auth,
      api: api,
    );
    s.cloud = cloud?.call(
        s, _LocalNoteReadyNotifier(sched, () => s.inForeground));
    s.processor = NoteProcessor(
      repo: repo,
      settings: settings,
      pieces: CloudPieceStore(db.db),
      cloud: s.cloud,
      onDevice: ProcessingPipeline(
          repo: repo, transcriber: s.currentTranscriber, summaries: s.summaries),
    );
    s.jobs = ProcessingJobQueue(
      db: db.db,
      repo: repo,
      analytics: analytics,
      processor: processor ?? s.processor.process,
      clock: clock,
      autoSchedule: false,
    );
    if (recorder != null) s.recorder = recorder(s);
    return s;
  }

  /// For [forTesting] recorders: what the app does after a recording stops.
  @visibleForTesting
  Future<void> onRecordingFinishedForTesting(Recording r) =>
      _onRecordingFinished(r);

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
    final settings = AppSettings(kv);
    final network = ConnectivityPlusMonitor();
    const backend = BackendConfig.current;
    final auth =
        backend.isConfigured ? SupabaseAuth(config: backend, kv: kv) : null;
    final api = auth == null ? null : LongnoteApi(config: backend, auth: auth);

    final s = AppServices._(
      db: db,
      kv: kv,
      repo: repo,
      analytics: analytics,
      billing: billing,
      gate: PaywallGate(kv),
      reminders: TrialReminderService(scheduler, kv: kv),
      reminderScheduler: scheduler,
      summaries: SummaryService.standard(kv, api: api),
      share: ShareService(repo: repo, analytics: analytics),
      settings: settings,
      network: network,
      recordingsRoot: recRoot.path,
      auth: auth,
      api: api,
    );
    s.whisperChoice.value = WhisperChoice.parse(await kv.get(kvWhisper));
    s.useFakeTranscriber = await kv.getBool(kvFakeTranscriber);

    final pieces = CloudPieceStore(db.db);
    if (auth != null && api != null) {
      s.cloud = CloudPipeline(
        repo: repo,
        settings: settings,
        auth: auth,
        api: api,
        tus: TusUploader(endpoint: backend.tusEndpoint, anonKey: backend.anonKey),
        encoder: const NativeAudioEncoder(),
        network: network,
        pieces: pieces,
        notifier: _LocalNoteReadyNotifier(scheduler, () => s.inForeground),
      );
    }
    s.processor = NoteProcessor(
      repo: repo,
      settings: settings,
      pieces: pieces,
      cloud: s.cloud,
      onDevice: ProcessingPipeline(
        repo: repo,
        transcriber: s.currentTranscriber,
        summaries: s.summaries,
      ),
    );
    s.jobs = ProcessingJobQueue(
      db: db.db,
      repo: repo,
      analytics: analytics,
      processor: s.processor.process,
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

    // 2) + 3) Resume processing, wire network/foreground wake-ups.
    await s.start();

    // 4) iCloud backup choice for the recordings folder.
    if (await settings.excludeFromBackup()) {
      unawaited(const BackupExclusion().setExcluded(recRoot.path, true));
    }
    return s;
  }

  /// The queue run started by [start] (tests wait for it).
  @visibleForTesting
  Future<int>? startupRun;

  /// Resume processing that was cut off (app killed mid-job), check server
  /// jobs at once, and wire the wake-ups: network back -> resume uploads;
  /// app back on screen -> check jobs. Called once per launch ([boot]; tests
  /// call it on services rebuilt over the same database = an app restart).
  Future<void> start() async {
    await jobs.resetInterrupted();
    await jobs.pokeAll();
    startupRun = jobs.runDue();
    unawaited(startupRun);
    _netSub ??= network.changes.listen((online) {
      if (online) jobs.wakeNetworkWaiters();
    });
    _lifecycleListener ??= AppLifecycleListener(onStateChange: (st) {
      _lifecycle = st;
      if (st == AppLifecycleState.resumed) jobs.pokeAll();
    });
  }

  /// Settings > "Keep recordings out of iCloud backup".
  Future<void> setExcludeFromBackup(bool v) async {
    await settings.setExcludeFromBackup(v);
    await const BackupExclusion().setExcluded(recordingsRoot, v);
  }

  /// D6 style change / "Make a summary": redo only the summary, through the
  /// queue (so a crash mid-way is resumed at the next launch, never left on
  /// "Writing summary"). The note is pinned to the engine that made its
  /// transcript, so a Settings change never re-uploads a phone-only note or
  /// replaces a cloud transcript. Returns false while the note is still
  /// being processed (the summary would be made from a partial transcript).
  Future<bool> redoSummary(String id) async {
    final n = await repo.get(id);
    if (n == null || n.processingStatus.inProgress) return false;
    final src = n.transcriptSource;
    if (src == 'cloud' || n.source == 'imported') {
      await repo.setNoteOptions(id, transcriptionMode: TranscriptionMode.cloud);
    } else if (src == 'on_device') {
      await repo.setNoteOptions(id,
          transcriptionMode: TranscriptionMode.onDevice);
    }
    await jobs.enqueue(id);
    return true;
  }

  /// D8 "Transcribe on this phone instead".
  Future<void> transcribeOnPhoneInstead(String id) =>
      processor.transcribeOnPhoneInstead(id, jobs);

  void dispose() {
    _netSub?.cancel();
    _lifecycleListener?.dispose();
    jobs.dispose();
  }

  /// C4 "Discard recording": stops capture and deletes this recording's
  /// audio. Nothing is queued and it does not count as a recording.
  Future<void> discardRecording() async {
    final id = recorder.current?.id;
    if (id == null) return;
    _discarding = id;
    try {
      await recorder.stop(reason: 'discard');
      await repo.deleteByUser(id);
    } finally {
      _discarding = null;
      jobs.resume();
    }
  }

  String? _discarding;

  Future<void> _onRecordingFinished(Recording r) async {
    if (r.id == _discarding) return;
    try {
      await _afterRecording(r);
    } finally {
      jobs.resume();
    }
    if (r.durationMs > 0) await noteQueuedByUser();
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
      final r = await recorder.start();
      // The note starts with the current defaults (the C1 language chip and
      // D6 can change them per note).
      await repo.setNoteOptions(r.id,
          language: await settings.audioLanguage(),
          summaryStyle: (await settings.defaultStyle()).id,
          outputLanguage: await settings.summaryLanguage());
      return r;
    } catch (_) {
      jobs.resume();
      rethrow;
    }
  }
}

/// "Your note is ready" as a local notification, only when the app is not on
/// screen. No push server: works while iOS keeps the app running (e.g. a
/// long upload/poll right after recording) or when it is next opened.
class _LocalNoteReadyNotifier implements NoteReadyNotifier {
  _LocalNoteReadyNotifier(this.scheduler, this.inForeground);
  final LocalNotificationScheduler scheduler;
  final bool Function() inForeground;

  @override
  Future<void> noteReady(Recording note) async {
    if (inForeground()) return;
    try {
      await scheduler.showNow(
          id: 5000 + (note.id.hashCode & 0xffff),
          title: 'Your note is ready',
          body: note.title);
    } catch (_) {}
  }
}
