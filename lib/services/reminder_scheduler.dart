import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../data/repos.dart';
import 'proactive.dart';

abstract class ReminderScheduler {
  Future<void> schedule(Reminder r);
  Future<void> cancel(int id);

  /// Why scheduled reminders won't show/ring on time, or null when fine or
  /// unknown. Reads the runtime state (notifications enabled, exact alarms
  /// allowed), not manifest declarations.
  Future<String?> deliveryIssue() async => null;

  /// One native test alarm [delay] ahead (replacing a previous test); returns
  /// its time. Accepted by Android != shown to the user.
  Future<DateTime> scheduleTest(Duration delay) =>
      throw UnsupportedError('no test notifications here');

  /// Shows a delivered check-in (see ProactiveDelivery). No-op here.
  Future<void> notify(ProactiveNotice n) async {}

  /// Arms the one evening-review alarm at [at]; null cancels it. No-op here.
  Future<void> scheduleReview(DateTime? at) async {}

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

  /// After a write: applies only the unconfirmed intents (schedule upcoming
  /// enabled rows, cancel the rest) and clears each that succeeded. Returns
  /// the ids still pending; they are retried here next time and at startup.
  Future<List<int>> syncPending(ReminderRepo repo) async {
    final failed = <int>[];
    final now = DateTime.now();
    for (final r in await repo.pending()) {
      try {
        if (r.enabled && r.sync == 'schedule' && r.triggerAt.isAfter(now)) {
          await schedule(r);
        } else {
          await cancel(r.id);
        }
        await repo.synced(r.id);
      } catch (_) {
        failed.add(r.id);
      }
    }
    return failed;
  }
}

/// Task id of the notification the user tapped (deep link to Tasks).
final notificationTaps = ValueNotifier<int?>(null);

/// Chat id of the notification the user tapped (check-ins, evening review).
final chatTaps = ValueNotifier<String?>(null);

/// Native notification target: 'task:<id>' or 'chat:<id>'.
void openTarget(String? target) {
  if (target == null) return;
  if (target.startsWith('task:')) {
    final id = int.tryParse(target.substring(5));
    if (id != null) notificationTaps.value = id;
  } else if (target.startsWith('chat:')) {
    chatTaps.value = target.substring(5);
  }
}

/// For tests / headless use.
class NoopScheduler extends ReminderScheduler {
  @override
  Future<void> schedule(Reminder r) async {}
  @override
  Future<void> cancel(int id) async {}
}

/// Exact AlarmManager alarms armed natively (Proactive.kt). When one fires,
/// ProactiveReceiver runs Dart delivery (current task state, main chat,
/// notification) even with the app closed; no model is loaded for it. The
/// plugin only asks permissions, reports their state and sends the test.
class AlarmReminderScheduler extends ReminderScheduler {
  final _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    tzdata.initializeTimeZones();
    await _plugin.initialize(
        const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (n) => openTarget(n.payload));
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      openTarget(launch!.notificationResponse?.payload);
    }
    // Reminders armed by the plugin before this version would fire a second,
    // unchecked notification; they are re-armed natively at startup.
    try {
      for (final p in await _plugin.pendingNotificationRequests()) {
        if (p.id != _testId) await _plugin.cancel(p.id);
      }
      openTarget(await proactiveChannel.invokeMethod<String>('takeLaunch'));
    } catch (_) {} // best effort; permissions are still requested below
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
  }

  /// Throws (PlatformException exact_alarms_not_permitted) when exact alarms
  /// are not allowed, so the intent stays pending and the issue is shown.
  @override
  Future<void> schedule(Reminder r) => proactiveChannel.invokeMethod(
      'arm', {'id': r.id, 'at': r.triggerAt.millisecondsSinceEpoch});

  /// Also removes the reminder's notification if it is still shown.
  @override
  Future<void> cancel(int id) =>
      proactiveChannel.invokeMethod('disarm', {'id': id});

  @override
  Future<void> notify(ProactiveNotice n) =>
      proactiveChannel.invokeMethod('notify', n.toMap());

  /// Inexact when exact alarms are not allowed: the review is not time-critical.
  @override
  Future<void> scheduleReview(DateTime? at) => at == null
      ? proactiveChannel.invokeMethod('disarm', {'id': reviewNotificationId})
      : proactiveChannel
          .invokeMethod('armReview', {'at': at.millisecondsSinceEpoch});

  /// Fixed id far above reminder row ids, so a test never replaces a reminder.
  static const _testId = 2000000000;

  @override
  Future<DateTime> scheduleTest(Duration delay) async {
    await _plugin.cancel(_testId);
    final at = DateTime.now().add(delay);
    await _plugin.zonedSchedule(
      _testId,
      'Test notification',
      'Corenyth reminders can reach you.',
      tz.TZDateTime.from(at, tz.UTC),
      const NotificationDetails(
          android: AndroidNotificationDetails('reminders', 'Reminders',
              importance: Importance.high, priority: Priority.high)),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
    return at;
  }

  @override
  Future<String?> deliveryIssue() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (await android?.areNotificationsEnabled() == false) {
      return "notifications are turned off for this app, so it won't show. "
          'Turn them on in Android settings.';
    }
    if (await android?.canScheduleExactNotifications() == false) {
      return 'exact alarms are not allowed for this app, so it may arrive late. '
          'Allow "Alarms & reminders" in Android settings.';
    }
    return null;
  }
}
