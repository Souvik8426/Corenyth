import 'dart:convert';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backend_test.dart'
    show FakeTasks, FakeReminders, FakeMemory, FakeProfile, FakeConversations;
import 'screenshot_replies_test.dart' show ScriptedEngine;

/// P0 baseline regression for the reported screenshot (corpus case S-001).
/// Written before any parser change: expected to FAIL at c1d1ada ("within"
/// is not a duration form, so the app asks when). P1 must turn it green
/// without editing these expectations.
void main() {
  const request = 'Can u remind me i have a meeting within 10 mins';
  final now = DateTime(2026, 10, 19, 7, 41); // plan §6 fixed time, local
  final due = DateTime(2026, 10, 19, 7, 51);

  late FakeReminders reminders;
  Future<AssistantSession> open(LlmEngine engine) async {
    final tasks = FakeTasks();
    reminders = FakeReminders();
    final memory = FakeMemory();
    final s = AssistantSession(
      engine: engine,
      tools: ToolExecutor(tasks, reminders, memory, NoopScheduler(),
          clock: () => now),
      memory: memory,
      profile: FakeProfile(),
      taskRepo: tasks,
      conversations: FakeConversations(),
      clock: () => now,
    );
    await s.start();
    addTearDown(s.close);
    return s;
  }

  Future<void> expectOneCleanReminder(String reply) async {
    final l = await reminders.upcoming();
    expect(l, hasLength(1), reason: 'reply was: $reply');
    expect(l.single.triggerAt, due);
    final title = l.single.title.toLowerCase();
    expect(title, contains('meeting'));
    for (final filler in ['within', '10', 'min', 'i have', 'can u']) {
      expect(title, isNot(contains(filler)));
    }
    expect(reply, isNot(contains(RuleEngine.supportedWhen)));
    expect(reply.toLowerCase(), isNot(contains('when should')));
  }

  test('model unavailable: rules alone schedule submission + 10 minutes',
      () async {
    final s = await open(RuleEngine(clock: () => now));
    await expectOneCleanReminder(await s.handle(request));
  });

  test('valid Qwen extraction ("within 10 mins") schedules the same',
      () async {
    final model = ScriptedEngine();
    model.outputs[PromptKind.plan] = jsonEncode({
      'intent': 'create_reminder',
      'title': 'meeting',
      'when': 'within 10 mins',
    });
    final s = await open(model);
    await expectOneCleanReminder(await s.handle(request));
  });
}
