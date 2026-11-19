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
