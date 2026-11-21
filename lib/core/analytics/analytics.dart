import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../util/clock.dart';
import 'remote_analytics.dart';

/// Event names. Every event is kept in the local log and, while "Share usage
/// analytics" is on, forwarded to Amplitude; a few also go to Meta
/// (docs/ANALYTICS.md).
class AnalyticsEvent {
  AnalyticsEvent._();
  static const recordingStarted = 'recording_started';
  static const recordingCompleted = 'recording_completed';
  static const recordingInterrupted = 'recording_interrupted';
  static const recordingRecovered = 'recording_recovered';
  static const processingFailed = 'processing_failed';
  static const processingRetried = 'processing_retried';
  static const transcriptViewed = 'transcript_viewed';
  static const summaryViewed = 'summary_viewed';
  static const export = 'export';
  static const paywallViewed = 'paywall_viewed';
  static const trialStarted = 'trial_started';

  /// A paid (non-trial) subscription purchase.
  static const subscriptionPurchased = 'subscription_purchased';
  static const restoreTapped = 'restore_tapped';
  static const restoreResult = 'restore_result';
  static const onboardingCompleted = 'onboarding_completed';

  /// Each onboarding screen as it shows (the funnel up to the paywall).
  static const onboardingStep = 'onboarding_step';

  /// A paywall FAQ question opened.
  static const paywallFaqOpened = 'paywall_faq_opened';

  /// The App Tracking Transparency answer (only when the prompt was shown).
  static const attResult = 'att_result';

  // ---- Screens and actions (Amplitude only; no note content, ever) ------

  /// Every route change (tab switch, push, sheet, pop back): `screen` = the
  /// route name (app/routes.dart). ScreenViewTracker logs it.
  static const screenViewed = 'screen_viewed';

  // Paywall. `plan` = the store product id, `placement` as paywall_viewed.
  static const paywallPlanSelected = 'paywall_plan_selected';
  static const paywallPurchaseTapped = 'paywall_purchase_tapped';

  /// `result`: purchased / cancelled / pending / failed.
  static const paywallPurchaseResult = 'paywall_purchase_result';

  /// `how`: close_button / purchased / restored / system_back.
  static const paywallClosed = 'paywall_closed';

  /// "See everything you get".
  static const paywallMoreOpened = 'paywall_more_opened';

  /// `result`: allowed / denied, `from`: where it was asked.
  static const micPermission = 'mic_permission';

  /// `result`: allowed / denied / skipped (our own ask, before iOS's).
  static const notificationPermission = 'notification_permission';

  static const recordingPaused = 'recording_paused';
  /// A user without a plan used the free 30 s mid-recording (`duration_s`).
  static const freeLimitReached = 'free_limit_reached';
  static const recordingResumed = 'recording_resumed';

  /// C4 "Discard recording": `duration_s`.
  static const recordingDiscarded = 'recording_discarded';

  /// Once per search session: `chars_bucket` 1-3 / 4-10 / 11+ (never the
  /// search text).
  static const searchUsed = 'search_used';
  static const noteRenamed = 'note_renamed';
  static const noteDeleted = 'note_deleted';
  static const speakerRenamed = 'speaker_renamed';
  /// Edit tapped on the Summary tab.
  static const summaryEditOpened = 'summary_edit_opened';
  /// One per edit session that changed something: counts only, never text
  /// (`fields_changed`, `items_removed`, `items_added`).
  static const summaryEdited = 'summary_edited';

  /// `style`: the style id, `from`: note / settings / onboarding.
  static const summaryStyleChanged = 'summary_style_changed';
  static const playbackStarted = 'playback_started';

  /// Ask: `from`; then `result` ok / failed. Never the question or answer.
  static const askSent = 'ask_sent';
  static const askAnswered = 'ask_answered';

  /// Import: `kind` audio / video (by extension, never the file name).
  static const importStarted = 'import_started';
  static const importCompleted = 'import_completed';

  /// `error`: a code.
  static const importFailed = 'import_failed';

  /// The user stopped the copy (F3 "x"): `kind`, `format`.
  static const importCancelled = 'import_cancelled';

  /// Settings: `setting` + `value` (codes: a language code, a mode, a style).
  static const settingChanged = 'setting_changed';

  /// Logged just BEFORE the switch turns remote analytics off.
  static const shareAnalyticsOff = 'share_analytics_off';
  static const rateTapped = 'rate_tapped';
  static const supportTapped = 'support_tapped';
  static const manageSubscriptionTapped = 'manage_subscription_tapped';

  /// `link`: terms / privacy, `from`: paywall / settings / plan.
  static const legalLinkOpened = 'legal_link_opened';
  static const deleteDataConfirmed = 'delete_data_confirmed';

