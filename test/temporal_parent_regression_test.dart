import 'dart:convert';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backend_test.dart' show FakeMemory;
import 'screenshot_replies_test.dart' show ScriptedEngine;
import 'support/v2_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 10, 19, 7, 41);
  for (final modelAvailable in [false, true]) {
    for (final (request, title, timeWords) in [
      ('remind me in 2 weeks at 5pm to call Mum', 'call Mum', 'at 5pm'),
      ('remind me every 2 hours at 5pm to drink water', 'drink water', 'at 5pm'),
      ('remind me in 10 minutes on 30 February to call Mum', 'call Mum', 'in 10 minutes'),
      ('remind me in 1 hour and 2 hours to call Mum', 'call Mum', 'in 1 hour'),
      ('remind me tomorrow Friday at 5pm to call Mum', 'call Mum', 'tomorrow at 5pm'),
    ]) {
      test('P1 parent: no partial time write ($modelAvailable): $request', () async {
        final db = await openMigratedV2();
        final tasks = TaskRepo(db);
        final reminders = ReminderRepo(db);
        final memory = FakeMemory();
        final model = ScriptedEngine();
        model.outputs[PromptKind.plan] = jsonEncode({
          'intent': 'create_reminder', 'title': title, 'when': timeWords,
        });
        final session = AssistantSession(
          engine: modelAvailable ? model : RuleEngine(clock: () => now),
          tools: ToolExecutor(tasks, reminders, memory, NoopScheduler(),
              clock: () => now, preferences: ReminderPreferencesRepo(db)),
          memory: memory,
          profile: ProfileRepo(db),
          taskRepo: tasks,
          conversations: ConversationRepo(db),
          pending: PendingRepo(db),
          clock: () => now,
        );
        await session.start();
        addTearDown(session.close);
        final reply = await session.handle(request);
        expect(await tasks.list(includeDone: true), isEmpty, reason: reply);
        expect(await db.query('reminders'), isEmpty, reason: reply);
      });
    }
  }
}
