import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/repos.dart';

abstract class ReminderScheduler {
  Future<void> schedule(Reminder r);
  Future<void> cancel(int id);
}

/// For tests / headless use.
class NoopScheduler implements ReminderScheduler {
  @override
  Future<void> schedule(Reminder r) async {}
  @override
  Future<void> cancel(int id) async {}
}

/// AlarmManager-backed notifications; no model/Dart session needed when they fire.
class AlarmReminderScheduler implements ReminderScheduler {
  final _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    tzdata.initializeTimeZones();
    await _plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
  }

  @override
  Future<void> schedule(Reminder r) => _plugin.zonedSchedule(
        r.id,
        'Reminder',
        r.title,
        // from() converts the instant, so UTC as the target zone is correct.
        tz.TZDateTime.from(r.triggerAt, tz.UTC),
        const NotificationDetails(
            android: AndroidNotificationDetails('reminders', 'Reminders',
                importance: Importance.high, priority: Priority.high)),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );

  @override
  Future<void> cancel(int id) => _plugin.cancel(id);

  /// Call on app start: alarms are lost on reinstall/force-clear.
  Future<void> rescheduleAll(ReminderRepo repo) async {
    for (final r in await repo.upcoming()) {
      await schedule(r);
    }
  }
}
