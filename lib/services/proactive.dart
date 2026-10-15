import 'package:flutter/services.dart';

import '../assistant/follow_through.dart' show reviewText, isEventTitle;
import '../assistant/tools.dart' show fullDate;
import '../data/repos.dart';
import 'app_services.dart';
import 'reminder_scheduler.dart';

/// Channel shared with Proactive.kt: alarm arming, native notifications and
/// the jobs ProactiveReceiver hands to Dart (in the running app's engine, or
/// in the headless `proactiveMain` engine when the app is closed).
const proactiveChannel = MethodChannel('assistant/alarms');

/// Native notification id of the evening review (Proactive.REVIEW_ID); far
/// above reminder row ids, below the test notification's.
const reviewNotificationId = 1999999999;

/// Missed alarms older than this are not filed on catch-up (no flood).
const _catchUpWindow = Duration(hours: 12);

/// Newer ones are left to the alarm itself, which may still be on its way.
const _alarmGrace = Duration(minutes: 15);

/// One notification as posted natively (see Proactive.notify). [target]
/// opens 'task:<id>' (Tasks) or 'chat:main' when tapped.
class ProactiveNotice {
  final int id;
  final String title, body, target;
  final int? taskId, reminderId, at;
  final List<String> actions;
  const ProactiveNotice(this.id, this.title, this.body, this.target,
      {this.taskId, this.reminderId, this.at, this.actions = const []});

  Map<String, Object?> toMap() => {
        'id': id,
        'title': title,
        'body': body,
        'target': target,
        'taskId': taskId,
        'reminderId': reminderId,
        'at': at,
        'actions': actions,
      };
}

/// Routes `proactive` jobs to [run] and notification taps to [openTarget].
void listenProactive(Future<void> Function(List<Object?> args) run) =>
    proactiveChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'proactive':
          await run(List<Object?>.from(call.arguments as List));
        case 'open':
          openTarget(call.arguments as String?);
      }
      return null;
    });

/// Message kind stored with a delivered alert (the UI labels these).
String alertKind(Reminder r, Task? t) => switch (r.kind) {
      'pre' => 'nudge',
      'follow_up' => 'follow_up',
      _ => t?.dailyMinute != null ? 'daily' : 'reminder',
    };

/// Factual check-in written by app code (no model runs in the background);
/// the local model continues the conversation when the chat is opened.
String alertText(Reminder r, Task? t) {
  final title = t?.title ?? r.title;
  final about = t?.subject == null ? '' : ' (${t!.subject})';
  final due = t?.dueAt;
  switch (alertKind(r, t)) {
    case 'nudge':
      return 'Heads-up: $title$about${due == null ? '' : ' starts at ${_clock(due)}'}. '
          'Anything you want to get ready first?';
    case 'follow_up':
      return "How did $title go? Tell me here and I'll note the outcome, "
          'plus anything you want a reminder about later.';
    case 'daily':
      final d = t!.deadlineAt;
      return 'Daily reminder: $title. ${d == null ? "I'll remind you every day until it's done." : "I'll remind you every day until ${fullDate(d)}, unless you finish sooner."}';
    default:
      return "It's time: $title$about.";
  }
}

String _heading(String kind) => switch (kind) {
      'nudge' => 'Coming up',
      'follow_up' => 'How did it go?',
      'daily' => 'Daily reminder',
      _ => 'Reminder',
    };

String _clock(DateTime t) =>
    '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} '
    '${t.hour < 12 ? 'AM' : 'PM'}';

