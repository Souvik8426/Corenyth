import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/v2_db.dart';

class _Alarms extends ReminderScheduler {
  final live = <int, Reminder>{};
  @override
  Future<void> schedule(Reminder r) async => live[r.id] = r;
  @override
  Future<void> cancel(int id) async => live.remove(id);
}

void main() {
  test('replacing an existing task reminder replaces its alerts and due time',
      () async {
    final db = await openMigratedV2();
    final tasks = TaskRepo(db);
    final reminders = ReminderRepo(db);
    final prefs = ReminderPreferencesRepo(db);
    final scheduler = _Alarms();
    tasks.onRemindersChanged = () async {
      await scheduler.syncPending(reminders);
    };
    final now = DateTime(2099, 10, 13, 8);
    final executor = ToolExecutor(tasks, reminders, MemoryRepo(db), scheduler,
        preferences: prefs, clock: () => now);
    await executor.execute(ToolCall('create_reminder', {
      'title': 'meeting',
      'at': now.add(const Duration(hours: 4)),
    }));
    final task = (await tasks.list()).single;
    final later = now.add(const Duration(hours: 6));
    await executor.execute(ToolCall('create_reminder', {
      'title': 'meeting',
      'at': later,
      'task_id': task.id,
      'multiple': true,
    }));
    expect((await tasks.get(task.id))!.dueAt, later);
    expect((await tasks.list()).length, 1);
    expect(scheduler.live.values.map((r) => r.triggerAt).toList()..sort(), [
      later.subtract(const Duration(minutes: 30)),
      later.subtract(const Duration(minutes: 10)),
      later,
    ]);
  });

  test(
      'postponing a late-created multiple reminder restores future lead alerts',
      () async {
    final db = await openMigratedV2();
    final tasks = TaskRepo(db);
    final reminders = ReminderRepo(db);
    final prefs = ReminderPreferencesRepo(db);
    final scheduler = _Alarms();
    tasks.onRemindersChanged = () async {
      await scheduler.syncPending(reminders);
    };
    final now = DateTime(2099, 10, 13, 11, 55);
    final executor = ToolExecutor(tasks, reminders, MemoryRepo(db), scheduler,
        preferences: prefs, clock: () => now);
    await executor.execute(ToolCall('create_reminder', {
      'title': 'meeting',
      'at': DateTime(2099, 10, 13, 12),
      'multiple': true,
    }));
    final task = (await tasks.list()).single;
    expect(scheduler.live.length, 1, reason: 'early alerts are already past');
    await executor.execute(ToolCall('edit_task', {
      'id': task.id,
      'due': DateTime(2099, 10, 14, 12),
    }));
    expect(scheduler.live.values.map((r) => r.triggerAt).toList()..sort(), [
      DateTime(2099, 10, 14, 11, 30),
      DateTime(2099, 10, 14, 11, 50),
      DateTime(2099, 10, 14, 12),
    ]);
    await tasks.complete(task.id);
    expect(scheduler.live, isEmpty);
  });
}
