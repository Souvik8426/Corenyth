import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/v2_db.dart';

// Future dates: ReminderRepo.upcoming filters by the wall clock.
final _early = DateTime(2099, 10, 7, 7); // before 08:10
final _late = DateTime(2099, 10, 7, 9); // after 08:10

const _screenshot =
    'Morning 8:10 am remind me i have to schedule a meet with ceo of komal goyal studios';
const _title = 'schedule a meet with ceo of komal goyal studios';

class _Memory extends MemoryRepo {
  final items = <String>[];
  _Memory(super.db);
  @override
  Future<int> add(String content,
      {String category = 'fact', double importance = 0.5}) async {
    items.add(content);
    return items.length;
  }

  @override
  Future<List<Memory>> search(String query, {int limit = 3}) async => [];
  @override
  Future<List<Memory>> important({int limit = 3}) async => [];
}

class _Recorder extends ReminderScheduler {
  final cancelled = <int>[];
  @override
  Future<void> schedule(Reminder r) async {}
  @override
  Future<void> cancel(int id) async => cancelled.add(id);
}

/// A model that always tries to dump the task list (what the screenshot showed).
class _ListingModel extends LlmEngine {
  var calls = 0;
  String output = '{"type":"tool","tool":"list_tasks","arguments":{}}';
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
  late _Recorder scheduler;
  late _ListingModel model;
  late _Memory memory;
  late ToolExecutor tools;

  setUp(() async {
    db = await openMigratedV2();
    tasks = TaskRepo(db);
    reminders = ReminderRepo(db);
    scheduler = _Recorder();
    model = _ListingModel();
    memory = _Memory(db);
  });

  Future<AssistantSession> open(DateTime now) async {
    tools = ToolExecutor(tasks, reminders, memory, scheduler,
        clock: () => now, preferences: ReminderPreferencesRepo(db));
    final s = AssistantSession(
      engine: model,
      tools: tools,
      memory: memory,
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      pending: PendingRepo(db),
      conversationId: 'chat',
      clock: () => now,
    );
    await s.start();
    return s;
  }

  Future<void> screenshotTasks() async {
    await tools.execute(ToolCall('create_reminder', {
      'title': 'buy milk',
      'at': DateTime(2099, 10, 7, 18),
      'multiple': true
    }));
    await tasks.create('bring milk', due: DateTime(2099, 10, 7, 19));
    await tasks.create('Calculate 46+50'); // legacy accidental task stays
  }

  Future<Reminder> alarmFor(String title) async => (await reminders.upcoming())
      .singleWhere((r) => r.title == title && r.kind == 'reminder');

  test(
      'exact screenshot before 08:10: completes buy milk, then schedules today 08:10',
      () async {
    final s = await open(_early);
    await screenshotTasks();
    final buy = (await tasks.byTitle('buy milk')).single;

    expect(await s.handle('Okay i am done with buying milk'),
        contains('buy milk'));
    expect((await tasks.get(buy.id))!.done, isTrue);
    expect(await reminders.forTask(buy.id), isEmpty);
    expect(scheduler.cancelled, isNotEmpty);

    final reply = await s.handle(_screenshot);
    expect(
        reply, allOf(contains(_title), contains('8:10 AM'), contains('today')));
    expect(reply, isNot(contains('bring milk')));
    expect(reply, isNot(contains('2099-')));
    expect((await alarmFor(_title)).triggerAt, DateTime(2099, 10, 7, 8, 10));
    expect((await tasks.byTitle(_title)).single.dueAt,
        DateTime(2099, 10, 7, 8, 10));
    expect((await tasks.byTitle('bring milk')).single.done, isFalse);
    expect((await tasks.byTitle('Calculate 46+50')), hasLength(1));
    expect(model.calls, greaterThan(0),
        reason: 'the model never got to list tasks');
    expect(memory.items, isEmpty);
  });

  test('after 08:10: asks which day, keeps 08:10 and flags across a restart',
      () async {
    var s = await open(_late);
    await screenshotTasks();
    final ask = await s.handle(
        'Morning 8:10 am remind me multiple times i have to schedule a meet with ceo of komal goyal studios');
    expect(
        ask,
        allOf(contains('already passed'), contains('at 8:10 AM'),
            contains(_title)));
    expect(ask, isNot(contains('bring milk')));
    expect(await tasks.byTitle(_title), isEmpty);
    await s.close();

    s = await open(_late); // restart, same chat
    expect(
        await s.handle('What is 2+2'), contains('4')); // detour keeps the draft
    final done = await s.handle('tomorrow');
    expect(done, contains('8:10 AM'));
    final alarm = await alarmFor(_title);
    expect(alarm.triggerAt, DateTime(2099, 10, 8, 8, 10),
        reason: 'not the 9 AM default');
    expect((await reminders.forTask(alarm.taskId!)).length, greaterThan(1),
        reason: '"multiple times" survived the question');
    expect(model.calls, greaterThan(0));
  });