/// Delivery runs the same way from an alarm (app open or closed), a
/// notification action, and catch-up: re-read current rows, write the main
/// chat message once per occurrence key, notify only when newly written.
extension ProactiveDelivery on AppServices {
  /// Alarm of reminder [id] armed for [at] (ms) fired. Stale alarms (row
  /// moved, disabled, task done/deleted), nudges after the start, optional
  /// check-ins now inside quiet hours and outcomes already given are
  /// dropped. A daily task then moves to its next occurrence. True = new.
  Future<bool> deliverAlert(int id, int at,
      {DateTime? now, bool notify = true}) async {
    now ??= DateTime.now();
    final r = await reminders.get(id);
    if (r == null || !r.enabled || r.triggerAt.millisecondsSinceEpoch != at)
      return false;
    if (r.triggerAt.isAfter(now.add(const Duration(minutes: 1))) ||
        now.difference(r.triggerAt) > _catchUpWindow) {
      return false;
    }
    final t = r.taskId == null ? null : await tasks.get(r.taskId!);
    if (r.taskId != null && (t == null || t.done)) return false;
    final kind = alertKind(r, t);
    final prefs = await preferences.get();
    if (kind == 'nudge' &&
            (prefs.isQuiet(now) ||
                t?.dueAt != null && !t!.dueAt!.isAfter(now)) ||
        kind == 'follow_up' && (prefs.isQuiet(now) || t?.outcome != null)) {
      return false;
    }
    final text = alertText(r, t);
    final added = await conversations.addProactive(alertKey(r), text,
        taskId: r.taskId, kind: kind);
    if (added && kind == 'follow_up' && t != null) {
      await tasks.setAwaiting(
          t.id, TaskRepo.outcomeQuestion); // the reply is its outcome
    }
    if (t?.dailyMinute != null &&
        r.kind == 'reminder' &&
        r.triggerAt == t!.dueAt) {
      await tasks.advanceDaily(t.id, now);
    }
    if (added && notify) {
      await _post(ProactiveNotice(
        r.id,
        _heading(kind),
        text,
        kind == 'follow_up' || t == null
            ? 'chat:${ConversationRepo.mainChatId}'
            : 'task:${t.id}',
        taskId: t?.id,
        reminderId: r.id,
        at: at,
        actions: t == null
            ? const []
            : kind == 'reminder' || kind == 'daily'
                ? const ['done', 'snooze']
                : const ['done'],
      ));
    }
    return added;
  }

  /// Tonight's review, once per day, when follow-ups are on, from its time
  /// until quiet hours start. Raised items are recorded so ignored ones come
  /// back tomorrow; nothing is rescheduled. True = new.
  Future<bool> deliverReview({DateTime? now, bool notify = true}) async {
    now ??= DateTime.now();
    final prefs = await preferences.get();
    final m = prefs.reviewMinute;
    final at = DateTime(now.year, now.month, now.day, m ~/ 60, m % 60);
    if (!prefs.followUp ||
        prefs.isQuiet(now) ||
        now.isBefore(at.subtract(const Duration(minutes: 1)))) {
      return false;
    }
    final day = DateTime(now.year, now.month, now.day);
    if (await conversations.delivered(reviewKey(day))) return false;
    final agenda = await review.agenda(day);
    final text = reviewText(agenda, now, ignored: await review.ignoredCounts());
    if (!await conversations.addProactive(reviewKey(day), text, kind: 'review'))
      return false;
    await review.record(
        day,
        agenda.unresolved
            .where((t) => t.dueAt == null || !t.dueAt!.isAfter(now!))
            .map((t) => t.id));
    for (final t in agenda.finished.take(10)) {
      if (isEventTitle(t.title) && (t.outcome?.trim().isEmpty ?? true)) {
        await tasks.setAwaiting(t.id, TaskRepo.outcomeQuestion);
      }
    }
    if (notify) {
      await _post(ProactiveNotice(reviewNotificationId, 'Evening review', text,
          'chat:${ConversationRepo.mainChatId}'));
    }
    return true;
  }

  /// The message is already saved; a refused notification (permission
  /// revoked) must not undo or repeat the delivery.
  Future<void> _post(ProactiveNotice n) async {
    try {
      await scheduler.notify(n);
    } catch (_) {}
  }

  /// Arms the next review alarm (none while follow-ups are off). Best effort:
  /// the next startup, resume or settings change re-arms it.
  Future<void> armReview({DateTime? now}) async {
    try {
      final p = await preferences.get();
      await scheduler.scheduleReview(
          p.followUp ? nextDaily(p.reviewMinute, now ?? DateTime.now()) : null);
    } catch (_) {}
  }

