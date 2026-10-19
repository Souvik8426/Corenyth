import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'backend_test.dart'
    show FakeTasks, FakeReminders, FakeMemory, FakeProfile, FakeConversations;
import 'screenshot_replies_test.dart' show ScriptedEngine;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2099, 10, 19, 7, 41);
  late FakeTasks tasks;
  late FakeReminders reminders;
  late ScriptedEngine model;
  late AssistantSession session;
  setUp(() async {
    tasks = FakeTasks();
    reminders = FakeReminders();
    model = ScriptedEngine();
    final memory = FakeMemory();
    session = AssistantSession(
        engine: model,
        tools: ToolExecutor(tasks, reminders, memory, NoopScheduler(),
            clock: () => now),
        memory: memory,
        profile: FakeProfile(),
        taskRepo: tasks,
        conversations: FakeConversations(),
        clock: () => now);
    await session.start();
    addTearDown(session.close);
  });
  test('model cannot replace requested action with duration words', () async {
    model.outputs[PromptKind.plan] =
        '{"intent":"create_reminder","title":"remind me in 2 hrs","when":"in 2 hrs"}';
    await session.handle('remind me in 2 hrs to take my tablets');
    final r = (await reminders.upcoming()).single;
    expect(r.title, 'take my tablets');
    expect(r.triggerAt, now.add(const Duration(hours: 2)));
  });
  test('model cannot invent today as a filter for an unqualified list',
      () async {
    await tasks.create('renew passport', due: now.add(const Duration(days: 2)));
    model.outputs[PromptKind.plan] = '{"intent":"list","range":"today"}';
    expect(
        await session.handle('what are my tasks?'), contains('renew passport'));
  });
  test('external action request cannot silently create a task', () async {
    model.outputs[PromptKind.plan] =
        '{"intent":"create_task","title":"book me a cab"}';
    final reply = await session.handle('can you book me a cab');
    expect(await tasks.list(), isEmpty);
    expect(await reminders.upcoming(), isEmpty);
    expect(reply, contains("can't"));
  });
  test('same-time move keeps stored clock, not a disclosed day default',
      () async {
    final task =
        await tasks.create('dentist', due: DateTime(2099, 10, 20, 16, 25));
    model.outputs[PromptKind.plan] = '{"intent":"list","range":"today"}';
    await session.handle('move the dentist to thursday same time');
    final moved = (await tasks.get(task.id))!.dueAt!;
    expect((moved.hour, moved.minute), (16, 25));
    expect(moved.weekday, DateTime.thursday);
  });
  test('question about completion reads stored state and never completes',
      () async {
    final task = await tasks.create('buy milk');
    model.outputs[PromptKind.plan] = '{"intent":"complete","ref":"buy milk"}';
    expect(await session.handle('Am I done with buy milk?'),
        contains('still pending'));
    expect((await tasks.get(task.id))!.done, isFalse);
  });
  test('discarded obligation asks before deleting and typed confirmation works',
      () async {
    final task = await tasks.create('buy bread');
    expect(await session.handle("I don't need to buy bread anymore"),
        contains('Should I remove'));
    expect(await tasks.get(task.id), isNotNull);
    await session.handle('#${task.id}');
    expect(await tasks.get(task.id), isNull);
  });
}
