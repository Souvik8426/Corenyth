import 'dart:convert';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/v2_db.dart';

/// Wed 7 Oct 2099, 10:00.
final _now = DateTime(2099, 10, 7, 10);

/// Host SQLite has no FTS4, so memories stay in Dart.
class _Memory extends MemoryRepo {
  final items = <String>[];
  var searches = 0;
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
  Future<List<Memory>> search(String query, {int limit = 3}) async {
    searches++;
    return [];
  }

  @override
  Future<List<Memory>> important({int limit = 3}) async => [];
}

/// Model stand-in returning [output]; counts calls.
class _Model extends LlmEngine {
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

late Database db;
late TaskRepo tasks;
late ReminderRepo reminders;
late _Memory memory;
late _Model model;

AssistantSession open({String id = 'chat', DateTime? now}) => AssistantSession(
      engine: model,
      tools: ToolExecutor(tasks, reminders, memory, NoopScheduler(),
          clock: () => now ?? _now),
      memory: memory,
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      pending: PendingRepo(db),
      conversationId: id,
      clock: () => now ?? _now,
    );

Future<AssistantSession> started({String id = 'chat', DateTime? now}) async {
  final s = open(id: id, now: now);
  await s.start();
  return s;
}

Future<Task> task(String title) async =>
    (await tasks.list(includeDone: true)).singleWhere((t) => t.title == title);

void main() {
  final r = RuleEngine(clock: () => _now);
  Map<String, Object?>? args(String s) =>
      r.fastRoute(s)?['arguments'] as Map<String, Object?>?;

  setUp(() async {
    db = await openMigratedV2();
    tasks = TaskRepo(db);
    reminders = ReminderRepo(db);
    memory = _Memory(db);
    model = _Model();
  });

  test('screenshot: catch-up typo recalls every pending task, sets no alarm',
      () async {
    await tasks.create('pay rent', due: _now.subtract(const Duration(days: 2)));
    await tasks.create('buy bread');
    await tasks.create('dentist', due: _now.add(const Duration(days: 3)));
    final s = await started();
    final reply = await s.handle(
        'Hello canu remind me what are the things which i have catch on');
    expect(
        reply,
        allOf(
            contains('pay rent'), contains('buy bread'), contains('dentist')));
    expect(await reminders.upcoming(), isEmpty);
    expect(memory.items, isEmpty);
    expect(model.calls, greaterThan(0));
    expect(r.fastRoute('remind me what reminders I have')!['tool'],
        'list_reminders');
    // a general question is not a catch-up
    expect(r.fastRoute('what do I need to cook pasta'), isNull);
  });

  test('screenshot: arithmetic is computed by the app, not saved as a task',
      () async {
    final s = await started();
    expect(await s.handle('90+24-10*89898'), contains('= -898866'));
    expect(await s.handle('what is (2+3)*4?'), contains('= 20'));
    expect(await tasks.list(), isEmpty);
    expect(model.calls, 0, reason: 'arithmetic is an app utility');
  });

  test('screenshot: general knowledge never searches personal memories',
      () async {
    model.output = '{"intent":"recall","title":"capital of France"}';
    final s = await started();
    final reply = await s.handle('What is the capital of France?');
    expect(memory.searches, 0);
    expect(reply, contains("can't look that up"));
    expect(s.lastDiagnostics['intent'], 'recall');
    model.output = '{"intent":"chat","reply":"Hi! How can I help?"}';
    expect(await s.handle('hi'), 'Hi! How can I help?');
  });

  test(
      'plain-language capture: tasks with disclosed defaults, no alerts, no memories',
      () async {
    final s = await started();
    expect(await s.handle('I have to buy eggs in evening'),
        allOf(contains('buy eggs'), contains('7 PM')));
    expect(await s.handle('I also need to buy bread'), contains('buy bread'));
    expect(
        await s.handle('I need to call Mum tomorrow'),
        allOf(contains('call Mum'),
            contains("9 AM since you didn't give a time")));
    await s.handle('I have a meeting tomorrow at 12pm');
    expect((await task('buy eggs')).dueAt, DateTime(2099, 10, 7, 19));
    expect((await task('buy bread')).dueAt, isNull);
    expect((await task('call Mum')).dueAt, DateTime(2099, 10, 8, 9));
    expect((await task('meeting')).dueAt, DateTime(2099, 10, 8, 12));
    expect(await reminders.upcoming(), isEmpty,
        reason: 'statements set no alarms');
    expect(memory.items, isEmpty, reason: 'temporary plans are not memories');
    expect(model.calls, greaterThan(0));
    // later completion by the plain item name finds "buy eggs"
    expect(await s.handle('I bought eggs'), contains('buy eggs'));
    expect((await task('buy eggs')).done, isTrue);
    // "I finished reading about tasks" matches no task: not a completion
    expect(RuleEngine.doneRef('I finished reading about tasks'), isNotNull);
    await s.handle('I finished reading about tasks');
    expect((await tasks.list()).length, 3);
  });

  test('multi-commitment requests save all or nothing', () async {
    final s = await started();
    expect(await s.handle('I need to buy eggs and call Mum tomorrow'),
        contains('one at a time'));
    expect(await tasks.list(), isEmpty);
    // one item with several things to buy is fine
    await s.handle('I need to buy eggs and bread');
    expect((await tasks.list()).single.title, 'buy eggs and bread');
  });

  test(
      'missing time: asked, persisted across restart, ambiguous replies do nothing',
      () async {
    var s = await started();
    expect(await s.handle('remind me to call Bob'),
        contains('When should I remind you about "call Bob"?'));
    await s.close();
    s = await started(); // app restart / chat switch back: same conversation
    expect(await s.handle('tomorrow buy bread'), contains('did nothing'));
    expect(await tasks.list(), isEmpty);
    expect(await reminders.upcoming(), isEmpty);
    expect(await s.handle('next monday'),
        contains("can't schedule that kind of date"));
    expect(await s.handle('5pm'), contains('call Bob'));
    final alarm = (await reminders.upcoming()).single;
    expect((alarm.title, alarm.triggerAt),
        ('call Bob', DateTime(2099, 10, 7, 17)));
  });

  test(
      'pending time survives detours and restart; cancel or a new create ends it',
      () async {
    var s = await started();
    await s.handle('remind me to stretch');
    expect(await s.handle('2+2'), contains('= 4'));
    await s.handle('what are my tasks');
    await s.close();
    s = await started(); // restart: same conversation
    expect(await s.handle('in twenty minutes'), contains('stretch'));
    await s.handle('remind me to call Al');
    expect(await s.handle('remind me to call Bo'),
        contains('replaced the unfinished "call Al"'));
    await s.handle('5pm');
    expect((await reminders.upcoming()).map((r) => r.title),
        ['stretch', 'call Bo']);
    await s.handle('remind me to nap');
    expect(await s.handle('cancel'), contains('dropped'));
    await s.handle('6pm');
    expect((await reminders.upcoming()).map((r) => r.title),
        isNot(contains('nap')));
  });

  test('a time already passed today is asked about, never moved silently',
      () async {
    final s = await started();
    expect(await s.handle('remind me at 9am to stretch'),
        contains('already passed'));
    expect(await reminders.upcoming(), isEmpty);
    await s.handle('tomorrow at 9am');
    expect((await reminders.upcoming()).single.triggerAt,
        DateTime(2099, 10, 8, 9));
  });

  test(
      'postpone by duration, by #id, and duplicates asked then picked by number',
      () async {
    await tasks.create('gym', due: DateTime(2099, 10, 7, 18));
    final s = await started();
    expect(await s.handle('postpone gym by 2h'), contains('#1'));
    expect((await task('gym')).dueAt, DateTime(2099, 10, 7, 20));
    await s.handle('postpone #1 by 30 min');
    expect((await task('gym')).dueAt, DateTime(2099, 10, 7, 20, 30));
    await tasks.create('Gym!', due: DateTime(2099, 10, 9, 8));
    final ask = await s.handle('postpone gym by 1 hour');
    expect(ask, allOf(contains('#1'), contains('#2'), contains('Which')));
    expect(await s.handle('#2'), contains('#2'));
    expect((await tasks.get(2))!.dueAt, DateTime(2099, 10, 9, 9));
    expect((await tasks.get(1))!.dueAt, DateTime(2099, 10, 7, 20, 30));
    await s.handle('complete task gym');
    expect(await s.handle('#7'), contains("isn't one of"));
    await s.handle('1');
    expect((await tasks.get(1))!.done, isTrue);
  });

  test(
      'notification flags: stripped from titles, disables beat enables, negation stays',
      () {
    final a =
        args('remind me I have a meeting at 12pm do remind me multiple times')!;
    expect(a, {
      'title': 'meeting',
      'at': '2099-10-07T12:00:00.000',
      'multiple': true
    });
    expect(args('remind me at 5pm to call Bob with no follow-up'), {
      'title': 'call Bob',
      'at': '2099-10-07T17:00:00.000',
      'follow_up': false
    });
    expect(args('remind me at 5pm to stretch just once with follow-ups'), {
      'title': 'stretch',
      'at': '2099-10-07T17:00:00.000',
      'multiple': false,
      'follow_up': true
    });
    for (final t in [
      "Don't remind me at 5pm to call Bob",
      'do not remind me at 5pm',
      'remind me at 5pm to call Bob or Al'
    ]) {
      expect(r.fastRoute(t), isNull, reason: t);
      expect(r.maybeClarify(t), isNull, reason: t);
    }
    expect(r.plan("Don't remind me at 5pm to call Bob")['text'],
        contains("didn't change"));
  });

  test('clock parsing rejects invalid times and stays calendar-safe', () {
    for (final t in [
      'remind me at 13pm to x',
      'remind me at 0am to x',
      'remind me at 7:75 to x'
    ]) {
      expect(r.fastRoute(t), isNull, reason: t);
      expect(r.maybeClarify(t), isNull, reason: t);
    }
    expect(args('remind me tomorrow at 7 to run')!['at'],
        '2099-10-08T07:00:00.000');
    final evening = r.fastRoute('remind me at 7 to run')!;
    expect((evening['arguments'] as Map)['at'], '2099-10-07T19:00:00.000');
    expect(evening['note'], contains('7 PM'));
    expect(args('remind me at noon to eat')!['at'], '2099-10-07T12:00:00.000');
    final eom = RuleEngine(clock: () => DateTime(2026, 12, 31, 22));
    expect(
        (eom.fastRoute('remind me tomorrow at 8am to rest')!['arguments']
            as Map)['at'],
        '2027-01-01T08:00:00.000');
  });

  test('model mutations need evidence: verb, matching item, same date',
      () async {
    bool ok(String tool, String user, Map<String, Object?> a) =>
        r.justifiedMutation(tool, user, a);
    expect(
        ok('delete_task', 'Explain how to delete tasks', {'id': 1}), isFalse);
    expect(ok('delete_task', 'Explain how to delete tasks', {'title': 'tasks'}),
        isFalse);
    expect(ok('complete_task', 'I finished reading about tasks', {'id': 2}),
        isFalse);
    expect(ok('create_task', 'jot down milk', {'title': 'milk'}), isFalse);
    expect(
        ok('create_task', 'I need to call the plumber',
            {'title': 'call the plumber', 'due': DateTime(2099, 10, 9)}),
        isFalse,
        reason: 'invented date');
    expect(
        ok('create_task', 'I need to call the plumber',
            {'title': 'fix the sink'}),
        isFalse);
    expect(
        ok('create_reminder', 'remind me at 5pm to call Bob',
            {'title': 'call Bob', 'at': DateTime(2099, 10, 7, 17)}),
        isTrue);
    expect(
        ok('create_reminder', 'remind me at 5pm to call Bob',
            {'title': 'call Bob', 'at': DateTime(2099, 10, 7, 18)}),
        isFalse);
    expect(ok('delete_task', 'please delete #2 now', {'id': 2}), isTrue);
    final at1 = DateTime(2099, 10, 7, 13);
    for (final extra in [
      {'multiple': true},
      {'follow_up': false},
      {'task_id': 1}
    ]) {
      expect(
          ok('create_reminder', 'remind me at 1pm to call Bob',
              {'title': 'call Bob', 'at': at1, ...extra}),
          isFalse,
          reason: '$extra unrequested');
    }
    expect(
        ok('create_reminder', 'remind me at 1pm to call Bob with no follow-up',
            {'title': 'call Bob', 'at': at1, 'follow_up': false}),
        isTrue);
    expect(
        ok('create_reminder', 'remind me at 1pm to call Bob for task #4',
            {'title': 'call Bob', 'at': at1, 'task_id': 4}),
        isTrue);

    await tasks.create('Keep me');
    model.output = '{"intent":"delete","ref":"Keep me"}';
    final s = await started();
    expect(await s.handle('Explain how to delete tasks'),
        contains("didn't change"));
    expect((await tasks.list()).single.title, 'Keep me');
    model.output =
        '{"intent":"delete","ref":"1"}'; // an id the user never typed
    await s.handle('please get rid of the thing');
    expect((await tasks.list()).single.title, 'Keep me');
  });

  test('model claims of actions are neither streamed nor shown', () async {
    model.output = '{"type":"respond","text":"I\'ve set a reminder for 5pm."}';
    final s = await started();
    final seen = <String>[];
    final reply = await s.handle('could you sort my evening', onText: seen.add);
    expect(reply, isNot(contains('set a reminder')));
    expect(seen.where((t) => t.contains('set a reminder')), isEmpty);
    expect(await reminders.upcoming(), isEmpty);
  });

  test('explicit "mark task" keeps its exact title', () {
    expect(r.fastRoute('mark task Buy milk done')!['arguments'],
        {'title': 'Buy milk'});
    expect(r.fastRoute('mark Buy milk as done')!['arguments'],
        {'title': 'Buy milk'});
  });

  test('durable preferences mentioning meetings are saved; plans are not',
      () async {
    final s = await started();
    expect(await s.handle('Remember that I prefer meetings in the afternoon'),
        contains("I'll remember"));
    expect(memory.items, ['User prefers meetings in the afternoon']);
    expect(await s.handle('Remember I have a meeting tomorrow'),
        contains("won't store short-lived plans"));
    await s.handle('I usually have meetings on Monday');
    expect(memory.items, hasLength(2));
    expect(jsonEncode(r.extractMemory('I have to buy eggs')),
        '{"remember":false}');
  });
}
