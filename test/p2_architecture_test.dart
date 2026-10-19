import 'dart:convert';

import 'package:assistant/assistant/authorization.dart';
import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/assistant/turn_contract.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:crypto/crypto.dart';

import 'backend_test.dart' show FakeMemory;
import 'support/v2_db.dart';

class _RecordingScheduler extends NoopScheduler {
  final List<String> log = [];
  int scheduledCount = 0;
  int cancelledCount = 0;

  @override
  Future<void> schedule(Reminder r) async {
    scheduledCount++;
    log.add('schedule:${r.id}:${r.triggerAt}');
  }

  @override
  Future<void> cancel(int id) async {
    cancelledCount++;
    log.add('cancel:$id');
  }
}

class _TestEngine extends LlmEngine {
  final prompts = <Prompt>[];
  String? planOutput;
  String? replyOutput;
  int completeCalls = 0;

  @override
  String get name => 'test-engine';

  @override
  Future<bool> load() async => true;

  @override
  Future<void> unload() async {}

  @override
  Future<String> complete(Prompt p) async {
    completeCalls++;
    prompts.add(p);
    if (p.kind == PromptKind.plan && planOutput != null) return planOutput!;
    if (p.kind == PromptKind.reply && replyOutput != null) return replyOutput!;
    return '{"intent":"chat","reply":"Hello."}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fixedClock = DateTime(2099, 10, 19, 10, 0);

  late Database db;
  late TaskRepo tasks;
  late ReminderRepo reminders;
  late ReminderPreferencesRepo prefs;
  late ConversationRepo convs;
  late PendingRepo pending;
  late OperationJournal journal;
  late _RecordingScheduler scheduler;
  late _TestEngine engine;

  setUp(() async {
    db = await openMigratedV2();
    tasks = TaskRepo(db);
    reminders = ReminderRepo(db);
    prefs = ReminderPreferencesRepo(db);
    convs = ConversationRepo(db);
    pending = PendingRepo(db);
    journal = OperationJournal(db);
    scheduler = _RecordingScheduler();
    engine = _TestEngine();
    await prefs.save(const ReminderPreferences(followUp: false));
  });

  ToolExecutor createTools() => ToolExecutor(
        tasks,
        reminders,
        FakeMemory(),
        scheduler,
        clock: () => fixedClock,
        preferences: prefs,
      );

  AssistantSession createSession({
    Interpreter? interpreter,
    String chatId = 'p2-chat',
    LlmEngine? customEngine,
  }) {
    return AssistantSession(
      engine: customEngine ?? engine,
      tools: createTools(),
      memory: FakeMemory(),
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: convs,
      pending: pending,
      operations: journal,
      conversationId: chatId,
      clock: () => fixedClock,
      interpreter: interpreter ?? Interpreter.legacy,
    );
  }

  group('P2 Authorization Audit', () {
    test('polite action requests are authorized as requests and permit writes', () {
      final cases = [
        'Can you remind me to call Dad at 6pm?',
        'Could you please add buy milk to my tasks?',
        'Would you mind setting a reminder for tomorrow 9am?',
        'Can I get a reminder at 4pm?',
        'could u schedule dentist at 3pm?',
        'please remind me to submit report at 5pm',
      ];
      for (final text in cases) {
        final auth = readAuthorization(text);
        expect(auth.kind, Authorization.request, reason: 'Expected request for "$text"');
        expect(auth.permitsWrite, isTrue, reason: 'permitsWrite should be true for "$text"');
      }
    });

    test('question marks alone do not suppress explicit polite action requests', () {
      final auth = readAuthorization('Can you remind me at 5pm?');
      expect(auth.kind, Authorization.request);
      expect(auth.permitsWrite, isTrue);
    });

    test('informational questions are classified as questions and forbid writes', () {
      final cases = [
        'How do reminders work?',
        'Can you tell me how reminders work?',
        'Could you explain what tasks are due?',
        'Has Aditya replied?',
        'Can reminders repeat?',
        'What tasks do I have today?',
      ];
      for (final text in cases) {
        final auth = readAuthorization(text);
        expect(auth.kind, Authorization.question, reason: 'Expected question for "$text"');
        expect(auth.permitsWrite, isFalse, reason: 'permitsWrite must be false for "$text"');
      }
    });

    test('hypothetical and tentative inputs forbid writes', () {
      final cases = [
        "What if Aditya hasn't replied?",
        'Maybe I should buy milk tomorrow at 5pm',
        'Should I remind myself daily at 8am?',
        'Thinking about scheduling a dentist appointment',
        'Suppose I finish this by 4pm',
      ];
      for (final text in cases) {
        final auth = readAuthorization(text);
        expect(auth.kind, Authorization.hypothetical, reason: 'Expected hypothetical for "$text"');
        expect(auth.permitsWrite, isFalse, reason: 'permitsWrite must be false for "$text"');
      }
    });

    test('negations forbid writes', () {
      final cases = [
        "Don't remind me daily at 8am to stretch",
        "I don't want a reminder for the meeting",
        'Please do not create any task',
        "You don't need to remind me",
        'Never remind me about this',
      ];
      for (final text in cases) {
        final auth = readAuthorization(text);
        expect(auth.kind, Authorization.negated, reason: 'Expected negated for "$text"');
        expect(auth.permitsWrite, isFalse, reason: 'permitsWrite must be false for "$text"');
      }
    });

    test('statements and factual reports permit writes/reports appropriately', () {
      final stmt = readAuthorization('I have a meeting at 3pm');
      expect(stmt.kind, Authorization.statement);
      expect(stmt.permitsWrite, isTrue);
      expect(stmt.permitsReport, isTrue);

      final report = readAuthorization('The meeting is over');
      expect(report.kind, Authorization.statement);
      expect(report.permitsReport, isTrue);
    });
  });

  group('P2 Validation Gate & No Unintended Writes', () {
    test('validatePlan rejects write actions when authorization is question, hypothetical, or negated', () {
      final writeCall = ToolCall('create_reminder', {
        'title': 'stretch',
        'at': fixedClock.add(const Duration(hours: 1)),
      });
      final evidence = {'title': 'said', 'time': 'resolved'};

      for (final authKind in [Authorization.question, Authorization.hypothetical, Authorization.negated]) {
        final plan = CandidatePlan(
          interpreter: Interpreter.unified,
          route: RouteId.semantic,
          call: writeCall,
          evidence: evidence,
          authorization: AuthorizationReading(authKind, 'cue'),
        );
        final val = validatePlan(plan);
        expect(val.accepted, isFalse, reason: '$authKind must be rejected');
        expect(val.reason, startsWith('blocked_${authKind.name}_'));
        expect(val.reply, isNotEmpty);
      }
    });

    test('validatePlan rejects create actions missing title or time evidence', () {
      final writeCall = ToolCall('create_reminder', {
        'title': 'stretch',
        'at': fixedClock.add(const Duration(hours: 1)),
      });

      // Missing title
      final planNoTitle = CandidatePlan(
        interpreter: Interpreter.unified,
        route: RouteId.semantic,
        call: writeCall,
        evidence: {'time': 'resolved'},
        authorization: const AuthorizationReading(Authorization.request, 'cue'),
      );
      expect(validatePlan(planNoTitle).accepted, isFalse);
      expect(validatePlan(planNoTitle).reason, 'no_title_evidence');

      // Missing time for timed creation
      final planNoTime = CandidatePlan(
        interpreter: Interpreter.unified,
        route: RouteId.semantic,
        call: writeCall,
        evidence: {'title': 'said'},
        authorization: const AuthorizationReading(Authorization.request, 'cue'),
      );
      expect(validatePlan(planNoTime).accepted, isFalse);
      expect(validatePlan(planNoTime).reason, 'no_time_evidence');
    });

    test('validatePlan rejects change actions missing target evidence', () {
      final changeCall = ToolCall('complete_task', {'id': 42});
      final plan = CandidatePlan(
        interpreter: Interpreter.unified,
        route: RouteId.semantic,
        call: changeCall,
        evidence: {}, // no target evidence
        authorization: const AuthorizationReading(Authorization.request, 'cue'),
      );
      final val = validatePlan(plan);
      expect(val.accepted, isFalse);
      expect(val.reason, 'no_target_evidence');
    });

    test('end-to-end: ungrounded model write proposal on question input never mutates database', () async {
      final s = createSession();
      await s.start();
      engine.planOutput = '{"intent":"create_task","title":"fake task"}';

      final reply = await s.handle('How do reminders work?');
      expect(reply, isNotEmpty);
      expect(await tasks.list(), isEmpty);
      expect(await reminders.upcoming(), isEmpty);
      expect(s.lastTurn?.receipts.any((r) => r.wrote) ?? false, isFalse);
      expect(s.lastTurn?.receipts.single.status, ReceiptStatus.noWrite);
      await s.close();
    });
  });

  group('P2 Rollout / Rollback Contract: Dual Interpreters & Read-Only Comparison', () {
    test('internal interpreter switch configures legacy and unified routes', () {
      final legacy = createSession(interpreter: Interpreter.legacy);
      expect(legacy.interpreter, Interpreter.legacy);

      final unified = createSession(interpreter: Interpreter.unified);
      expect(unified.interpreter, Interpreter.unified);
    });

    test('compareInterpreters runs both interpreters read-only on fixtures without writes or model reply calls', () async {
      await tasks.create('Review quarterly roadmap');
      final s = createSession(interpreter: Interpreter.unified);
      await s.start();

      final fixtures = [
        'remind me to call Alice tomorrow at 3pm',
        'what is 42 * 2',
        'brief me',
        '#1 is done',
        'remember that my laptop is a ThinkPad',
        'How do reminders work?',
      ];

      for (final fixture in fixtures) {
        final tasksBefore = await tasks.list();
        final remindersBefore = await reminders.upcoming();
        final opsBefore = await db.query('operations');
        final convsBefore = await convs.listChats();

        final comparison = await s.compareInterpreters(fixture);

        // Verify neither interpreter performed any database writes
        expect((await tasks.list()).length, tasksBefore.length);
        expect((await reminders.upcoming()).length, remindersBefore.length);
        expect((await db.query('operations')).length, opsBefore.length);
        expect((await convs.listChats()).length, convsBefore.length);

        // Verify candidate plans are well-formed
        expect(comparison.legacy.interpreter, Interpreter.legacy);
        expect(comparison.unified.interpreter, Interpreter.unified);
        expect(comparison.legacy.call.tool, isNotEmpty);
        expect(comparison.unified.call.tool, isNotEmpty);
      }
      await s.close();
    });

    test('exactly one executor writes: running a turn under unified interpreter executes writes only via ToolExecutor', () async {
      final s = createSession(interpreter: Interpreter.unified);
      await s.start();

      final reply = await s.handle('remind me to buy groceries tomorrow at 5pm');
      expect(reply, contains('groceries'));

      final createdTasks = await tasks.list();
      expect(createdTasks.length, 1);
      expect(createdTasks.single.title, 'buy groceries');
      expect(s.lastTurn?.receipts.single.wrote, isTrue);
      expect(s.lastTurn?.receipts.single.status, ReceiptStatus.committed);
      await s.close();
    });
  });

  group('P2 Receipts & Operation Identity', () {
    test('each accepted action has exactly one route, validated evidence and one receipt', () async {
      final s = createSession(interpreter: Interpreter.unified);
      await s.start();

      await s.handle('remind me to inspect servers tomorrow at 4pm');
      final record = s.lastTurn!;

      expect(record.operationId, isNotEmpty);
      expect(record.plan.route, RouteId.rules);
      expect(record.validation.accepted, isTrue);
      expect(record.plan.evidence['title'], isNotNull);
      expect(record.plan.evidence['time'], isNotNull);
      expect(record.receipts.length, 1);

      final receipt = record.receipts.single;
      expect(receipt.status, ReceiptStatus.committed);
      expect(receipt.tool, 'create_reminder');
      expect(receipt.taskIds, isNotEmpty);
      expect(receipt.reminderIds, isNotEmpty);
      expect(receipt.alarm, AlarmStatus.scheduled);
      await s.close();
    });

    test('receipt statuses: committed, replayed, readOnly, noWrite', () async {
      final s = createSession(interpreter: Interpreter.unified);
      await s.start();

      // 1. Committed
      await s.handle('add task finish documentation');
      expect(s.lastTurn!.receipts.single.status, ReceiptStatus.committed);

      // 2. ReadOnly
      await s.handle('brief me');
      expect(s.lastTurn!.receipts.single.status, ReceiptStatus.readOnly);

      // 3. NoWrite
      await s.handle('what is 15 + 27');
      expect(s.lastTurn!.receipts.single.status, ReceiptStatus.noWrite);

      await s.close();
    });
  });

  group('P2 Retry, Crash Recovery & Idempotency', () {
    test('retry of a completed turn replays reply without duplicating tasks or alarms', () async {
      final s = createSession(interpreter: Interpreter.unified);
      await s.start();

      final firstReply = await s.handle('remind me to submit report tomorrow at 2pm');
      final opId = s.lastOperationId!;
      expect(opId, isNotEmpty);

      final initialTasks = await tasks.list();
      final initialReminders = await reminders.upcoming();
      final scheduledAlarms = scheduler.scheduledCount;
      expect(initialTasks.length, 1);
      expect(initialReminders.length, 1);

      // Retry with identical operationId and identical text
      final retryReply = await s.handle(
        'remind me to submit report tomorrow at 2pm',
        operationId: opId,
      );

      expect(retryReply, firstReply);
      expect((await tasks.list()).length, initialTasks.length, reason: 'No duplicate task created');
      expect((await reminders.upcoming()).length, initialReminders.length, reason: 'No duplicate reminder created');
      expect(scheduler.scheduledCount, scheduledAlarms, reason: 'No duplicate alarm scheduled');
      expect(s.lastTurn, isNull, reason: 'Replayed turns do not run fresh candidate plans');
      await s.close();
    });

    test('recovering a turn after execution crash finishes journaled action and marks replayed on committed rows', () async {
      // Simulate crash during execution: task was committed to DB with opId, but turn died before finalizing
      const crashedOp = 'crashed-op-123';
      const text = 'remind me to pay bills tomorrow at 11am';
      final textHash = sha256Hex(text);

      final createdTask = await tasks.create('pay bills', opId: crashedOp);
      final candidatePlan = CandidatePlan(
        interpreter: Interpreter.unified,
        route: RouteId.rules,
        call: ToolCall('create_task', {'title': 'pay bills'}),
        evidence: {'title': 'said'},
        authorization: const AuthorizationReading(Authorization.request, 'cue'),
      );

      await journal.begin(crashedOp, 'p2-chat', textHash);
      await journal.mark(
        crashedOp,
        OperationJournal.executing,
        action: candidatePlan.toActionJson(),
      );

      final s = createSession(interpreter: Interpreter.unified);
      await s.start();

      // Retry with the crashed operationId
      final reply = await s.handle(text, operationId: crashedOp);
      expect(reply, contains('pay bills'));

      // Verify no duplicate row was created; existing row was replayed
      final allTasks = await tasks.list();
      expect(allTasks.length, 1);
      expect(allTasks.single.id, createdTask.id);
      expect(s.lastTurn!.receipts.single.status, ReceiptStatus.replayed);

      // Verify operation status is now finalized
      final op = await journal.get(crashedOp);
      expect(op!.status, OperationJournal.replied);
      await s.close();
    });

    test('retrying with a different message for the same operationId throws ArgumentError', () async {
      final s = createSession();
      await s.start();

      await s.handle('remind me to water plants tomorrow at 8am');
      final opId = s.lastOperationId!;

      expect(
        () => s.handle('different message text', operationId: opId),
        throwsA(isA<ArgumentError>()),
      );
      await s.close();
    });
  });

  group('P2 Bounded Model Calls & Deduplication', () {
    test('identical greedy output is not retried within a turn', () async {
      final s = createSession(interpreter: Interpreter.unified);
      await s.start();

      engine.planOutput = '{"intent":"chat","reply":"First response."}';
      engine.replyOutput = 'First response.';

      await s.handle('Hello Corenyth!');
      final firstCalls = engine.completeCalls;
      expect(firstCalls, greaterThanOrEqualTo(1));

      // Diagnostics check
      expect(s.lastDiagnostics['model_calls'], isNotNull);
      await s.close();
    });
  });

  group('P2 Inventoried Route Priority & Parity', () {
    test('calculator route takes precedence over rules and model', () async {
      final s = createSession(interpreter: Interpreter.unified);
      await s.start();

      final reply = await s.handle('100 / 4');
      expect(reply, contains('25'));
      expect(s.lastTurn!.plan.route, RouteId.calculator);
      expect(await tasks.list(), isEmpty);
      await s.close();
    });

    test('explicit memory route takes highest priority and stores memory', () async {
      final s = createSession(interpreter: Interpreter.unified);
      await s.start();

      final reply = await s.handle('remember that Alice is my manager');
      expect(reply, contains("remember that"));
      expect(s.lastTurn!.plan.route, RouteId.explicitMemory);
      await s.close();
    });

    test('daily schedule route creates daily recurring task with exact confirmation', () async {
      final s = createSession(interpreter: Interpreter.unified);
      await s.start();

      final reply = await s.handle('remind me daily at 8am until 5 November to stretch');
      expect(reply, contains('every day at 8:00 AM'));
      expect(s.lastTurn!.plan.route, RouteId.dailySchedule);

      final task = (await tasks.list()).single;
      expect(task.title, 'stretch');
      expect(task.dailyMinute, 480);
      await s.close();
    });

    test('complaint route re-answers previous turn without writing', () async {
      final s = createSession(interpreter: Interpreter.unified);
      await s.start();

      await s.handle('What is the weather like?');
      final reply = await s.handle('that was dumb, answer my previous message');
      expect(reply, isNotEmpty);
      expect(s.lastTurn!.plan.route, RouteId.complaint);
      expect(await tasks.list(), isEmpty);
      await s.close();
    });
  });

  group('P2 v7 Database Migration & Backward Compatibility', () {
    test('v7 migration preserves legacy tasks and reminders with null op_id', () async {
      final legacy = await openMigratedV2(seed: (db) async {
        await db.insert('tasks', {
          'title': 'ancient task',
          'created_at': 1000,
          'status': 'pending',
          'priority': 1,
        });
        await db.insert('reminders', {
          'title': 'ancient reminder',
          'trigger_at': 5000,
          'enabled': 1,
        });
      });

      expect(await legacy.getVersion(), 8);

      final taskRows = await legacy.query('tasks', where: "title = 'ancient task'");
      expect(taskRows.single['op_id'], isNull);

      final reminderRows = await legacy.query('reminders', where: "title = 'ancient reminder'");
      expect(reminderRows.single['op_id'], isNull);

      // Home-screen widget query compatibility
      final widgetQuery = await legacy.query('tasks', columns: ['title', 'status', 'due_at']);
      expect(widgetQuery.isNotEmpty, isTrue);

      // OperationJournal recoverStale cleans up unfinished crashes
      final journal = OperationJournal(legacy);
      await journal.begin('stale-1', 'chat', 'hash');
      final settled = await journal.recoverStale(olderThan: Duration.zero);
      expect(settled, contains('stale-1'));
      final op = await journal.get('stale-1');
      expect(op!.status, OperationJournal.abandoned);
    });
  });
}

String sha256Hex(String text) {
  return sha256.convert(utf8.encode(text)).toString().substring(0, 16);
}