  static const all = [
    recordingStarted,
    recordingCompleted,
    recordingInterrupted,
    recordingRecovered,
    processingFailed,
    processingRetried,
    transcriptViewed,
    summaryViewed,
    export,
    paywallViewed,
    trialStarted,
    subscriptionPurchased,
    restoreTapped,
    restoreResult,
    onboardingCompleted,
    onboardingStep,
    paywallFaqOpened,
    attResult,
    screenViewed,
    paywallPlanSelected,
    paywallPurchaseTapped,
    paywallPurchaseResult,
    paywallClosed,
    paywallMoreOpened,
    micPermission,
    notificationPermission,
    recordingPaused,
    freeLimitReached,
    recordingResumed,
    recordingDiscarded,
    searchUsed,
    noteRenamed,
    noteDeleted,
    speakerRenamed,
    summaryEditOpened,
    summaryEdited,
    summaryStyleChanged,
    playbackStarted,
    askSent,
    askAnswered,
    importStarted,
    importCompleted,
    importFailed,
    importCancelled,
    settingChanged,
    shareAnalyticsOff,
    rateTapped,
    supportTapped,
    manageSubscriptionTapped,
    legalLinkOpened,
    deleteDataConfirmed,
  ];
}

class LoggedEvent {
  LoggedEvent(this.name, this.ts, this.recordingId, this.props);
  final String name;
  final DateTime ts;
  final String? recordingId;
  final Map<String, Object?> props;

  @override
  String toString() =>
      '${ts.toIso8601String()}  $name${recordingId == null ? '' : '  rec=$recordingId'}'
      '${props.isEmpty ? '' : '  ${jsonEncode(props)}'}';
}

/// Event log: always written to sqflite on the phone, then forwarded to the
/// remote [sinks] (Amplitude, Meta) while [remoteEnabled]. Tests and
/// simulator QA pass no sinks, so nothing leaves the phone there.
class Analytics {
  Analytics(this._db,
      {Clock clock = const SystemClock(),
      List<AnalyticsSink> sinks = const [],
      bool remoteEnabled = true})
      : _clock = clock,
        _sinks = List.unmodifiable(sinks),
        _remoteEnabled = remoteEnabled;
  final Database _db;
  final Clock _clock;
  final List<AnalyticsSink> _sinks;
  bool _remoteEnabled;

  List<AnalyticsSink> get sinks => _sinks;

  /// The "Share usage analytics" switch.
  bool get remoteEnabled => _remoteEnabled;

  /// Turns every remote sink on or off (the local log keeps working: it
  /// never leaves the phone).
  Future<void> setRemoteEnabled(bool enabled) async {
    _remoteEnabled = enabled;
    for (final s in _sinks) {
      try {
        await s.setEnabled(enabled);
      } catch (_) {}
    }
  }

  /// The Supabase anonymous id, once known.
  Future<void> setUserId(String? userId) async {
    for (final s in _sinks) {
      try {
        await s.setUserId(userId);
      } catch (_) {}
    }
  }

  /// Never throws: analytics must not break the app.
  Future<void> log(String name,
      {String? recordingId, Map<String, Object?>? props}) async {
    try {
      await _db.insert('events', {
        'name': name,
        'ts': _clock.now().millisecondsSinceEpoch,
        'recording_id': recordingId,
        'props': props == null || props.isEmpty ? null : jsonEncode(props),
      });
    } catch (_) {
      // Swallow: a full disk must not crash a recording because of a log row.
    }
    if (!_remoteEnabled || _sinks.isEmpty) return;
    final safe = remoteSafeProps(props);
    if (recordingId != null) safe['recording_id'] = recordingId;
    for (final s in _sinks) {
      try {
        await s.track(name, safe);
      } catch (_) {}
    }
  }

  Future<List<LoggedEvent>> recent({int limit = 500, String? name}) async {
    final rows = await _db.query('events',
        where: name == null ? null : 'name = ?',
        whereArgs: name == null ? null : [name],
        orderBy: 'id DESC',
        limit: limit);
    return rows
        .map((r) => LoggedEvent(
              r['name'] as String,
              DateTime.fromMillisecondsSinceEpoch(r['ts'] as int),
              r['recording_id'] as String?,
              r['props'] == null
                  ? const {}
                  : (jsonDecode(r['props'] as String) as Map)
                      .cast<String, Object?>(),
            ))
        .toList();
  }

  Future<Map<String, int>> counts() async {
    final rows = await _db
        .rawQuery('SELECT name, COUNT(*) AS c FROM events GROUP BY name');
    return {for (final r in rows) r['name'] as String: r['c'] as int};
  }
}
