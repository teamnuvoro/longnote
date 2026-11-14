import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../config.dart';
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
class TrialReminderService {
  TrialReminderService(this.scheduler, {Clock clock = const SystemClock()})
      : _clock = clock;

  final ReminderScheduler scheduler;
  final Clock _clock;
  static const notificationId = 4201;

  /// Returns the scheduled time, or null if nothing was scheduled.
  Future<DateTime?> onTrialStarted(Plan plan, DateTime trialEndsAt) async {
    final at = trialReminderTime(trialEndsAt, _clock.now());
    await scheduler.cancel(notificationId);
    if (at == null) return null;
    await scheduler.schedule(
      id: notificationId,
      at: at,
      title: 'Trial ends in about a day',
      body: trialReminderBody(plan, trialEndsAt),
    );
    return at;
  }
}

/// flutter_local_notifications-backed scheduler. Uses an absolute UTC instant,
/// so no time-zone lookup plugin is needed.
class LocalNotificationScheduler implements ReminderScheduler {
  LocalNotificationScheduler();
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _inited = false;

  Future<void> _init() async {
    if (_inited) return;
    tzdata.initializeTimeZones();
    await _plugin.initialize(
      settings: const InitializationSettings(
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
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
}