  /// Done/Snooze from a notification. Acts only while the task is pending
  /// and the reminder still belongs to it. Snooze adds a one-off alert in
  /// [snooze]; the task's due time and deadline stay as they are.
  Future<bool> act(String action, int taskId, int reminderId,
      {DateTime? now, Duration snooze = const Duration(minutes: 10)}) async {
    now ??= DateTime.now();
    final t = await tasks.get(taskId);
    final r = await reminders.get(reminderId);
    if (t == null || t.done || r == null || r.taskId != taskId) return false;
    if (action == 'snooze') {
      await reminders.create(t.title, now.add(snooze), taskId: taskId);
      await syncReminders();
      return true;
    }
    if (action != 'done') return false;
    final meeting = (await reminders.followUpTasks()).contains(taskId);
    if (!await tasks.complete(taskId)) return false;
    if (meeting && t.outcome == null) {
      // Same as finishing early in chat: the follow-up is cancelled, so ask now.
      await tasks.setAwaiting(taskId, TaskRepo.outcomeQuestion);
      await conversations.addProactive('done:$taskId:$reminderId',
          'You marked ${t.title} done. How did it go? Anything you want a reminder about later?',
          taskId: taskId, kind: 'follow_up');
    }
    return true;
  }

  /// Startup, resume, boot, time or time-zone change. Files at most the
  /// latest missed check-in per task from the last 12 hours, silently;
  /// moves daily tasks past missed days (never replayed); catches up
  /// tonight's review silently before quiet hours.
  Future<void> catchUp({DateTime? now}) async {
    now ??= DateTime.now();
    final missed = (await db.query('reminders',
            where: 'enabled = 1 AND trigger_at <= ? AND trigger_at > ?',
            whereArgs: [
              now.subtract(_alarmGrace).millisecondsSinceEpoch,
              now.subtract(_catchUpWindow).millisecondsSinceEpoch,
            ],
            orderBy: 'trigger_at DESC'))
        .map(Reminder.new);
    final seen = <int>{};
    for (final r in missed) {
      if (!seen.add(r.taskId ?? -r.id)) continue;
      await deliverAlert(r.id, r.triggerAt.millisecondsSinceEpoch,
          now: now, notify: false);
    }
    for (final t in await tasks.list()) {
      if (t.dailyMinute == null) continue;
      // File a recent daily occurrence before advancing, even inside alarm grace.
      final due = t.dueAt;
      if (due != null &&
          !due.isAfter(now) &&
          now.difference(due) <= _catchUpWindow) {
        final rows = await db.query('reminders',
            where:
                "task_id = ? AND enabled = 1 AND kind = 'reminder' AND trigger_at = ?",
            whereArgs: [t.id, due.millisecondsSinceEpoch]);
        for (final row in rows) {
          final r = Reminder(row);
          await deliverAlert(r.id, due.millisecondsSinceEpoch,
              now: now, notify: false);
        }
      }
      await tasks.advanceDaily(t.id, now);
    }
    final m = (await preferences.get()).reviewMinute;
    if (!now
        .isBefore(DateTime(now.year, now.month, now.day, m ~/ 60, m % 60))) {
      await deliverReview(now: now, notify: false);
    }
  }

  /// Catch-up, then every alarm re-armed (boot, zone change) and the review.
  Future<void> reconcile() async {
    await catchUp();
    await scheduler.rescheduleAll(reminders);
    await armReview();
  }

  /// One job from ProactiveReceiver (see Proactive.kt for the argument lists).
  Future<void> runProactive(List<Object?> a) async {
    int n(int i) => (a[i] as num).toInt();
    switch (a.first) {
      case 'alert':
        await deliverAlert(n(1), n(2));
      case 'review':
        try {
          await deliverReview();
        } finally {
          await armReview();
        }
      case 'reconcile':
        await reconcile();
      case 'done' || 'snooze':
        await act(a.first as String, n(1), n(2));
    }
    proactiveChanged.value++;
  }
}
