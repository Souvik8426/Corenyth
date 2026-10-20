import 'dart:convert';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/follow_through.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backend_test.dart'
    show FakeTasks, FakeReminders, FakeMemory, FakeProfile, FakeConversations;
import 'screenshot_replies_test.dart' show ScriptedEngine;

/// The model's own voice: one plan call carries the toned `reply`, the app
/// confirms facts itself and appends the model's follow-up after them.
void main() {
  late FakeTasks tasks;
  late ScriptedEngine model;
  late AssistantSession session;
  setUp(() async {
    tasks = FakeTasks();
    model = ScriptedEngine();
    session = AssistantSession(
      engine: model,
      tools: ToolExecutor(tasks, FakeReminders(), FakeMemory(), NoopScheduler()),
      memory: FakeMemory(),
      profile: FakeProfile(),
      taskRepo: tasks,
      conversations: FakeConversations(),
    );
    await session.start();
    addTearDown(session.close);
  });

  void plan(Map<String, Object?> p) =>
      model.outputs[PromptKind.plan] = jsonEncode(p);

  test('a created reminder ends with the model follow-up, in one call',
      () async {
    plan({
      'intent': 'create_reminder',
      'title': 'call Kabir',
      'when': 'tomorrow at 6pm',
      'reply': "What's the call about?"
    });
    final reply = await session.handle('Remind me to call Kabir tomorrow at 6pm');
    expect(reply, contains('call Kabir'));
    expect(reply, endsWith("What's the call about?"));
    expect(model.calls, 1);
    expect(session.lastDiagnostics['route'], 'semantic');
    expect(session.lastDiagnostics['reply'], 'model_line');
  });

  test('a follow-up stating a time is dropped; the app confirmation stands',
      () async {
    plan({
      'intent': 'create_reminder',
      'title': 'call Kabir',
      'when': 'tomorrow at 6pm',
      'reply': 'Talk to you at 7pm!'
    });
    final reply = await session.handle('Remind me to call Kabir tomorrow at 6pm');
    expect(reply, contains('call Kabir'));
    expect(reply, isNot(contains('7pm')));
  });

  test('a task the model picks by #id from Current tasks is accepted',
      () async {
    final milk = await tasks.create('buy milk');
    plan({'intent': 'complete', 'ref': '#${milk.id}', 'reply': 'Nice one!'});
    final reply = await session.handle('Mark buy milk as done');
    expect((await tasks.get(milk.id))!.done, isTrue);
    expect(session.lastDiagnostics['route'], 'semantic');
    expect(session.lastDiagnostics['fallback'], isNull);
    expect(reply, endsWith('Nice one!'));
  });

  test('a model-picked #id whose task the message does not name is refused',
      () async {
    final milk = await tasks.create('buy milk');
    await tasks.create('call Kabir');
    plan({'intent': 'complete', 'ref': '#${milk.id}', 'reply': 'Done!'});
    await session.handle('Mark call Kabir as done');
    expect((await tasks.get(milk.id))!.done, isFalse);
  });

  test('a meeting with a day but no time asks the time, then keeps the day',
      () async {
    plan({
      'intent': 'create_task',
      'title': 'meeting',
      'when': 'tomorrow',
      'reply': "Ooh, what's the meeting about?"
    });
    final ask = await session.handle('I have a meeting tomorrow');
    expect(ask, startsWith('What time is "meeting" on'));
    expect(tasks.rows, isEmpty, reason: 'no 9 AM guess');
    final done = await session.handle('3pm');
    expect(done, contains('tomorrow'));
    expect(done, contains('3:00 PM'));
    final due = (await tasks.list()).single.dueAt!;
    expect(due.hour, 15);
    expect(due.day, DateTime.now().add(const Duration(days: 1)).day);
  });

  test('the time answer may carry the topic; the meeting stores both',
      () async {
    plan({
      'intent': 'create_task',
      'title': 'meeting',
      'when': 'tomorrow',
      'reply': "Ooh, what's the meeting about?"
    });
    final ask = await session.handle('I have a meeting tomorrow');
    expect(ask, endsWith("Ooh, what's the meeting about?"));
    await session.handle("3pm, it's about the budget");
    final t = (await tasks.list()).single;
    expect(t.dueAt!.hour, 15);
    expect(t.subject, 'the budget');
  });

  test('a model ref with id and title ("#4 water the plants") is accepted',
      () async {
    final plants = await tasks.create('water the plants',
        due: DateTime.now().add(const Duration(hours: 3)));
    plan({
      'intent': 'postpone',
      'ref': '#${plants.id} water the plants',
      'when': 'in 30 minutes',
      'reply': 'No rush!'
    });
    final before = plants.dueAt!;
    await session.handle('Postpone water the plants by 30 minutes');
    expect(session.lastDiagnostics['route'], 'semantic');
    expect(session.lastDiagnostics['fallback'], isNull);
    expect((await tasks.get(plants.id))!.dueAt,
        before.add(const Duration(minutes: 30)));
  });

  test('a ref naming nothing falls back to the task the message names',
      () async {
    final bill = await tasks.create('pay the electricity bill',
        due: DateTime.now().add(const Duration(hours: 3)));
    plan({
      'intent': 'postpone',
      'title': 'postpone',
      'when': '1 hour',
      'reply': 'No rush!'
    });
    await session.handle('Postpone pay the electricity bill by 1 hour');
    expect((await tasks.get(bill.id))!.dueAt,
        bill.dueAt!.add(const Duration(hours: 1)));
  });

  test('postpone reads the last "by" in the message, not "for mom"',
      () async {
    final gift = await tasks.create('buy a gift for mom',
        due: DateTime.now().add(const Duration(hours: 3)));
    plan({
      'intent': 'postpone',
      'ref': '#${gift.id}',
      'when': 'Tue 2026-10-20T01:30',
      'reply': 'No rush!'
    });
    await session.handle('Postpone buy a gift for mom by 1 hour');
    expect((await tasks.get(gift.id))!.dueAt,
        gift.dueAt!.add(const Duration(hours: 1)));
  });

  test('an add command is never applied as complete', () async {
    final room = await tasks.create('clean my room');
    plan({'intent': 'complete', 'ref': 'clean my room', 'reply': 'Nice!'});
    await session.handle('Add a task to clean my room');
    expect((await tasks.get(room.id))!.done, isFalse);
  });

  test('the plan prompt carries the profile tone next to the message', () {
    final p = Prompt(PromptKind.plan, 'hi', tone: 'playful');
    expect(p.render(), contains('Reply tone: playful (witty and teasing'));
  });

  group('isSafeFollowUp', () {
    test('allows warm prose and questions', () {
      expect(isSafeFollowUp("What's the meeting about?", 'I have a meeting'),
          isTrue);
      expect(isSafeFollowUp('Nice work! 🎉', 'mark it done'), isTrue);
    });
    test('blocks facts the app owns and parroting', () {
      expect(isSafeFollowUp('See you tomorrow morning!', 'x'), isFalse);
      expect(isSafeFollowUp('It is at 5.', 'x'), isFalse);
      expect(isSafeFollowUp("What's the time you need to pay?", 'x'), isFalse);
      expect(isSafeFollowUp("I've set the reminder.", 'x'), isFalse);
      expect(
          isSafeFollowUp('remind me to call kabir', 'remind me to call kabir'),
          isFalse);
    });
  });
}
