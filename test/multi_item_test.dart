import 'dart:convert';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/v2_db.dart';

final _now = DateTime(2099, 10, 30, 10);
const _paste = '''Add these tasks: **Due soon**
- Sachiv V1 — tomorrow
- SurveyMonkey credits — until Nov 19
- Post on X and Instagram — today 5 PM
**Waiting on you**
- Aditya's update — already tracked
- Jaydeb's ₹60 — waiting for your answer
**Coming up**
- Dispose of the covers — daily at 9 AM and 6 PM''';

class _Memory extends MemoryRepo {
  _Memory(super.db);
  @override
  Future<List<Memory>> search(String query, {int limit = 3}) async => [];
  @override
  Future<List<Memory>> important({int limit = 3}) async => [];
}

class _Model extends LlmEngine {
  final prompts = <Prompt>[];
  String output = '{"intent":"chat","reply":"Okay."}';
  bool reject = false;
  @override
  String get name => 'batch-test-model';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}
  @override
  Future<String> complete(Prompt p) async {
    prompts.add(p);
    if (reject) throw PlatformException(code: 'prompt_too_long');
    return output;
  }
}

class _Scheduler extends NoopScheduler {
  int syncs = 0;
  @override
  Future<List<int>> syncPending(ReminderRepo repo) async {
    syncs++;
    return super.syncPending(repo);
  }
}

late Database db;
late TaskRepo tasks;
late ReminderRepo reminders;
late PendingRepo pending;
late _Memory _memory;
late _Model _model;
late _Scheduler _scheduler;
late ToolExecutor executor;

Future<AssistantSession> _open(
    {String id = 'batch-chat',
    DateTime? now,
    Interpreter interpreter = Interpreter.unified}) async {
  final session = AssistantSession(
    engine: _model,
    tools: executor,
    memory: _memory,
    profile: ProfileRepo(db),
    taskRepo: tasks,
    conversations: ConversationRepo(db),
    pending: pending,
    operations: OperationJournal(db),
    conversationId: id,
    clock: () => now ?? _now,
    interpreter: interpreter,
  );
  await session.start();
  addTearDown(session.close);
  return session;
}

Future<void> _seedTracked() async {
  await tasks.create('call aditya');
}

Map<String, Object?> _item(int index, String title) => {
      'index': index,
      'tool': 'create_task',
      'arguments': {'title': title},
    };