  test('time-first and time-last variants', () async {
    final s = await open(_early);
    await s.handle('at 8:10am remind me to call Mum');
    expect(
        (await alarmFor('call Mum')).triggerAt, DateTime(2099, 10, 7, 8, 10));
    await s.handle('tomorrow morning at 8:10 remind me to water plants');
    expect((await alarmFor('water plants')).triggerAt,
        DateTime(2099, 10, 8, 8, 10));
    await s.handle('remind me to pay rent at 8:10 am tomorrow');
    expect(
        (await alarmFor('pay rent')).triggerAt, DateTime(2099, 10, 8, 8, 10));
    await s.handle('Tomorrow 9am, remind me to stretch with no follow-up');
    expect((await alarmFor('stretch')).triggerAt, DateTime(2099, 10, 8, 9));
    expect(model.calls, greaterThan(0));
  });

  test('time-first recall stays retrieval', () async {
    final s = await open(_early);
    await tasks.create('dentist', due: DateTime(2099, 10, 8, 15));
    await tasks.create('far away', due: DateTime(2099, 10, 20, 15));
    final reply = await s.handle('tomorrow remind me what tasks I have');
    expect(reply, allOf(contains('dentist'), isNot(contains('far away'))));
    expect(await reminders.upcoming(), isEmpty);
  });

  test(
      'invalid, conflicting, unsupported, negated and multiple requests write nothing',
      () async {
    final s = await open(_early);
    await screenshotTasks();
    final before = (await tasks.list()).length;
    final alarms = (await reminders.upcoming()).length;
    for (final (say, expected) in [
      ('morning 8pm remind me to call Mum', 'disagree'),
      ('at 13pm remind me to call Mum', ''),
      (
        'next Monday 8am remind me to call Mum',
        "don't schedule that kind of date"
      ),
      ("Don't remind me at 8:10 am to call Mum", ''),
      ('at 8:10 am remind me to call Mum and email Bob', 'one at a time'),
    ]) {
      final reply = await s.handle(say);
      expect(reply, contains(expected), reason: say);
      expect(reply, isNot(contains('bring milk')),
          reason: '$say: no unrelated list');
      expect((await tasks.list()).length, before, reason: say);
      expect((await reminders.upcoming()).length, alarms, reason: say);
    }
  });

  test('model read tools cannot stand in for a create or completion', () async {
    final s = await open(_early);
    await screenshotTasks();
    // a valid plan of the wrong kind (list for a create) is not executed
    model.output = '{"intent":"list","range":"all"}';
    final reply = await s.handle('remind me next monday to call Bob');
    expect(reply, isNot(contains('bring milk')));
    expect(s.lastFallbackReason, contains('did not fit'));
    model.output = '{"intent":"recall","title":"Bob"}';
    expect(await s.handle('remind me next monday to call Bob'),
        isNot(contains('nothing stored')));
    // a genuine question may still read
    model.output = '{"intent":"list","range":"all"}';
    expect(await s.handle('anything on my plate this week'),
        contains('bring milk'));
  });

  test(
      'malformed long time prefixes are rejected (linear check, no backtracking)',
      () {
    final r = RuleEngine(clock: () => _early);
    // Backtracked exponentially with the old nested regex (30 digits ~1.4 s);
    // the test timeout is the bound, no timing assertion.
    for (final n in [30, 60, 5000]) {
      final say = '${'9' * n}x remind me to call Mum';
      expect(r.parseCreate(say), isNull, reason: '$n');
      expect(r.fastRoute(say), isNull, reason: '$n');
      expect(r.fastRoute('${'9 ' * n}remind me to call Mum'), isNull,
          reason: '$n spaced');
    }
    // valid prefixes still reorder
    expect(
        (r.fastRoute('8:10am, remind me to call Mum')!['arguments']
            as Map)['at'],
        '2099-10-07T08:10:00.000');
  });

  test(
      'bare HH:MM: the part of day or 24-hour clock gives AM/PM; bad or double times ask',
      () {
    final r = RuleEngine(clock: () => _early);
    String? at(String say) =>
        (r.fastRoute(say)?['arguments'] as Map?)?['at'] as String?;
    for (final (say, want) in [
      ('Morning 8:10 remind me to call Mum', '2099-10-07T08:10:00.000'),
      ('remind me to call Mum morning 8:10', '2099-10-07T08:10:00.000'),
      (
        'tomorrow morning 8:10 remind me to call Mum',
        '2099-10-08T08:10:00.000'
      ),
      ('afternoon 3:30 remind me to call Mum', '2099-10-07T15:30:00.000'),
      ('evening 8:10 remind me to call Mum', '2099-10-07T20:10:00.000'),
      ('remind me to call Mum at 20:30', '2099-10-07T20:30:00.000'),
      ('remind me to call Mum 20:30', '2099-10-07T20:30:00.000'),
    ]) {
      expect(at(say), want, reason: say);
      expect((r.fastRoute(say)!['arguments'] as Map)['title'], 'call Mum',
          reason: say);
    }
    for (final say in [
      'remind me to call Mum 25:10',
      'remind me to call Mum 8:75',
      'morning 20:30 remind me to call Mum',
      'remind me to call Mum at 8:10 then 9pm',
    ]) {
      expect(r.fastRoute(say), isNull, reason: say);
      expect(r.maybeClarify(say), isNull, reason: say);
    }
    // past today: asks and keeps 08:10 for a "tomorrow" reply
    final late = RuleEngine(clock: () => _late);
    final d = late.maybeClarify('Morning 8:10 remind me to call Mum')!;
    expect(d.time, '8:10 AM');
    final done = late.resolveClarify(d, 'tomorrow')!.call;
    expect((done['arguments'] as Map)['at'], '2099-10-08T08:10:00.000');
  });
}
