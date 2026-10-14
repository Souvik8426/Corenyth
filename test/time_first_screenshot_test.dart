import 'dart:convert';

import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backend_test.dart'
    show
        FakeTasks,
        FakeReminders,
        FakeMemory,
        FakeProfile,
        FakeConversations,
        SpyEngine;

void main() {
  const request =
      'Morning 8:10 am remind me i have to schedule a meet with ceo of komal goyal studios';
  const title = 'schedule a meet with ceo of komal goyal studios';
  late DateTime now;
  late FakeTasks tasks;
  late FakeReminders reminders;
  late SpyEngine model;
  late AssistantSession session;
  setUp(() async {
    now = DateTime(2026, 10, 14, 7);
    tasks = FakeTasks();
    reminders = FakeReminders();
    final memory = FakeMemory();
    model = SpyEngine()
      ..output =
          jsonEncode({'type': 'tool', 'tool': 'list_tasks', 'arguments': {}});
    session = AssistantSession(
      engine: model,
      tools: ToolExecutor(tasks, reminders, memory, NoopScheduler(),
          clock: () => now),
      memory: memory,
      profile: FakeProfile(),
      taskRepo: tasks,
      conversations: FakeConversations(),
      clock: () => now,
    );
    await session.start();
    addTearDown(session.close);
  });

  test(
      'the exact time-first request schedules the requested action, not a task list',
      () async {
    await tasks.create('buy milk');
    await tasks.create('bring milk');
    final reply = await session.handle(request);
    final reminder = (await reminders.upcoming()).single;
    expect(reminder.title.toLowerCase(), title);
    expect(reminder.triggerAt, DateTime(2026, 10, 14, 8, 10));
    expect(reply.toLowerCase(), isNot(contains('buy milk')));
    expect(model.calls, greaterThan(0)); // model-first; invalid plan -> rules
  });

  test('a date clarification retains the originally supplied 8:10 time',
      () async {
    now = DateTime(2026, 10, 14, 10);
    final reply = await session.handle(request);
    expect(await reminders.upcoming(), isEmpty);
    expect(reply, contains('8:10'));
    await session.handle('tomorrow');
    final reminder = (await reminders.upcoming()).single;
    expect(reminder.title.toLowerCase(), title);
    expect(reminder.triggerAt, DateTime(2026, 10, 15, 8, 10));
  });

  test('morning plus an explicit clock does not require repeating am',
      () async {
    await session.handle(request.replaceFirst('8:10 am', '8:10'));
    final reminder = (await reminders.upcoming()).single;
    expect(reminder.triggerAt, DateTime(2026, 10, 14, 8, 10));
    expect(reminder.title.toLowerCase(), title);
  });
}
