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
  late FakeTasks tasks;
  late FakeMemory memory;
  late SpyEngine model;
  late AssistantSession session;
  setUp(() async {
    tasks = FakeTasks();
    memory = FakeMemory();
    model = SpyEngine();
    session = AssistantSession(
      engine: model,
      tools: ToolExecutor(tasks, FakeReminders(), memory, NoopScheduler()),
      memory: memory,
      profile: FakeProfile(),
      taskRepo: tasks,
      conversations: FakeConversations(),
    );
    await session.start();
    addTearDown(session.close);
  });

  test('the exact screenshot phrase completes buy milk and leaves bring milk',
      () async {
    final buy = await tasks.create('buy milk');
    final bring = await tasks.create('bring milk');
    model.output =
        jsonEncode({'type': 'tool', 'tool': 'list_tasks', 'arguments': {}});
    final reply = await session.handle('Okay i am done with buying milk');
    expect((await tasks.get(buy.id))!.done, isTrue);
    expect((await tasks.get(bring.id))!.done, isFalse);
    expect((await tasks.list()).map((t) => t.id), [bring.id]);
    expect(reply.toLowerCase(), contains('done'));
    expect(model.calls, greaterThan(0)); // model-first; invalid plan -> rules
    expect(memory.items, isEmpty);
  });

  test('a duplicate completion asks which task and respects the chosen number',
      () async {
    final one = await tasks.create('buy milk');
    final two = await tasks.create('buy milk');
    final reply = await session.handle('Okay i am done with buying milk');
    expect(reply.toLowerCase(), contains('which one'));
    expect((await tasks.list()).length, 2);
    await session.handle('#${two.id}');
    expect((await tasks.get(one.id))!.done, isFalse);
    expect((await tasks.get(two.id))!.done, isTrue);
  });

  test('a model cannot turn completion questions or hypotheticals into writes',
      () async {
    final task = await tasks.create('buy milk');
    model.output = jsonEncode({
      'type': 'tool',
      'tool': 'complete_task',
      'arguments': {'title': 'buy milk'},
    });
    for (final text in [
      'Am I done with buy milk?',
      'I am done with buy milk?',
      'If I am done with buy milk, what next?',
    ]) {
      await session.handle(text);
      expect((await tasks.get(task.id))!.done, isFalse, reason: text);
    }
  });
}
