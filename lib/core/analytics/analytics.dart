import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../util/clock.dart';

/// Event names. Local-only; nothing here is ever sent anywhere.
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

/// Local-only event log in sqflite. No third-party SDK, no network.
class Analytics {
  Analytics(this._db, {Clock clock = const SystemClock()}) : _clock = clock;
  final Database _db;
  final Clock _clock;

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
