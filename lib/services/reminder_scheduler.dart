import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/repos.dart';

abstract class ReminderScheduler {
  Future<void> schedule(Reminder r);
  Future<void> cancel(int id);

  /// Call on app start: alarms are lost on reinstall/force-clear, and a schedule
  /// or cancel may have failed or been interrupted. Re-arms every upcoming
  /// enabled reminder, retries pending cancels (cancelled rows are never
  /// re-armed) and clears each intent that succeeded. One failure doesn't stop
  /// the rest; returns the ids still out of sync.
  Future<List<int>> rescheduleAll(ReminderRepo repo) async {
    final failed = <int>[];
    final upcoming = await repo.upcoming();
    final live = {for (final r in upcoming) r.id};
    for (final r in upcoming) {
      try {
        await schedule(r);
        if (r.sync != null) await repo.synced(r.id);
      } catch (_) {
        failed.add(r.id);
      }
    }
    for (final r in await repo.pending()) {
      if (live.contains(r.id)) continue;
      try {
        // Disabled rows only ever need their alarm gone; expired ones too.
        await cancel(r.id);
        await repo.synced(r.id);
      } catch (_) {
        if (r.sync == 'cancel') failed.add(r.id);
      }
    }
    return failed;
  }
}

/// For tests / headless use.
class NoopScheduler extends ReminderScheduler {
  @override
  Future<void> schedule(Reminder r) async {}
  @override
  Future<void> cancel(int id) async {}
}

/// AlarmManager-backed notifications; no model/Dart session needed when they fire.
class AlarmReminderScheduler extends ReminderScheduler {
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
}
