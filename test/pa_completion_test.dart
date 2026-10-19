import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/v2_db.dart';

/// Future date: ReminderRepo.upcoming filters by the wall clock.
final _now = DateTime(2099, 10, 7, 10);

class _Memory extends MemoryRepo {
  final items = <String>[];
  _Memory(super.db);
  @override
  Future<int> add(String content,
      {String category = 'fact',
      double importance = 0.5,
      String? opId,
      String? source}) async {
    items.add(content);
    return items.length;
  }

  @override
  Future<List<Memory>> search(String query, {int limit = 3}) async => [];
  @override
  Future<List<Memory>> important({int limit = 3}) async => [];
}

class _Recorder extends ReminderScheduler {
  final scheduled = <int>[], cancelled = <int>[];
  @override
  Future<void> schedule(Reminder r) async => scheduled.add(r.id);
  @override
  Future<void> cancel(int id) async => cancelled.add(id);
}

/// Any model call is a failure here: completion is decided by the app.
class _NoModel extends LlmEngine {
  var calls = 0;
  String output = '{"type":"respond","text":"model reply"}';
  @override
  String get name => 'model';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}
  @override
  Future<String> complete(Prompt p) async {
    calls++;
    return output;
  }
}

void main() {
  late Database db;
  late TaskRepo tasks;
  late ReminderRepo reminders;
  late _Memory memory;
  late _Recorder scheduler;
  late ToolExecutor tools;
  late _NoModel model;
  late AssistantSession s;

  setUp(() async {
    db = await openMigratedV2();
    tasks = TaskRepo(db);
    reminders = ReminderRepo(db);
    memory = _Memory(db);
    scheduler = _Recorder();
    model = _NoModel();
    tools = ToolExecutor(tasks, reminders, memory, scheduler,
        clock: () => _now, preferences: ReminderPreferencesRepo(db));
    s = AssistantSession(
      engine: model,
      tools: tools,
      memory: memory,
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      clock: () => _now,
    );
    await s.start();
  });

  Future<void> screenshotTasks() async {
    // #1 buy milk, with a linked notification plan (alerts + follow-up)
    await tools.execute(ToolCall('create_reminder', {
      'title': 'buy milk',
      'at': DateTime(2099, 10, 7, 18),
      'multiple': true,
      'follow_up': true,
    }));
    await tasks.create('bring milk', due: DateTime(2099, 10, 7, 19));
    await tasks.create('Calculate 46+50');
  }

  test('screenshot: "Okay i am done with buying milk" completes buy milk only',
      () async {
    await screenshotTasks();
    final buy = (await tasks.byTitle('buy milk')).single;
    final alarms = await reminders.forTask(buy.id);
    expect(alarms.length, greaterThan(1));

    final reply = await s.handle('Okay i am done with buying milk');
    expect(reply, contains('buy milk'));
    expect(model.calls, greaterThan(0));
    final done = (await tasks.get(buy.id))!;
    expect(done.done, isTrue);
    final row = await db.query('tasks', where: 'id = ?', whereArgs: [buy.id]);
    expect(row.single['completed_at'], isNotNull);
    expect((await tasks.list()).map((t) => t.title),
        ['bring milk', 'Calculate 46+50']);
    // every linked alarm disabled and cancelled on the platform
    expect(await reminders.forTask(buy.id), isEmpty);
    expect(scheduler.cancelled, containsAll(alarms.map((r) => r.id)));
    expect(await reminders.pending(), isEmpty);
    expect(memory.items, isEmpty);

    // repeating it changes nothing and says so
    expect(await s.handle('Okay i am done with buying milk'),
        contains('already marked done'));
    expect((await tasks.list()).length, 2);
    expect((await tasks.list(includeDone: true)).length, 3,
        reason: 'no new task');
  });

  test('other natural phrasings', () async {
    for (final say in [
      "Ok, I'm done with buying milk",
      'Okay, I’m done with buying milk',
      'I finished buying milk',
      'I have bought milk',
      'done with buy milk',
    ]) {
      final t = await tasks.create('buy milk');
      await s.handle(say);
      expect((await tasks.get(t.id))!.done, isTrue, reason: say);
    }
    final call = await tasks.create('call Mum');
    await s.handle('I called Mum');
    expect((await tasks.get(call.id))!.done, isTrue);
    expect(model.calls, greaterThan(0));
  });

  test('duplicates ask which; a bare id completes the chosen one', () async {
    await tasks.create('buy milk');
    await tasks.create('Buy milk!');
    await tasks.create('bring milk');
    final ask = await s.handle('I am done with buying milk');
    expect(
        ask,
        allOf(contains('#1'), contains('#2'), contains('Which'),
            isNot(contains('#3'))));
    expect((await tasks.list()).length, 3);
    await s.handle('#2');
    expect((await tasks.get(2))!.done, isTrue);
    expect((await tasks.get(1))!.done, isFalse);
    expect((await tasks.get(3))!.done, isFalse);
  });

  test(
      'clear completion with an unknown target asks directly, then completes the pick',
      () async {
    await screenshotTasks();
    final reply = await s.handle("I'm done with buying bread");
    expect(
        reply,
        allOf(contains('buying bread'), contains('Which one'),
            contains('#2 bring milk')));
    expect(model.calls, greaterThan(0));
    expect((await tasks.list()).length, 3);
    await s.handle('2');
    expect((await tasks.get(2))!.done, isTrue);
  });

  test('negations, questions, and hypotheticals never complete', () async {
    await screenshotTasks();
    for (final say in [
      'I am not done with buying milk',
      "I haven't finished buying milk",
      "I'm done with buying milk but not bringing milk",
      'am I done with buying milk?',
      'Am I done with buying milk',
      'If I am done with buying milk, what next',
      '"done with buying milk"',
      'what does done with buying milk mean',
    ]) {
      await s.handle(say);
      expect((await tasks.list()).length, 3, reason: say);
    }
    expect(RuleEngine.doneRef('I got a new phone'), isNull);
  });

  test('a model-proposed completion needs an explicit command or statement',
      () async {
    await screenshotTasks();
    model.output =
        '{"type":"tool","tool":"complete_task","arguments":{"title":"buy milk"}}';
    for (final say in [
      'Am I done with buy milk?',
      'I am done with buy milk?',
      'If I am done with buy milk, what next?',
      'Explain what done means for buy milk',
      'I was thinking about buy milk',
    ]) {
      await s.handle(say);
      expect((await tasks.list()).length, 3, reason: say);
    }
    expect(model.calls, greaterThan(0), reason: 'the model really proposed it');
    model.output =
        '{"type":"tool","tool":"complete_task","arguments":{"title":"bring milk"}}';
    await s
        .handle('Okay i am done with buying milk'); // rules act; model unused
    expect((await tasks.get(2))!.done, isFalse);
    final r = RuleEngine(clock: () => _now);
    expect(
        r.justifiedMutation('complete_task', 'Can you complete task buy milk?',
            {'title': 'buy milk'}),
        isTrue);
    expect(
        r.justifiedMutation(
            'complete_task', 'I finished buying milk', {'title': 'bring milk'}),
        isFalse);
  });

  test('explicit complete_task by id and title still work', () async {
    await screenshotTasks();
    expect(await s.handle('complete task 2'), contains('#2'));
    expect(await s.handle('complete task buy milk'), contains('buy milk'));
    expect((await tasks.list()).map((t) => t.title), ['Calculate 46+50']);
  });
}
