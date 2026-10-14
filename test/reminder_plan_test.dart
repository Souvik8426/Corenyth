import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/v2_db.dart';

class _Recorder extends ReminderScheduler {
  final scheduled = <int>[], cancelled = <int>[];
  final live = <int, Reminder>{};
  int? failOnSchedule; // 1-based count of schedule calls
  @override
  Future<void> schedule(Reminder r) async {
    if (failOnSchedule != null && scheduled.length + 1 >= failOnSchedule!) {
      throw Exception('denied');
    }
    scheduled.add(r.id);
    live[r.id] = r;
  }

  bool failCancel = false;
  String? issue;
  @override
  Future<void> cancel(int id) async {
    if (failCancel) throw Exception('cancel failed');
    cancelled.add(id);
    live.remove(id);
  }

  @override
  Future<String?> deliveryIssue() async => issue;
}

void main() {
  final now = DateTime.now();
  final at = DateTime(now.year, now.month, now.day + 1, 15);

  group('reminderPlan', () {
    const prefs = ReminderPreferences();
    test('single by default, multi 30/10/at, follow-up +60', () {
      expect(reminderPlan(at, prefs, multiple: false, followUp: false, now: now)
          .map((p) => p.kind), ['reminder']);
      final plan = reminderPlan(at, prefs, multiple: true, followUp: true, now: now);
      expect(plan.map((p) => (p.kind, p.at.difference(at).inMinutes)),
          [('pre', -30), ('pre', -10), ('reminder', 0), ('follow_up', 60)]);
    });

    test('skips past offsets and quiet hours, never the event itself', () {
      final soon = now.add(const Duration(minutes: 20));
      expect(reminderPlan(soon, prefs, multiple: true, followUp: false, now: now)
          .map((p) => p.kind), ['pre', 'reminder']);
      final quiet = prefs.copyWith(quiet: (22 * 60, 7 * 60));
      final late = DateTime(at.year, at.month, at.day, 22, 30);
      expect(reminderPlan(late, quiet, multiple: true, followUp: true, now: now)
          .map((p) => p.kind), ['reminder']);
    });

    test('quiet hours wrap midnight; invalid prefs are rejected', () {
      final q = const ReminderPreferences().copyWith(quiet: (22 * 60, 7 * 60));
      expect(q.isQuiet(DateTime(2026, 1, 1, 23)), isTrue);
      expect(q.isQuiet(DateTime(2026, 1, 1, 6, 59)), isTrue);
      expect(q.isQuiet(DateTime(2026, 1, 1, 7)), isFalse);
      expect(() => const ReminderPreferences(leadMinutes: []).validated(), throwsArgumentError);
      expect(() => const ReminderPreferences(followUpMinutes: 1).validated(), throwsArgumentError);
      expect(() => const ReminderPreferences(quietStart: 5).validated(), throwsArgumentError);
    });
  });

  test('friendlyTime shows exact date and time', () {
    expect(friendlyTime(DateTime(2026, 10, 14, 9), DateTime(2026, 10, 13, 20)),
        'tomorrow (Wed 14 Oct) at 9:00 AM');
    expect(friendlyTime(DateTime(2027, 1, 2, 13, 5), DateTime(2026, 10, 13)),
        'on Sat 2 Jan 2027 at 1:05 PM');
  });

  group('sqlite lifecycle', () {
    late TaskRepo tasks;
    late ReminderRepo reminders;
    late ReminderPreferencesRepo prefs;
    late _Recorder sch;
    late ToolExecutor x;
    setUp(() async {
      final db = await openMigratedV2();
      tasks = TaskRepo(db);
      reminders = ReminderRepo(db);
      prefs = ReminderPreferencesRepo(db);
      sch = _Recorder();
      tasks.onRemindersChanged =
          prefs.onRemindersChanged = () => sch.syncPending(reminders);
      x = ToolExecutor(tasks, reminders, MemoryRepo(db), sch,
          clock: () => now, preferences: prefs);
    });

    Future<String> remind(String title, {bool? multiple, bool? followUp}) =>
        x.execute(ToolCall('create_reminder', {'title': title, 'at': at,
          if (multiple != null) 'multiple': multiple,
          if (followUp != null) 'follow_up': followUp}));

    test('defaults off: one alert linked to a task, preferences round trip', () async {
      expect((await prefs.get()).multiple, isFalse);
      expect(await remind('Dentist'), contains('3:00 PM'));
      final t = (await tasks.list()).single;
      expect(t.dueAt, at);
      expect((await reminders.forTask(t.id)).length, 1);
      expect(await reminders.pending(), isEmpty);
      await prefs.save(const ReminderPreferences(multiple: true, leadMinutes: [10, 60],
          followUpMinutes: 90, quietStart: 1320, quietEnd: 420));
      final p = await prefs.get();
      expect(p.leadMinutes, [60, 10]);
      expect((p.multiple, p.followUpMinutes, p.quietStart, p.quietEnd),
          (true, 90, 1320, 420));
      expect(await remind('Dentist'), contains('already'), reason: 'no duplicate');
    });

    test('multi + follow-up plan, discloses times; done cancels all', () async {
      final reply = await remind('Dentist', multiple: true, followUp: true);
      expect(reply, allOf(contains('2:30 PM, 2:50 PM and 3:00 PM'),
          contains('4:00 PM'), contains("don't know when it ends")));
      final t = (await tasks.list()).single;
      final ids = [for (final r in await reminders.forTask(t.id)) r.id];
      expect(ids.length, 4);
      expect(sch.scheduled, ids);
      // cancel by title: the plan is one match, cancelled as a group, task stays
      expect(await x.execute(ToolCall('cancel_reminder', {'title': 'dentist'})),
          contains('other alerts'));
      expect(await reminders.forTask(t.id), isEmpty);
      expect(sch.cancelled, unorderedEquals(ids));
      expect((await tasks.list()).single.id, t.id);
    });

    test('Tasks-style postpone shifts the plan; complete cancels it', () async {
      await remind('Call', multiple: true);
      final t = (await tasks.list()).single;
      await tasks.update(t.id, {'due_at': at.add(const Duration(hours: 1)).millisecondsSinceEpoch});
      expect([for (final r in await reminders.forTask(t.id)) r.triggerAt.hour * 60 + r.triggerAt.minute],
          [16 * 60 - 30, 16 * 60 - 10, 16 * 60]);
      expect(await reminders.pending(), isEmpty, reason: 'hook synced alarms');
      expect(await x.execute(ToolCall('complete_task', {'id': t.id})),
          contains('cancelled its remaining reminders'));
      expect(await reminders.forTask(t.id), isEmpty);
      expect(await reminders.pending(), isEmpty);
    });

    test('turning follow-ups off cancels scheduled follow-ups', () async {
      await prefs.save(const ReminderPreferences(followUp: true));
      expect(await remind('Gym'), contains('check in'));
      await prefs.save(const ReminderPreferences());
      final left = await reminders.upcoming();
      expect(left.map((r) => r.kind), ['reminder']);
      expect(sch.cancelled.length, 1);
    });

    test('partial schedule failure rolls back everything, honestly', () async {
      sch.failOnSchedule = 2;
      await expectLater(remind('Dentist', multiple: true),
          throwsA(isA<ToolError>().having((e) => e.message, 'm', contains('not saved'))));
      expect(await tasks.list(), isEmpty);
      expect(await reminders.upcoming(), isEmpty);
      expect(await reminders.pending(), isEmpty);
      expect(sch.cancelled, isNotEmpty, reason: 'the armed alert was removed');
    });

    test('moving the main reminder moves the whole plan and the task', () async {
      await remind('Dentist', multiple: true);
      final main = (await reminders.upcoming()).firstWhere((r) => r.kind == 'reminder');
      final later = at.add(const Duration(days: 1));
      expect(await x.execute(ToolCall('edit_reminder', {'id': main.id, 'at': later})),
          contains('other alerts moved'));
      expect((await tasks.list()).single.dueAt, later);
      expect((await reminders.upcoming()).first.triggerAt,
          later.subtract(const Duration(minutes: 30)));
    });

    test('edit by title picks the event alert and moves the whole plan', () async {
      await remind('Dentist', multiple: true);
      final later = at.add(const Duration(days: 1));
      expect((await reminders.byTitle('dentist')).single.kind, 'reminder');
      expect(await x.execute(ToolCall('edit_reminder', {'target_title': 'Dentist', 'at': later})),
          contains('other alerts moved'));
      expect((await tasks.list()).single.dueAt, later);
      expect([for (final r in await reminders.upcoming()) r.triggerAt], [
        later.subtract(const Duration(minutes: 30)),
        later.subtract(const Duration(minutes: 10)),
        later,
      ]);
    });

    test('rollback whose cancel also fails discloses alerts may remain', () async {
      sch.failOnSchedule = 2;
      sch.failCancel = true;
      await expectLater(remind('Dentist', multiple: true),
          throwsA(isA<ToolError>().having((e) => e.message, 'm', contains('may still go off'))));
      expect(await tasks.list(), isEmpty);
      expect(await reminders.upcoming(), isEmpty);
      expect((await reminders.pending()).map((r) => r.sync).toSet(), {'cancel'},
          reason: 'cancel intents kept for retry');
    });

    test('moving a plan drops early alerts that land in quiet hours', () async {
      await prefs.save(const ReminderPreferences(quietStart: 22 * 60, quietEnd: 7 * 60));
      await remind('Flight', multiple: true);
      final t = (await tasks.list()).single;
      final early = DateTime(at.year, at.month, at.day + 1, 7, 10);
      await tasks.update(t.id, {'due_at': early.millisecondsSinceEpoch});
      expect([for (final r in await reminders.forTask(t.id)) (r.kind, r.triggerAt)], [
        ('pre', early.subtract(const Duration(minutes: 10))),
        ('reminder', early),
      ]);
      expect(await reminders.pending(), isEmpty, reason: 'dropped alert cancelled');
    });

    test('follow-up check-in only for tasks with a follow-up', () async {
      await remind('Gym', followUp: true);
      await remind('Call');
      final ids = {for (final t in await tasks.list()) t.title: t.id};
      expect(await reminders.followUpTasks(), {ids['Gym']});
    });

    test('discloses when notifications are off instead of promising', () async {
      sch.issue = "notifications are turned off for this app, so it won't show.";
      final reply = await remind('Dentist');
      expect(reply, allOf(startsWith('Saved the reminder'), contains('turned off')));
      expect(reply, isNot(contains("I'll remind you")));
    });

    List<(String, DateTime)> live(int taskId) => [
          for (final r in sch.live.values.where((r) => r.taskId == taskId))
            (r.kind, r.triggerAt)
        ]..sort((a, b) => a.$2.compareTo(b.$2));

    test('quiet-hours drop comes back when moved out again; no id reuse clash', () async {
      await prefs.save(const ReminderPreferences(quietStart: 22 * 60, quietEnd: 7 * 60));
      await remind('Flight', multiple: true);
      final t = (await tasks.list()).single;
      final d = DateTime(at.year, at.month, at.day + 1);
      await tasks.update(t.id, {'due_at': d.add(const Duration(hours: 7, minutes: 10)).millisecondsSinceEpoch});
      expect(live(t.id).map((e) => e.$1), ['pre', 'reminder'], reason: '6:40 is quiet');
      await tasks.update(t.id, {'due_at': d.add(const Duration(hours: 9)).millisecondsSinceEpoch});
      expect(live(t.id), [
        ('pre', d.add(const Duration(hours: 8, minutes: 30))),
        ('pre', d.add(const Duration(hours: 8, minutes: 50))),
        ('reminder', d.add(const Duration(hours: 9))),
      ]);
      final ids = [for (final r in await reminders.forTask(t.id)) r.id];
      expect(ids.toSet().length, 3);
      expect(await reminders.pending(), isEmpty);
      // cancel after rebuilding removes every alarm and the plan stays dead
      expect(await x.execute(ToolCall('cancel_reminder', {'title': 'Flight'})),
          contains('other alerts'));
      expect(live(t.id), isEmpty);
      await tasks.update(t.id, {'due_at': d.add(const Duration(hours: 12)).millisecondsSinceEpoch});
      expect(live(t.id), isEmpty, reason: 'cancelled plan never regenerated');
    });

    test('complete after rebuild cancels all; restore never resurrects', () async {
      await remind('Call', multiple: true, followUp: true);
      final t = (await tasks.list()).single;
      await tasks.update(t.id, {'due_at': at.add(const Duration(days: 1)).millisecondsSinceEpoch});
      expect(live(t.id).length, 4);
      await tasks.complete(t.id);
      expect(live(t.id), isEmpty);
      await tasks.update(t.id, {'status': 'pending', 'completed_at': null});
      await tasks.update(t.id, {'due_at': at.add(const Duration(days: 2)).millisecondsSinceEpoch});
      expect(live(t.id), isEmpty);
    });

    test('follow-ups off: a later move does not bring the follow-up back', () async {
      await remind('Gym', followUp: true);
      final t = (await tasks.list()).single;
      await prefs.save(const ReminderPreferences());
      await tasks.update(t.id, {'due_at': at.add(const Duration(days: 1)).millisecondsSinceEpoch});
      expect(live(t.id).map((e) => e.$1), ['reminder']);
    });

    test('failed move rolls back the whole prior plan, skipped offsets included', () async {
      await remind('Dentist', multiple: true, followUp: true);
      final t = (await tasks.list()).single;
      final before = live(t.id);
      expect(before.length, 4);
      final main = (await reminders.forTask(t.id)).firstWhere((r) => r.kind == 'reminder');
      sch.failOnSchedule = sch.scheduled.length + 1;
      await expectLater(
          x.execute(ToolCall('edit_reminder', {'id': main.id, 'at': at.add(const Duration(days: 1))})),
          throwsA(isA<ToolError>()));
      sch.failOnSchedule = null;
      await sch.syncPending(reminders);
      expect((await tasks.get(t.id))!.dueAt, at);
      expect(live(t.id), before);
    });

    test('replacing a task plan: failure restores due, plan and old alarms', () async {
      await remind('Meeting', followUp: true);
      final t = (await tasks.list()).single;
      final before = live(t.id);
      final plan = await reminders.planOf(t.id);
      sch.failOnSchedule = sch.scheduled.length + 2;
      await expectLater(
          x.execute(ToolCall('create_reminder', {'title': 'Meeting', 'task_id': t.id,
            'at': at.add(const Duration(hours: 2)), 'multiple': true})),
          throwsA(isA<ToolError>()));
      sch.failOnSchedule = null;
      await sch.syncPending(reminders);
      expect((await tasks.get(t.id))!.dueAt, at);
      expect(await reminders.planOf(t.id), plan);
      expect(live(t.id), before);
      expect(await reminders.pending(), isEmpty);
      expect((await tasks.list()).length, 1);
    });

    test('replacement whose old-alarm cancel fails keeps a durable cancel', () async {
      await remind('Meeting');
      final t = (await tasks.list()).single;
      final old = (await reminders.forTask(t.id)).single.id;
      sch.failCancel = true;
      await x.execute(ToolCall('create_reminder', {'title': 'Meeting', 'task_id': t.id,
        'at': at.add(const Duration(hours: 2))}));
      expect((await reminders.pending()).map((r) => (r.id, r.sync)), [(old, 'cancel')]);
      sch.failCancel = false;
      await sch.syncPending(reminders);
      expect(live(t.id).map((e) => e.$2), [at.add(const Duration(hours: 2))]);
    });

    test('a done task cannot get a reminder until restored', () async {
      final t = await tasks.create('Report');
      await tasks.complete(t.id);
      await expectLater(
          x.execute(ToolCall('create_reminder', {'title': 'Report', 'task_id': t.id, 'at': at})),
          throwsA(isA<ToolError>().having((e) => e.message, 'm', contains('Restore'))));
      expect(await reminders.forTask(t.id), isEmpty);
    });

    test('shopping nudge lists other pending buys, not done ones', () async {
      await x.execute(ToolCall('create_task', {'title': 'Buy eggs'}));
      final bread = await tasks.create('buy bread');
      await tasks.create('Buy stamps');
      await tasks.complete((await tasks.create('Buy soap')).id);
      expect(bread.id, 2);
      final reply = await x.execute(ToolCall('create_task', {'title': 'Buy milk'}));
      expect(reply, 'Added task Buy milk. You also still need to buy eggs, bread and stamps.');
    });
  });
}
