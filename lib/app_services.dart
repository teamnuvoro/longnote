import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'core/analytics/amplitude_sink.dart';
import 'core/analytics/analytics.dart';
import 'core/analytics/meta_sink.dart';
import 'core/analytics/remote_analytics.dart';
import 'core/analytics/tracking_consent.dart';
import 'core/analytics/tracking_profile.dart';
import 'core/audio/pcm_source.dart';
import 'core/billing/billing_service.dart';
import 'core/billing/paywall_gate.dart';
import 'core/billing/storekit_billing_service.dart';
import 'core/billing/trial_reminder.dart';
import 'core/cloud/audio_encoder.dart';
import 'core/cloud/backend_config.dart';
import 'core/cloud/cloud_pieces.dart';
import 'core/cloud/cloud_pipeline.dart';
import 'core/cloud/longnote_api.dart';
import 'core/cloud/network_monitor.dart';
import 'core/cloud/supabase_auth.dart';
import 'core/cloud/tus_uploader.dart';
import 'core/config.dart';
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
    required this.tracking,
    this.meta,
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

  /// Apple's "Allow tracking?" prompt. v1 always passes NoTrackingConsent
  /// (never shown); kept for askTrackingOnce's tests.
  final TrackingConsent tracking;

  /// Meta ad measurement; null when Meta is not in this build (local
  /// builds, tests, simulator QA) or LN_TRACKING=off.
  final MetaSink? meta;

  /// Null when the backend is not configured in this build.
  final SupabaseAuth? auth;
  final LongnoteApi? api;

  late final ProcessingJobQueue jobs;
  late final RecordingController recorder;
  late final NoteProcessor processor;
  CloudPipeline? cloud;

  /// Sends the tracking profile the server needs for subscription events
  /// (docs/ANALYTICS.md "Server events"); null without a backend.
  TrackingProfileSender? trackingProfile;
  void _profileChanged() => unawaited(trackingProfile?.sync());

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

  /// Set once the App Tracking Transparency question was handled, so the
  /// prompt is never shown twice.
  static const kvAttAsked = 'att_asked';

  /// NOT CALLED in v1 (no ATT prompt; owner, 18 Nov 2026). Would ask Apple's
  /// "Allow tracking?" once, only when Meta is in the build, analytics sharing is
  /// on and iOS has no answer yet. Meta collects the IDFA only if allowed.
  Future<void> askTrackingOnce() async {
    final m = meta;
    if (m == null) return;
    if (await kv.getBool(kvAttAsked)) return;
    if (!analytics.remoteEnabled) return;
    await kv.setBool(kvAttAsked, true);
    final before = await tracking.status();
    if (before != AttStatus.notDetermined) {
      await m.setAttAuthorized(before == AttStatus.authorized);
      _profileChanged();
      return;
    }
    final answer = await tracking.request();
    if (answer == AttStatus.notDetermined) {
      // iOS did not show the prompt (app not active): may ask another time.
      await kv.setBool(kvAttAsked, false);
      return;
    }
    await m.setAttAuthorized(answer == AttStatus.authorized);
    _profileChanged();
    await analytics.log(AnalyticsEvent.attResult, props: {'status': answer.name});
  }

  /// Settings > Privacy > "Share usage analytics".
  /// The last event before sharing stops is `share_analytics_off`; the
  /// first after it starts again is `setting_changed`.
  Future<void> setShareAnalytics(bool share) async {
    if (!share) {
      // Sent while sharing is still on (a stuck SDK must not hold the switch).
      await analytics
          .log(AnalyticsEvent.shareAnalyticsOff)
          .timeout(const Duration(seconds: 2), onTimeout: () {});
    }
    await settings.setShareAnalytics(share);
    await analytics.setRemoteEnabled(share);
    if (share) {
      unawaited(analytics.log(AnalyticsEvent.settingChanged,
          props: {'setting': 'share_analytics', 'value': 'on'}));
    }
    _profileChanged();
  }

  /// "Restore purchases" from any screen ([from] = where, for analytics).
  Future<RestoreResult> restorePurchases(String from) async {
    // Analytics never holds up the restore (or its answer on screen).
    unawaited(
        analytics.log(AnalyticsEvent.restoreTapped, props: {'from': from}));
    final r = await billing.restore();
    unawaited(analytics.log(AnalyticsEvent.restoreResult, props: {
      'from': from,
      'result': r.name,
      'active': billing.entitlement.value.isActive,
    }));
    return r;
  }

  /// After a successful purchase: trial_started or subscription_purchased,
  /// marked `source: app`. Only Amplitude gets them, without revenue: the
  /// money events (Amplitude revenue, Meta StartTrial / Subscribe /
  /// Purchase) come from the server, from Apple's notifications.
  Future<void> logPurchase(Plan plan, {required bool startedTrial}) async {
    final props = <String, Object?>{
      'source': 'app',
      'plan': plan.id,
      'period': plan.periodWord,
      'price': plan.price,
      'currency': plan.currency,
    };
    if (startedTrial) {
      final ends = billing.entitlement.value.trialEndsAt;
      await analytics.log(AnalyticsEvent.trialStarted, props: {
        ...props,
        'trial_days': plan.trialDays,
        if (ends != null) 'trial_ends_at': ends.toIso8601String(),
      });
    } else {
      await analytics.log(AnalyticsEvent.subscriptionPurchased, props: props);
    }
  }

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
    var granted = false;
    if (allow) {
      try {
        granted = await reminderScheduler.requestPermission();
      } catch (_) {}
    }
    // "Not now" = skipped (iOS's prompt never shown).
    unawaited(analytics.log(AnalyticsEvent.notificationPermission, props: {
      'result': !allow ? 'skipped' : (granted ? 'allowed' : 'denied'),
      'from': 'note_ready',
    }));
    return granted;
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
    TrackingConsent tracking = const NoTrackingConsent(),
    MetaSink? meta,
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
      tracking: tracking,
      meta: meta,
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

  /// [sourceFactory] replaces the microphone; only the simulator QA suite
  /// (integration_test/) passes one (a file-backed source). The app uses
  /// [RecordPcmSource].
  static Future<AppServices> boot(
      {PcmSource Function()? sourceFactory}) async {
    final support = await getApplicationSupportDirectory();
    final dbPath = p.join(support.path, 'longnote.db');
    final recRoot = Directory(p.join(support.path, 'recordings'))
      ..createSync(recursive: true);

    final db = await AppDatabase.open(factory: databaseFactory, path: dbPath);
    final kv = KvStore(db.db);
    final settings = AppSettings(kv);
    final share = await settings.shareAnalytics();
    // Remote analytics only in builds that carry the keys (CI release
    // builds); local builds, tests and simulator QA send nothing.
    // LN_TRACKING=off (simulator QA) also keeps Meta and the ATT prompt out.
    const trackingOff = String.fromEnvironment('LN_TRACKING') == 'off';
    final useMeta = MetaSink.isConfigured && !trackingOff && Platform.isIOS;
    // No ATT prompt in v1 (owner, 18 Nov 2026): Meta never gets the IDFA.
    // askTrackingOnce() stays (tested with fakes) in case that changes.
    const tracking = NoTrackingConsent();
    final meta = useMeta
        ? MetaSink(FacebookMetaEvents(),
            enabled: share,
            attAuthorized: await tracking.status() == AttStatus.authorized)
        : null;
    final sinks = <AnalyticsSink>[
      if (AmplitudeSink.isConfigured) await AmplitudeSink.create(enabled: share),
      ?meta,
    ];
    final analytics = Analytics(db.db, sinks: sinks, remoteEnabled: share);
    final repo = RecordingRepository(db.db, RecordingStorage(recRoot.path));
    // Real App Store billing on iPhone. LN_BILLING=fake (simulator QA runs
    // 1-5) or =store forces one.
    const billingMode = String.fromEnvironment('LN_BILLING');
    final BillingService billing = billingMode == 'store' ||
            (billingMode != 'fake' && Platform.isIOS)
        ? StoreKitBillingService(kv: kv)
        : FakeBillingService(kv: kv);
    await billing.init();
    final scheduler = LocalNotificationScheduler();
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
      tracking: tracking,
      meta: meta,
      auth: auth,
      api: api,
    );
    // Events carry the Supabase anonymous id once there is one (no network
    // call here: the first upload signs up and reports it).
    if (auth != null) {
      auth.onUserId = (id) => unawaited(analytics.setUserId(id));
      final uid = await auth.knownUserId();
      if (uid != null) await analytics.setUserId(uid);
    }
    unawaited(meta?.activate());
    if (auth != null && api != null) {
      final store = billing is StoreKitBillingService ? billing : null;
      final authed = auth;
      s.trackingProfile = TrackingProfileSender(
        kv: kv,
        send: (body) => api.call('tracking-profile', body,
            timeout: const Duration(seconds: 20)),
        shareEnabled: settings.shareAnalytics,
        knownUserId: auth.knownUserId,
        metaAnonId: meta?.anonymousId,
        attAuthorized: () async =>
            await tracking.status() == AttStatus.authorized,
        transactionJws: store == null ? null : () async => store.transactionJws,
        device: useMeta || AmplitudeSink.isConfigured
            ? const NativeDeviceInfo()
            : const NoDeviceInfo(),
      );
      if (store != null) {
        // StoreKit's appAccountToken = our user id (signs in if needed;
        // offline -> no token, the purchase still works).
        store.appAccountToken =
            () async => await authed.knownUserId() ?? await authed.userId();
        // The profile must reach the server before Apple's notification
        // does (seconds after the purchase): start it with the purchase.
        store.onPurchaseStarting =
            () => unawaited(s.trackingProfile?.sync(allowSignIn: true));
      }
      s._watchProfile();
      // Once per launch, off the startup path; sends only if changed.
      Timer(const Duration(seconds: 6), s._profileChanged);
    }
    s.whisperChoice.value = WhisperChoice.parse(await kv.get(kvWhisper));
    // A dev switch: ignored outside dev builds, so a value left on the phone
    // can never turn real transcripts into placeholders.
    s.useFakeTranscriber =
        AppConfig.devTools && await kv.getBool(kvFakeTranscriber);

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
      sourceFactory: sourceFactory ?? RecordPcmSource.new,
      onFinished: s._onRecordingFinished,
      onStopFailed: () => s.jobs.resume(),
    );

    // 1) Recover anything a crash/force-quit left behind, BEFORE new capture.
    final recovered =
        await RecoveryService(repo: repo, analytics: analytics).recoverAll();
    for (final r in recovered) {
      await s._afterRecording(r);
    }
    s.recoveredAtLaunch = recovered;
    // Off the start path: partial copies of imports the app was killed in.
    unawaited(repo.sweepOrphanPartFiles());

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
      if (st == AppLifecycleState.resumed) {
        jobs.pokeAll();
        unawaited(meta?.activate());
        // Expiry and "cancelled in Settings" are not pushed by the App Store.
        unawaited(billing.refresh());
      }
    });
    if (!_reminderSyncOn) {
      _reminderSyncOn = true;
      billing.entitlement.addListener(_syncReminder);
      _syncReminder();
    }
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

  bool _profileSyncOn = false;
  void _watchProfile() {
    if (_profileSyncOn) return;
    _profileSyncOn = true;
    // A purchase, renewal or restore changes the signed transaction.
    billing.entitlement.addListener(_profileChanged);
  }

  void dispose() {
    _endFreeLimit();
    freeLimitHit.dispose();
    if (_reminderSyncOn) billing.entitlement.removeListener(_syncReminder);
    if (_profileSyncOn) billing.entitlement.removeListener(_profileChanged);
    _netSub?.cancel();
    _lifecycleListener?.dispose();
    jobs.dispose();
  }

  /// C4 "Discard recording": stops capture and deletes this recording's
  /// audio. Nothing is queued and it does not count as a recording.
  Future<void> discardRecording() async {
    final id = recorder.current?.id;
    if (id == null) return;
    // Mark the discard BEFORE anything awaits: a Stop (or a self-stop) in
    // between must not count it as the free recording or queue it.
    _discarding = id;
    final seconds = recorder.elapsed.inSeconds;
    try {
      await recorder.stop(reason: 'discard');
      unawaited(analytics.log(AnalyticsEvent.recordingDiscarded,
          recordingId: id, props: {'duration_s': seconds}));
      await repo.deleteByUser(id);
    } finally {
      _discarding = null;
      jobs.resume();
    }
  }

  String? _discarding;

  // ---- Free 30 seconds (PaywallGate) ---------------------------------------

  /// The recording id when a user without a plan ran out of free seconds
  /// mid-recording (capture is paused). The recording screen opens the
  /// paywall; [afterFreeLimitPaywall] settles it. Null otherwise.
  final ValueNotifier<String?> freeLimitHit = ValueNotifier(null);

  /// Free time left for the current recording; null = no limit (a plan or
  /// trial, or nothing recording).
  Duration? _freeBudget;
  RecordingController? _limitWatched;
  // Level ticks can stop changing in a silent room (ValueNotifier only
  // notifies on change), so a 1 s timer checks too (not in widget tests).
  Timer? _limitTimer;

  /// Called on every audio level tick while capturing (no extra timer).
  void _checkFreeLimit() {
    final budget = _freeBudget;
    final id = recorder.current?.id;
    if (budget == null || id == null) return;
    if (recorder.state != CaptureState.recording) return;
    if (billing.entitlement.value.isActive) {
      _endFreeLimit();
      return;
    }
    if (recorder.elapsed < budget) return;
    // Past the limit, any resume other than afterFreeLimitPaywall (a plan)
    // pauses again.
    if (!_limitPausing) {
      _limitPausing = true;
      unawaited(recorder.pause().whenComplete(() => _limitPausing = false));
    }
    if (freeLimitHit.value == id) return;
    freeLimitHit.value = id;
    unawaited(analytics.log(AnalyticsEvent.freeLimitReached,
        recordingId: id, props: {'duration_s': recorder.elapsed.inSeconds}));
  }

  bool _limitPausing = false;

  void _endFreeLimit() {
    _freeBudget = null;
    _limitTimer?.cancel();
    _limitTimer = null;
    _limitWatched?.level.removeListener(_checkFreeLimit);
    _limitWatched = null;
    freeLimitHit.value = null;
  }

  /// The paywall opened at the free limit closed. On a plan or trial now:
  /// the same recording resumes. Returns whether it resumed; if not, the
  /// caller stops (saves) the recording.
  Future<bool> afterFreeLimitPaywall() async {
    if (!billing.entitlement.value.isActive) return false;
    _endFreeLimit();
    await recorder.resume();
    return true;
  }

  Future<void> _onRecordingFinished(Recording r) async {
    _endFreeLimit();
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

  /// On a plan or trial now (asks the store if the paid-through date passed).
  Future<bool> hasPlan() async {
    final paidUntil = billing.entitlement.value.renewsAt;
    if (paidUntil != null && paidUntil.isBefore(DateTime.now())) {
      await billing.refresh();
    }
    return billing.entitlement.value.isActive;
  }

  /// Gate check + start. Returns false when the paywall must be shown.
  Future<bool> canStartRecording() async {
    if (await hasPlan()) return true;
    return gate.canStart(billing.entitlement.value);
  }

  bool _reminderSyncOn = false;
  void _syncReminder() =>
      unawaited(reminders.syncWith(billing.entitlement.value).catchError(
          (Object e) => debugPrint('trial reminder sync: $e')));

  Future<Recording> startRecording() async {
    jobs.pause(); // keep CPU/battery for capture
    try {
      // Read the free time BEFORE capture starts (the first level tick
      // must already see the budget).
      final free = billing.entitlement.value.isActive
          ? null
          : await gate.freeLeft();
      _endFreeLimit();
      if (free != null) {
        _freeBudget = free;
        _limitWatched = recorder..level.addListener(_checkFreeLimit);
        if (recorder.useTimers) {
          _limitTimer = Timer.periodic(
              const Duration(seconds: 1), (_) => _checkFreeLimit());
        }
      }
      final r = await recorder.start();
      // The note starts with the current defaults (the C1 language chip and
      // D6 can change them per note).
      await repo.setNoteOptions(r.id,
          language: await settings.audioLanguage(),
          summaryStyle: (await settings.defaultStyle()).id,
          outputLanguage: await settings.summaryLanguage());
      return r;
    } catch (_) {
      // Capture may have started and only the note options failed: keep
      // the queue paused while it records.
      if (!recorder.isActive) {
        _endFreeLimit();
        jobs.resume();
      }
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
          body: note.title,
          payload: '${LocalNotificationScheduler.notePayload}${note.id}');
    } catch (_) {}
  }
}
