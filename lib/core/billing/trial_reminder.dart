import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

import '../config.dart';
import '../db/app_database.dart';
import '../util/clock.dart';
import 'billing_service.dart';

/// When to remind: [AppConfig.trialReminderLead] before the trial ends.
/// Returns null if that moment has already passed (no point reminding late;
/// we never schedule a notification in the past).
DateTime? trialReminderTime(DateTime trialEndsAt, DateTime now,
    {Duration lead = AppConfig.trialReminderLead}) {
  final at = trialEndsAt.subtract(lead);
  return at.isAfter(now) ? at : null;
}

String trialReminderBody(Plan plan, DateTime trialEndsAt) =>
    'Your free trial ends soon. On ${formatDate(trialEndsAt)} you will be '
    'charged ${plan.priceLabel} per ${plan.periodWord} unless you cancel. '
    'To cancel: Settings > your name > Subscriptions > Longnote.';

String formatDate(DateTime d) {
  const m = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final mm = d.minute.toString().padLeft(2, '0');
  return '${d.day} ${m[d.month - 1]} ${d.year}, $h:$mm ${d.hour < 12 ? 'AM' : 'PM'}';
}

abstract class ReminderScheduler {
  Future<void> schedule(
      {required int id,
      required DateTime at,
      required String title,
      required String body});
  Future<void> cancel(int id);
}

/// Schedules the trial reminder as a local notification (no server needed).
/// With a [kv], remembers what was scheduled so G4 can say "Off" when the
/// user skipped or denied notifications.
class TrialReminderService {
  TrialReminderService(this.scheduler,
      {this.kv, Clock clock = const SystemClock()})
      : _clock = clock;

  final ReminderScheduler scheduler;
  final KvStore? kv;
  final Clock _clock;
  static const notificationId = 4201;
  static const kvScheduledAt = 'trial_reminder_at';

  /// Returns the scheduled time, or null if nothing was scheduled.
  Future<DateTime?> onTrialStarted(Plan plan, DateTime trialEndsAt) async {
    final at = trialReminderTime(trialEndsAt, _clock.now());
    await scheduler.cancel(notificationId);
    await kv?.set(kvScheduledAt, null);
    if (at == null) return null;
    await scheduler.schedule(
      id: notificationId,
      at: at,
      title: 'Trial ends in about a day',
      body: trialReminderBody(plan, trialEndsAt),
    );
    await kv?.set(kvScheduledAt, '${at.millisecondsSinceEpoch}');
    return at;
  }

  /// The reminder scheduled for the trial ending at [trialEndsAt], or null
  /// if none was (skipped, notifications denied, or another trial's).
  Future<DateTime?> scheduledFor(DateTime trialEndsAt) async {
    final v = int.tryParse(await kv?.get(kvScheduledAt) ?? '');
    if (v == null) return null;
    final at = DateTime.fromMillisecondsSinceEpoch(v);
    final want = trialEndsAt.subtract(AppConfig.trialReminderLead);
    return at.difference(want).abs() < const Duration(minutes: 1) ? at : null;
  }
}

/// flutter_local_notifications-backed scheduler. Uses an absolute UTC instant,
/// so no time-zone lookup plugin is needed.
class LocalNotificationScheduler implements ReminderScheduler {
  LocalNotificationScheduler();
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _inited = false;

  /// Prefix of the payload of "note ready" notifications.
  static const notePayload = 'note:';

  /// Called with a note id when the user taps its "note ready" notification
  /// (set by main.dart to open the note).
  static void Function(String noteId)? onOpenNote;

  static void _onTap(NotificationResponse r) {
    final p = r.payload;
    if (p != null && p.startsWith(notePayload)) {
      onOpenNote?.call(p.substring(notePayload.length));
    }
  }

  /// The note whose notification launched the app, if any (cold start).
  Future<String?> launchNoteId() async {
    await _init();
    final d = await _plugin.getNotificationAppLaunchDetails();
    final p = d?.notificationResponse?.payload;
    if (d?.didNotificationLaunchApp != true || p == null) return null;
    return p.startsWith(notePayload) ? p.substring(notePayload.length) : null;
  }

  Future<void> _init() async {
    if (_inited) return;
    // Only tz.UTC is used (built in), so the time-zone database (a slow
    // parse on the UI thread) is never loaded.
    await _plugin.initialize(
      settings: const InitializationSettings(
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: _onTap,
    );
    _inited = true;
  }

  /// Asks for notification permission (called right after the trial starts,
  /// with the reason on screen).
  Future<bool> requestPermission() async {
    await _init();
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    return await ios?.requestPermissions(alert: true, sound: true) ?? false;
  }

  @override
  Future<void> schedule(
      {required int id,
      required DateTime at,
      required String title,
      required String body}) async {
    await _init();
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tz.TZDateTime.from(at.toUtc(), tz.UTC),
      notificationDetails: const NotificationDetails(
          iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true)),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  @override
  Future<void> cancel(int id) async {
    await _init();
    await _plugin.cancel(id: id);
  }

  /// Shows a notification now (e.g. "Your note is ready"). Silently does
  /// nothing if the user has not allowed notifications.
  Future<void> showNow(
      {required int id,
      required String title,
      required String body,
      String? payload}) async {
    await _init();
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      payload: payload,
      notificationDetails: const NotificationDetails(
          iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true)),
    );
  }
}
