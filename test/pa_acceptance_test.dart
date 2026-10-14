import 'dart:convert';

import 'package:assistant/assistant/rule_engine.dart';
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
  test('model suggestions cannot invent notification overrides or task links',
      () {
    final rules = RuleEngine(clock: () => DateTime(2099, 10, 13, 8));
    const request = 'remind me to call Sarah at 12pm';
    final args = <String, Object?>{
      'title': 'call Sarah',
      'at': DateTime(2099, 10, 13, 12),
    };
    expect(rules.justifiedMutation('create_reminder', request, args), isTrue);
    for (final extra in [
      {'multiple': true},
      {'follow_up': true},
      {'task_id': 1},
    ]) {
      expect(
          rules.justifiedMutation(
              'create_reminder', request, {...args, ...extra}),
          isFalse,
          reason: '$extra was not requested');
    }
  });

  final now = DateTime(2099, 10, 13, 8);
  late FakeTasks tasks;
  late FakeReminders reminders;
  late FakeMemory memory;
  late SpyEngine engine;
  late AssistantSession session;

  setUp(() async {
    tasks = FakeTasks();
    reminders = FakeReminders();
    memory = FakeMemory();
    engine = SpyEngine();
    session = AssistantSession(
      engine: engine,
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

  test('the screenshot recall request includes undated pending commitments',
      () async {
    await tasks.create('call Mum');
    await tasks.create('send invoice',
        due: now.subtract(const Duration(days: 1)));
    final reply = await session.handle(
        'Hello canu remind me what are the things which i have catch on');
    expect(reply, contains('call Mum'));
    expect(reply, contains('send invoice'));
    expect(await reminders.upcoming(), isEmpty);
    expect((await tasks.list()).length, 2);
  });

  test(
      'the eggs and bread conversation stores tasks and recalls the related errand',
      () async {
    await session.handle('i have to buy eggs in evening');
    final eggs = (await tasks.list()).single;
    expect(eggs.title.toLowerCase(), 'buy eggs');
    expect(eggs.dueAt, DateTime(2099, 10, 13, 19));
    final reply = await session.handle('i also need to buy bread');
    expect(reply.toLowerCase(), contains('eggs'));
    expect((await tasks.list()).map((t) => t.title.toLowerCase()),
        containsAll(['buy eggs', 'buy bread']));
    expect(await reminders.upcoming(), isEmpty);
    expect(memory.items, isEmpty);
  });

  test('both screenshot calculations bypass the model and never create tasks',
      () async {
    expect(await session.handle('What is 90+24-10*89898'), contains('-898866'));
    expect(await session.handle('What is 46+50'), contains('96'));
    expect(await tasks.list(), isEmpty);
    expect(engine.calls, 0);
  });

  test('a reminder draft survives an unrelated arithmetic question', () async {
    final first = await session.handle('remind me to call Sarah');
    expect(first.toLowerCase(), contains('when'));
    expect(await session.handle('What is 2+2'), contains('4'));
    await session.handle('in twenty minutes');
    final reminder = (await reminders.upcoming()).single;
    expect(reminder.title.toLowerCase(), 'call sarah');
    expect(reminder.triggerAt, now.add(const Duration(minutes: 20)));
  });

  test('negative follow-up override does not negate the reminder itself', () {
    final rules = RuleEngine(clock: () => now);
    final route =
        rules.fastRoute('remind me to call Sarah at 12pm with no follow-ups');
    expect(route, isNotNull);
    final call = parseToolCall(jsonEncode(route));
    expect(call.tool, 'create_reminder');
    expect(call.args['follow_up'], false);
    expect(call.args['title'], 'call Sarah');
    expect(rules.fastRoute("Don't remind me to call Sarah at 12pm")?['tool'],
        isNot('create_reminder'));
  });

  test('an explanation request cannot execute a model-proposed deletion',
      () async {
    final task = await tasks.create('buy eggs');
    engine.output = jsonEncode({
      'type': 'tool',
      'tool': 'delete_task',
      'arguments': {'id': task.id},
    });
    await session.handle('Explain how to delete tasks');
    expect(await tasks.get(task.id), isNotNull);
  });

  test(
      'relative postponement keeps the selected task and uses a validated time',
      () async {
    final task =
        await tasks.create('meeting', due: now.add(const Duration(hours: 4)));
    await session.handle('postpone meeting by 2h');
    expect(
        (await tasks.get(task.id))!.dueAt, now.add(const Duration(hours: 6)));
  });
}
