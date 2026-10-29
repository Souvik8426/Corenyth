import 'dart:async';
import 'dart:convert';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'backend_test.dart' show FakeMemory;
import 'support/v2_db.dart';

/// Stand-in for Qwen returning a valid scripted semantic plan. [during]
/// runs inside inference (a slow model: the clock moves, or the user
/// cancels). Never a measure of real model accuracy.
class _Qwen extends LlmEngine {
  String plan = '{"intent":"chat","reply":"Okay!"}';
  Future<void> Function()? during;
  var cancels = 0;
  @override
  String get name => 'qwen-scripted';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}
  @override
  Future<void> cancel() async => cancels++;
  @override
  Future<String> complete(Prompt p) async {
    if (p.kind != PromptKind.plan) {
      return '{"type":"respond","text":"Okay."}';
    }
    await during?.call();
    return plan;
  }
}

String _plan(String intent, [Map<String, Object?> f = const {}]) =>
    jsonEncode({'intent': intent, ...f});

/// P1 end to end: AssistantSession over the real SQLite repositories, once
/// with a valid scripted Qwen extraction and once with the model
/// unavailable (rules only). Asserts saved state, not just wording.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final submitted = DateTime(2026, 10, 19, 7, 41); // plan §6, Monday
  DateTime t(int h, int m, [int day = 19]) => DateTime(2026, 10, day, h, m);

  late Database db;
  late TaskRepo tasks;
  late ReminderRepo reminders;
  late ReminderPreferencesRepo prefs;
  late PendingRepo pending;
  late DateTime now;
  late _Qwen qwen;

  setUp(() async {
    db = await openMigratedV2();
    tasks = TaskRepo(db);
    reminders = ReminderRepo(db);
    prefs = ReminderPreferencesRepo(db);
    pending = PendingRepo(db);
    now = submitted;
    qwen = _Qwen();
    await prefs.save(const ReminderPreferences());
  });

  Future<AssistantSession> open(bool model) async {
    final s = AssistantSession(
      engine: model ? qwen : RuleEngine(clock: () => now),
      tools: ToolExecutor(tasks, reminders, FakeMemory(), NoopScheduler(),
          clock: () => now, preferences: prefs),
      memory: FakeMemory(),
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      pending: pending,
      conversationId: 'main',
      clock: () => now,
    );
    await s.start();
    addTearDown(s.close);
    return s;
  }

  test('day-only call asks time and keeps the Sunday date', () async {
    final s = await open(false);
    expect(await s.handle('I have a call on Sunday'), contains('What time'));
    expect(await tasks.list(), isEmpty);
    await s.handle('3pm');
    expect((await tasks.list()).single.dueAt, t(15, 0, 25));
  });

  /// Enabled rows straight from SQLite: [ReminderRepo.upcoming] filters by
  /// the wall clock, and these tests run at the plan's fixed 07:41.
  Future<List<Reminder>> enabled() async =>
      (await db.query('reminders', where: 'enabled = 1', orderBy: 'trigger_at'))
          .map(Reminder.new)
          .toList();

  Future<List<Reminder>> alerts() async =>
      (await enabled()).where((r) => r.kind != 'follow_up').toList();

  /// The one task with its event/alert reminder at [at]; clean title.
  Future<Task> expectOne(String reply, String title, DateTime at,
      {List<String> notIn = const []}) async {
    final main = (await alerts()).where((r) => r.kind == 'reminder').toList();
    expect(main, hasLength(1), reason: reply);
    expect(main.single.triggerAt, at, reason: reply);
    expect(main.single.title.toLowerCase(), title.toLowerCase(),
        reason: reply);
    for (final w in notIn) {
      expect(main.single.title.toLowerCase(), isNot(contains(w)));
    }
    expect(reply, isNot(contains(RuleEngine.supportedWhen)));
    expect(reply.toLowerCase(), isNot(contains('when should')));
    expect(await pending.get('main'), isNull, reason: 'no question left open');
    final open = await tasks.list();
    expect(open, hasLength(1), reason: reply);
    return open.single;
  }

  Future<void> expectNoWrites(String reply) async {
    expect(await tasks.list(includeDone: true), isEmpty, reason: reply);
    expect(await enabled(), isEmpty, reason: reply);
  }

  for (final model in [false, true]) {
    final mode = model ? 'valid Qwen extraction' : 'Qwen unavailable';

    test('$mode: the exact screenshot request', () async {
      qwen.plan = _plan('create_reminder',
          {'title': 'meeting', 'when': 'within 10 mins'});
      final s = await open(model);
      final reply =
          await s.handle('Can u remind me i have a meeting within 10 mins');
      await expectOne(reply, 'meeting', t(7, 51),
          notIn: ['within', '10', 'min', 'i have', 'can u']);
      expect(reply, contains('7:51 AM'));
      expect(reply, contains('10 minutes from now'));
      // Confirmation first; the optional details question never blocks it.
      expect(reply.indexOf('7:51'), lessThan(reply.indexOf('Optional')));
      expect(reply.length, lessThan(240), reason: reply);
      expect(s.lastDiagnostics['route'], model ? 'semantic' : 'rules');
    });

    for (final (say, words, title, at) in [
      ('Remind me in ten minutes to call Mum', 'in ten minutes', 'call Mum',
          t(7, 51)),
      ('after 10 min remind me to call Mum', 'after 10 min', 'call Mum',
          t(7, 51)),
      ('remind me to call Mum 10 mins later', '10 mins later', 'call Mum',
          t(7, 51)),
      ('remind me in 2 hrs to take my tablets', 'in 2 hrs', 'take my tablets',
          t(9, 41)),
      ('remind me in an hour and a half to move the car',
          'in an hour and a half', 'move the car', t(9, 11)),
      ('set an alarm for half an hour from now to check the oven',
          'half an hour from now', 'check the oven', t(8, 11)),
    ]) {
      test('$mode: "$say"', () async {
        qwen.plan =
            _plan('create_reminder', {'title': title, 'when': words});
        final s = await open(model);
        final reply = await s.handle(say);
        await expectOne(reply, title, at,
            notIn: ['minute', 'min', 'hour', 'hrs', 'after', 'later', 'half']);
      });
    }

    test('$mode: meeting start versus "5 minutes before"', () async {
      qwen.plan = _plan('create_reminder',
          {'title': 'Meeting', 'when': 'in 10 minutes'});
      final s = await open(model);
      final reply =
          await s.handle('Meeting in 10 minutes, remind me 5 minutes before');
      final task = await expectOne(reply, 'Meeting', t(7, 51),
          notIn: ['10', '5', 'before', 'remind']);
      expect(task.dueAt, t(7, 51));
      expect({for (final r in await alerts()) r.kind: r.triggerAt},
          {'pre': t(7, 46), 'reminder': t(7, 51)});
      expect((await prefs.get()).leadMinutes, [30, 10],
          reason: 'a one-off lead never changes the saved policy');
    });

    test('$mode: "half an hour before" is the lead the resolver read',
        () async {
      qwen.plan = _plan('create_reminder',
          {'title': 'the meeting', 'when': 'in 2 hours'});
      final s = await open(model);
      final reply = await s
          .handle('remind me about the meeting in 2 hours half an hour before');
      await expectOne(reply, 'the meeting', t(9, 41),
          notIn: ['2', 'half', 'hour', 'before']);
      expect({for (final r in await alerts()) r.kind: r.triggerAt},
          {'pre': t(9, 11), 'reminder': t(9, 41)});
      expect((await prefs.get()).leadMinutes, [30, 10]);
    });

    for (final say in [
      'remind me in a week to call Mum',
      'remind me in 30 seconds to call Mum',
      'remind me every week at 5pm to call Mum',
      'remind me weekly at 5pm to call Mum',
      'remind me at 5pm next week to call Mum',
      'remind me in 10 minutes and 20 minutes to call Mum',
      'remind me today Friday at 5pm to call Mum',
    ]) {
      test('$mode: no partial schedule: "$say"', () async {
        qwen.plan = _plan('create_reminder', {'title': 'call Mum', 'when': 'at 5pm'});
        final s = await open(model);
        await expectNoWrites(await s.handle(say));
      });
    }

    test('$mode: an event length is its end, not its start', () async {
      qwen.plan =
          _plan('create_task', {'title': 'meeting', 'when': 'in 10 minutes'});
      final s = await open(model);
      final reply =
          await s.handle('I have a meeting in 10 minutes for half an hour');
      final task = await expectOne(reply, 'meeting', t(7, 51));
      expect(task.endsAt, t(8, 21));
    });

    test('$mode: optional meeting details never block creation', () async {
      qwen.plan = _plan('create_task',
          {'title': 'dentist appointment', 'when': 'at 4 this afternoon'});
      final s = await open(model);
      final reply =
          await s.handle("I've got a dentist appointment at 4 this afternoon");
      await expectOne(reply, 'dentist appointment', t(16, 0));
      expect(reply, contains('Optional'));
      final next = await s.handle('no idea yet');
      expect(next, isNot(contains('When should')));
      expect((await alerts()).where((r) => r.kind == 'reminder'), hasLength(1));
    });

    test('$mode: a deadline for something unnamed creates nothing', () async {
      qwen.plan = _plan('create_task',
          {'title': 'finish this', 'when': 'within 10 minutes'});
      final s = await open(model);
      final reply = await s.handle('Finish this within 10 minutes');
      await expectNoWrites(reply);
      expect(reply.toLowerCase(), isNot(contains('meeting')));
      if (model) expect(reply, contains('What needs to be done'));
    });

    test('$mode: a named deadline is a task due then, never an alarm',
        () async {
      await prefs.save(const ReminderPreferences(multiple: true));
      qwen.plan = _plan('create_task',
          {'title': 'submit the report', 'when': 'within 2 hours'});
      final s = await open(model);
      final reply = await s.handle('I need to submit the report within 2 hours');
      final l = await tasks.list();
      expect(l.single.title, 'submit the report', reason: reply);
      expect(l.single.dueAt, t(9, 41));
      expect(await enabled(), isEmpty, reason: reply);
    });

    test('$mode: "before 5pm" is a deadline: ask when to remind, keep title',
        () async {
      qwen.plan = _plan('create_reminder',
          {'title': 'submit the report', 'when': 'before 5pm'});
      final s = await open(model);
      final reply = await s.handle('remind me to submit the report before 5pm');
      await expectNoWrites(reply);
      expect(reply, contains('deadline'));
      expect(reply, isNot(contains(RuleEngine.supportedWhen)));
      qwen.plan = _plan('answer_pending', {'when': 'at 4pm'});
      await s.handle('at 4pm');
      await expectOne('', 'submit the report', t(16, 0));
    });

    test('$mode: tentative statements stay conversational', () async {
      qwen.plan = _plan('create_reminder',
          {'title': 'meet him', 'when': 'within an hour'});
      final s = await open(model);
      await expectNoWrites(
          await s.handle('Maybe I should meet him within an hour'));
    });

    test('$mode: negation never adds a reminder', () async {
      final s = await open(model);
      qwen.plan = _plan('create_reminder',
          {'title': 'team meeting', 'when': 'at 5pm'});
      await s.handle('remind me about the team meeting at 5pm');
      final before = await enabled();
      qwen.plan =
          _plan('create_reminder', {'title': 'meeting', 'negated': true});
      final reply = await s.handle("Don't remind me about the meeting");
      final after = await enabled();
      expect([for (final r in after) r.id], [for (final r in before) r.id],
          reason: reply);
      expect((await tasks.list()).length, 1);
    });

    test('$mode: conflicting times ask which, then the answer completes it',
        () async {
      qwen.plan = _plan('create_reminder',
          {'title': 'meeting', 'when': 'in 10 minutes'});
      final s = await open(model);
      final reply =
          await s.handle('remind me about the meeting in 10 minutes at 9');
      await expectNoWrites(reply);
      expect(reply, contains('"in 10 minutes"'));
      expect(reply, contains('"at 9"'));
      expect(reply, contains('disagree'));
      expect(reply, isNot(contains(RuleEngine.supportedWhen)));
      expect(s.lastDiagnostics['clarify'], 'temporal_conflict');
      qwen.plan = _plan('answer_pending', {'when': 'in 10 minutes'});
      final done = await s.handle('in 10 minutes');
      await expectOne(done, model ? 'meeting' : 'the meeting', t(7, 51));
    });

    test('$mode: a statement with two times writes nothing', () async {
      qwen.plan =
          _plan('create_task', {'title': 'Meeting', 'when': 'in 10 minutes'});
      final s = await open(model);
      final reply = await s.handle('Meeting in 10 minutes at 9');
      await expectNoWrites(reply);
      if (model) expect(reply, contains('disagree'));
    });

    test('$mode: a repeating interval is not a one-off', () async {
      qwen.plan = _plan('create_reminder',
          {'title': 'drink water', 'when': 'every 2 hours'});
      final s = await open(model);
      await expectNoWrites(
          await s.handle('remind me every 2 hours to drink water'));
    });

    test('$mode: a cancelled question saves nothing', () async {
      qwen.plan = _plan('create_reminder', {'title': 'the meeting'});
      final s = await open(model);
      final ask = await s.handle('Remind me about the meeting');
      expect(ask, contains('When should I remind you about'));
      expect(ask, isNot(contains(RuleEngine.supportedWhen)));
      qwen.plan = _plan('cancel_pending');
      await s.handle('cancel');
      expect(await pending.get('main'), isNull);
      await expectNoWrites('');
    });

    test('$mode: an answer after restart uses its own submission time',
        () async {
      qwen.plan = _plan('create_reminder', {'title': 'the meeting'});
      final a = await open(model);
      await a.handle('Remind me about the meeting');
      await a.close();
      now = now.add(const Duration(minutes: 2));
      final b = await open(model);
      qwen.plan = _plan('answer_pending', {'when': 'in ten minutes'});
      final reply = await b.handle('in ten minutes');
      await expectOne(reply, 'the meeting', t(7, 53));
    });
  }

  test('slow model: time resolves against submission, not completion',
      () async {
    qwen.plan =
        _plan('create_reminder', {'title': 'meeting', 'when': 'within 10 mins'});
    qwen.during = () async {
      now = now.add(const Duration(minutes: 3)); // inference took 3 minutes
      await Future<void>.delayed(Duration.zero);
    };
    final s = await open(true);
    final reply =
        await s.handle('Can u remind me i have a meeting within 10 mins');
    await expectOne(reply, 'meeting', t(7, 51));
  });

  test('cancel during inference writes nothing; the next turn works',
      () async {
    final gate = Completer<void>();
    qwen.plan =
        _plan('create_reminder', {'title': 'meeting', 'when': 'within 10 mins'});
    qwen.during = () => gate.future;
    final s = await open(true);
    final turn = s.handle('Can u remind me i have a meeting within 10 mins');
    await Future<void>.delayed(Duration.zero);
    final cancelling = s.cancel();
    gate.complete();
    await cancelling;
    expect(await turn, '');
    expect(qwen.cancels, 1);
    await expectNoWrites('cancelled');
    qwen.during = null;
    final reply =
        await s.handle('Can u remind me i have a meeting within 10 mins');
    await expectOne(reply, 'meeting', t(7, 51));
  });
}