void main() {
  setUp(() async {
    db = await openMigratedV2();
    tasks = TaskRepo(db);
    reminders = ReminderRepo(db);
    pending = PendingRepo(db);
    _memory = _Memory(db);
    _model = _Model();
    _scheduler = _Scheduler();
    executor =
        ToolExecutor(tasks, reminders, _memory, _scheduler, clock: () => _now);
  });

  for (final mode in Interpreter.values) {
    test('B1 digest previews classes before whole-message routes ($mode)',
        () async {
      await _seedTracked();
      final session = await _open(interpreter: mode);
      final reply = await session.handle(
          "${_paste.replaceFirst('Add these tasks: ', '')}\n- don't notify me about gym");
      expect(
          reply,
          allOf(
              contains('I found 7 items'),
              contains('Already tracked:'),
              contains('Not added:'),
              contains('negated'),
              contains('daily at')));
      expect((await tasks.list()).length, 1);
      expect(await reminders.upcoming(), isEmpty);
      expect(session.lastTurn!.plan.route, isNot(RouteId.negatedCancel));
      expect(await pending.get('batch:batch-chat'), isNotNull);
      expect(_model.prompts, isEmpty);
    });
  }

  test('B2 explicit paste previews five entries without writes', () async {
    await _seedTracked();
    final session = await _open();
    final reply = await session.handle(_paste);
    expect(
        reply,
        'I found 6 items. I\'ll add:\n'
        '1. Sachiv V1 — due ${shortDate(DateTime(2099, 10, 31))}\n'
        '2. SurveyMonkey credits — until ${shortDate(DateTime(2099, 11, 19))}\n'
        '3. Post on X and Instagram — today 5:00 PM\n'
        '4. Dispose of the covers — daily at 9:00 AM\n'
        '5. Dispose of the covers — daily at 6:00 PM\n'
        "Already tracked: Aditya's update (#1 call aditya)\n"
        "Not added: Jaydeb's ₹60 is waiting for your answer (a question, not a task)\n"
        'Say "yes" to add all 5, "only 1 and 3", or "no".');
    expect((await tasks.list()).length, 1);
    expect(await reminders.upcoming(), isEmpty);
    expect(_model.prompts, isEmpty);
  });

  test('B3 yes saves three tasks and two daily schedules in one operation',
      () async {
    await _seedTracked();
    final session = await _open();
    await session.handle(_paste);
    final reply = await session.handle('yes', operationId: 'batch-yes');
    final saved =
        (await tasks.list()).where((t) => t.title != 'call aditya').toList();
    expect(saved, hasLength(5));
    expect(saved.where((t) => t.dailyMinute == null), hasLength(3));
    expect(saved.map((t) => t.dailyMinute).whereType<int>(),
        unorderedEquals([540, 1080]));
    expect((await reminders.upcoming()).length, 2);
    expect(_scheduler.syncs, 1);
    for (var i = 1; i <= 5; i++) {
      expect(await tasks.byOperation('batch-yes#$i'), hasLength(1));
    }
    expect((await tasks.get(1))!.title, 'call aditya');
    expect((await tasks.get(1))!.done, isFalse);
    expect(session.lastTurn!.receipts, hasLength(1));
    expect(reply, allOf(contains('Saved 5 items'), contains('task #')));
    expect(await pending.get('batch:batch-chat'), isNull);
  });

  test('B4 only 1 and 3 keeps preview indices', () async {
    await _seedTracked();
    final session = await _open();
    await session.handle(_paste);
    await session.handle('only 1 and 3', operationId: 'subset');
    expect(
        (await tasks.list()).map((t) => t.title),
        unorderedEquals(
            ['call aditya', 'Sachiv V1', 'Post on X and Instagram']));
    expect(await tasks.byOperation('subset#1'), hasLength(1));
    expect(await tasks.byOperation('subset#2'), isEmpty);
    expect(await tasks.byOperation('subset#3'), hasLength(1));
    expect(await reminders.upcoming(), isEmpty);
  });

  test('B5 no clears the draft without creates', () async {
    final session = await _open();
    await session.handle(_paste);
    expect(await session.handle('no'), contains('discarded'));
    expect(await tasks.list(), isEmpty);
    expect(await pending.get('batch:batch-chat'), isNull);
  });

  test(
      'B6 failure after item 2 rolls back the transaction; retry is idempotent',
      () async {
    final call = ToolCall('create_batch', {
      'items': [
        for (var i = 1; i <= 4; i++) _item(i, 'buy item $i'),
      ]
    });
    await db.execute("CREATE TRIGGER fail_third BEFORE INSERT ON tasks "
        "WHEN NEW.op_id = 'atomic#3' BEGIN SELECT RAISE(ABORT, 'crash'); END");
    await expectLater(
        executor.run(call, operationId: 'atomic'), throwsA(anything));
    expect(await tasks.list(), isEmpty);
    await db.execute('DROP TRIGGER fail_third');
    await executor.run(call, operationId: 'atomic', recovering: true);
    final replay =
        await executor.run(call, operationId: 'atomic', recovering: true);
    expect(await tasks.list(), hasLength(4));
    expect(replay.status, ReceiptStatus.replayed);
  });

  test('B6 recovery of previously stamped items creates only missing items',
      () async {
    await tasks.create('buy item 1', opId: 'partial#1');
    await tasks.create('buy item 2', opId: 'partial#2');
    await executor.run(
        ToolCall('create_batch', {
          'items': [
            for (var i = 1; i <= 4; i++) _item(i, 'buy item $i'),
          ]
        }),
        operationId: 'partial',
        recovering: true);
    expect(await tasks.list(), hasLength(4));
    for (var i = 1; i <= 4; i++) {
      expect(await tasks.byOperation('partial#$i'), hasLength(1));
    }
  });

  test('B7 conjunction creates both items after preview', () async {
    final session = await _open();
    expect(await session.handle('add buy milk and call mom tomorrow'),
        allOf(contains('1. buy milk'), contains('2. call mom')));
    expect(await tasks.list(), isEmpty);
    await session.handle('yes');
    expect((await tasks.list()).map((t) => t.title),
        unorderedEquals(['buy milk', 'call mom']));
  });

  test('B8 negation applies to its bullet only', () async {
    final session = await _open();
    final reply = await session
        .handle("Add these tasks:\n- buy milk\n- don't remind me about gym");
    expect(reply, allOf(contains('1. buy milk'), contains('gym (negated)')));
    await session.handle('yes');
    expect((await tasks.list()).single.title, 'buy milk');
    expect(await reminders.upcoming(), isEmpty);
  });

  test('B9 twelve bullets are rejected without inference or writes', () async {
    final session = await _open();
    expect(
        await session
            .handle(List.generate(12, (i) => '- buy item $i').join('\n')),
        contains('send up to 10 at a time'));
    expect(await tasks.list(), isEmpty);
    expect(_model.prompts, isEmpty);
  });

  test('B10 single-sentence negated cancellation stays unchanged', () async {
    await reminders.create('gym', _now.add(const Duration(hours: 1)));
    final session = await _open();
    expect(await session.handle("don't cancel my gym reminder"),
        'Okay, your gym reminder stays.');
    expect(await reminders.upcoming(), hasLength(1));
  });

  test('B11 twenty-line paste never reaches a prompt_too_long model', () async {
    _model.reject = true;
    final session = await _open();
    final reply = await session
        .handle(List.generate(20, (i) => '- buy item $i').join('\n'));
    expect(reply, contains('send up to 10 at a time'));
    expect(_model.prompts, isEmpty);
    expect(await tasks.list(), isEmpty);
  });

  test('batch draft survives restart and expires after thirty minutes',
      () async {
    var session = await _open();
    await session.handle('add buy milk and call mom tomorrow');
    await session.close();
    session = await _open(now: _now.add(const Duration(minutes: 29)));
    await session.handle('yes');
    expect(await tasks.list(), hasLength(2));
    await session.handle('add buy bread and pay rent');
    await session.close();
    session = await _open(now: _now.add(const Duration(minutes: 60)));
    await session.handle('yes');
    expect(await tasks.list(), hasLength(2));
    expect(await pending.get('batch:batch-chat'), isNull);
  });

  test(
      'drop selection, invalid selection, and detours consume drafts correctly',
      () async {
    final session = await _open();
    await session.handle('add buy milk and call mom tomorrow');
    expect(await session.handle('only 9'), contains('Choose item numbers'));
    expect(await tasks.list(), isEmpty);
    await session.handle('drop 2');
    expect((await tasks.list()).single.title, 'buy milk');
    await session.handle('add buy bread and pay rent');
    await session.handle('hello');
    expect(await pending.get('batch:batch-chat'), isNull);
    await session.handle('yes');
    expect(await tasks.list(), hasLength(1));
  });

  test('questions, tentative and unclear items are skipped independently',
      () async {
    final session = await _open();
    final reply = await session.handle('Add these tasks:\n- buy milk\n'
        '- maybe call mom\n- what should I buy?\n- stuff');
    expect(
        reply,
        allOf(contains('undecided'), contains('a question'),
            contains('tell me this one in your own words')));
    await session.handle('yes');
    expect((await tasks.list()).single.title, 'buy milk');
    expect(_model.prompts, isEmpty);
  });

  test('remind-all header creates reminders; dated tasks alone never notify',
      () async {
    final session = await _open();
    await session.handle(
        'Remind me about these:\n- buy milk tomorrow at 9 AM\n- call mom tomorrow at 5 PM');
    await session.handle('add all');
    expect(await reminders.upcoming(), hasLength(2));
    expect(_scheduler.syncs, 1);
  });

  test('batch preview serialization preserves its five distinct create calls',
      () async {
    await _seedTracked();
    final session = await _open();
    await session.handle(_paste);
    final raw = jsonDecode((await pending.get('batch:batch-chat'))!) as Map;
    expect(raw['asked_at'], _now.toIso8601String());
    expect((raw['items'] as List).map((e) => (e as Map)['tool']), [
      'create_task',
      'create_task',
      'create_task',
      'create_daily',
      'create_daily'
    ]);
  });

  test('MB6 negation cannot borrow a reminder from another sentence', () async {
    await reminders.create('gym', _now.add(const Duration(hours: 1)));
    final session = await _open();
    await session
        .handle("Don't email the client. My gym reminder is tomorrow.");
    expect(session.lastTurn!.plan.route, isNot(RouteId.negatedCancel));
    expect(await reminders.upcoming(), hasLength(1));
    expect(await pending.get('pick:batch-chat'), isNull);
  });

  test('MB6 create negation checks the clause containing the title', () async {
    _model.output =
        '{"intent":"create_task","title":"buy milk","negated":true}';
    final session = await _open(interpreter: Interpreter.legacy);
    await session.handle("I don't want coffee. I need to buy milk tomorrow.");
    expect((await tasks.list()).single.title, 'buy milk');
  });

  test('MB7 list intent without a listing drops the model listing claim',
      () async {
    _model.output =
        '{"intent":"list","reply":"Here is your task list: phantom item."}';
    final session = await _open(interpreter: Interpreter.legacy);
    final reply = await session.handle("Don't show my tasks");
    expect(reply, isNot(contains('phantom item')));
    expect(reply, isNot(contains('Here is your task list')));
  });

  test('a calculator detour drops the batch and never confirms it later',
      () async {
    final session = await _open();
    await session.handle('add buy milk and call mom tomorrow');
    expect(await session.handle('2+2'), contains('= 4'));
    expect(await pending.get('batch:batch-chat'), isNull);
    await session.handle('yes');
    expect(await tasks.list(), isEmpty);
  });
}
