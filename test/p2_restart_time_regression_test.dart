import 'dart:convert';

import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/assistant/authorization.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backend_test.dart' show FakeMemory;
import 'support/v2_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('startup recovery preserves the committed reminder time after clock advances', () async {
    final db = await openMigratedV2();
    var now = DateTime(2099, 10, 19, 10);
    final originalTime = now.add(const Duration(minutes: 10));
    final tasks = TaskRepo(db);
    final reminders = ReminderRepo(db);
    final memory = FakeMemory();
    final prefs = ReminderPreferencesRepo(db);
    await prefs.save(const ReminderPreferences());
    final journal = OperationJournal(db);
    final tools = ToolExecutor(tasks, reminders, memory, NoopScheduler(),
        clock: () => now, preferences: prefs);
    const message = 'remind me in 10 minutes to take medicine';
    const op = 'restart-committed-time';
    final call = ToolCall('create_reminder', {'title': 'take medicine', 'at': originalTime});
    final plan = CandidatePlan(
      interpreter: Interpreter.unified, route: RouteId.rules, call: call,
      evidence: const {'title': 'said', 'time': 'resolved'},
      authorization: const AuthorizationReading(Authorization.request, 'cue'),
    );
    await journal.begin(op, 'restart-time',
        sha256.convert(utf8.encode(message)).toString().substring(0, 16));
    await journal.mark(op, OperationJournal.executing, action: plan.toActionJson());
    await tools.run(call, operationId: op);
    // The process dies after the write but before storing its receipt.
    await journal.recoverStale(olderThan: Duration.zero);
    now = now.add(const Duration(minutes: 5));
    final session = AssistantSession(
      engine: RuleEngine(clock: () => now), tools: tools, memory: memory,
      profile: ProfileRepo(db), taskRepo: tasks, conversations: ConversationRepo(db),
      pending: PendingRepo(db), operations: journal, conversationId: 'restart-time',
      clock: () => now, interpreter: Interpreter.unified,
    );
    await session.start();
    addTearDown(session.close);
    final reply = await session.handle(message, operationId: op);
    final saved = (await reminders.byOperation(op)).single;
    expect(saved.triggerAt, originalTime);
    expect(session.lastTurn!.main!.at, saved.triggerAt,
        reason: 'the receipt must report the saved time, not submission + a fresh duration: $reply');
    expect(reply, contains('10:10 AM'));
  });

  test('startup recovery after original time passed produces no duplicate alarm or invented delivery claim', () async {
    final db = await openMigratedV2();
    var now = DateTime(2099, 10, 19, 10);
    final originalTime = now.add(const Duration(minutes: 10));
    final tasks = TaskRepo(db);
    final reminders = ReminderRepo(db);
    final memory = FakeMemory();
    final prefs = ReminderPreferencesRepo(db);
    await prefs.save(const ReminderPreferences());
    final journal = OperationJournal(db);
    final scheduler = _Recorder();
    final tools = ToolExecutor(tasks, reminders, memory, scheduler,
        clock: () => now, preferences: prefs);
    const message = 'remind me in 10 minutes to take medicine';
    const op = 'restart-past-time';
    final call = ToolCall('create_reminder', {'title': 'take medicine', 'at': originalTime});
    final plan = CandidatePlan(
      interpreter: Interpreter.unified, route: RouteId.rules, call: call,
      evidence: const {'title': 'said', 'time': 'resolved'},
      authorization: const AuthorizationReading(Authorization.request, 'cue'),
    );
    await journal.begin(op, 'restart-time-past',
        sha256.convert(utf8.encode(message)).toString().substring(0, 16));
    await journal.mark(op, OperationJournal.executing, action: plan.toActionJson());
    await tools.run(call, operationId: op);
    expect(scheduler.scheduled.length, 1);

    // The process dies after the write but before storing its receipt.
    await journal.recoverStale(olderThan: Duration.zero);

    // Clock advances 20 minutes (10 minutes after originalTime passed).
    now = now.add(const Duration(minutes: 20));
    final session = AssistantSession(
      engine: RuleEngine(clock: () => now), tools: tools, memory: memory,
      profile: ProfileRepo(db), taskRepo: tasks, conversations: ConversationRepo(db),
      pending: PendingRepo(db), operations: journal, conversationId: 'restart-time-past',
      clock: () => now, interpreter: Interpreter.unified,
    );
    await session.start();
    addTearDown(session.close);

    final reply = await session.handle(message, operationId: op);
    final savedList = await reminders.byOperation(op);
    expect(savedList.length, 1, reason: 'must not insert duplicate reminder rows');
    final saved = savedList.single;
    expect(saved.triggerAt, originalTime);
    expect(session.lastTurn!.main!.at, saved.triggerAt,
        reason: 'the receipt must report stored time, not newly computed time');
    expect(session.lastTurn!.main!.alarm, AlarmStatus.none,
        reason: 'no alarm scheduled for a passed time');
    expect(session.lastTurn!.main!.status, ReceiptStatus.replayed);
    expect(scheduler.scheduled.length, 1, reason: 'must not schedule a new or duplicate alarm');

    expect(reply, contains('already saved'));
    expect(reply, contains('10:10 AM'));
    expect(reply, isNot(contains("I'll remind you")));
    expect(reply, isNot(contains('I reminded you')));
    expect(reply, isNot(contains('I already reminded you')));
  });

  test('startup recovery at exact trigger boundary treats non-future time as already saved', () async {
    final db = await openMigratedV2();
    var now = DateTime(2099, 10, 19, 10);
    final originalTime = now.add(const Duration(minutes: 10));
    final tasks = TaskRepo(db);
    final reminders = ReminderRepo(db);
    final memory = FakeMemory();
    final prefs = ReminderPreferencesRepo(db);
    await prefs.save(const ReminderPreferences());
    final journal = OperationJournal(db);
    final scheduler = _Recorder();
    final tools = ToolExecutor(tasks, reminders, memory, scheduler,
        clock: () => now, preferences: prefs);
    const message = 'remind me in 10 minutes to take medicine';
    const op = 'restart-exact-boundary';
    final call = ToolCall('create_reminder', {'title': 'take medicine', 'at': originalTime});
    final plan = CandidatePlan(
      interpreter: Interpreter.unified, route: RouteId.rules, call: call,
      evidence: const {'title': 'said', 'time': 'resolved'},
      authorization: const AuthorizationReading(Authorization.request, 'cue'),
    );
    await journal.begin(op, 'restart-time-exact',
        sha256.convert(utf8.encode(message)).toString().substring(0, 16));
    await journal.mark(op, OperationJournal.executing, action: plan.toActionJson());
    await tools.run(call, operationId: op);

    await journal.recoverStale(olderThan: Duration.zero);

    // Clock advances exactly to originalTime (10:10)
    now = originalTime;
    final session = AssistantSession(
      engine: RuleEngine(clock: () => now), tools: tools, memory: memory,
      profile: ProfileRepo(db), taskRepo: tasks, conversations: ConversationRepo(db),
      pending: PendingRepo(db), operations: journal, conversationId: 'restart-time-exact',
      clock: () => now, interpreter: Interpreter.unified,
    );
    await session.start();
    addTearDown(session.close);

    final reply = await session.handle(message, operationId: op);
    expect(session.lastTurn!.main!.at, originalTime);
    expect(session.lastTurn!.main!.alarm, AlarmStatus.none);
    expect(reply, contains('already saved'));
    expect(reply, contains('10:10 AM'));
    expect(reply, isNot(contains("I'll remind you")));
  });

  test('fresh create strictly validates against past times', () async {
    final db = await openMigratedV2();
    final now = DateTime(2099, 10, 19, 10);
    final tasks = TaskRepo(db);
    final reminders = ReminderRepo(db);
    final memory = FakeMemory();
    final prefs = ReminderPreferencesRepo(db);
    final tools = ToolExecutor(tasks, reminders, memory, NoopScheduler(),
        clock: () => now, preferences: prefs);
    final pastCall = ToolCall('create_reminder', {
      'title': 'past reminder',
      'at': now.subtract(const Duration(minutes: 5)),
    });
    expect(
      () => tools.run(pastCall),
      throwsA(isA<ToolError>().having((e) => e.message, 'message', 'Reminder time is in the past.')),
    );
  });
}

class _Recorder extends NoopScheduler {
  final scheduled = <Reminder>[];
  final cancelled = <int>[];

  @override
  Future<void> schedule(Reminder r) async {
    scheduled.add(r);
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }
}
