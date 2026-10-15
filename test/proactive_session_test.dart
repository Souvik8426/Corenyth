import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/follow_through.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'backend_test.dart' show FakeMemory;
import 'support/v2_db.dart';

/// Thu 15 Oct 2099, 10:00.
final _now = DateTime(2099, 10, 15, 10);
DateTime _at(int day, int h, [int m = 0]) => DateTime(2099, 10, day, h, m);

/// Stand-in for Qwen: a fixed plan for planning prompts, [reply] for reply
/// prompts. Records every prompt.
class _Qwen extends LlmEngine {
  final prompts = <Prompt>[];
  String reply = '{"type":"respond","text":"Sounds like Aditya is busy. '
      'Want a reminder to nudge him, or should we move the client meeting?"}';
  @override
  String get name => 'qwen-standin';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}
  @override
  Future<String> complete(Prompt p) async {
    prompts.add(p);
    return p.kind == PromptKind.reply
        ? reply
        : '{"intent":"chat","reply":"Okay!"}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late TaskRepo tasks;
  late ReminderRepo reminders;
  late ReminderPreferencesRepo prefs;
  late _Qwen model;

  setUp(() async {
    db = await openMigratedV2();
    tasks = TaskRepo(db);
    reminders = ReminderRepo(db);
    prefs = ReminderPreferencesRepo(db);
    model = _Qwen();
    // Follow-ups on, quiet hours explicitly off: daytime tests stay exact.
    await prefs.save(const ReminderPreferences(followUp: true));
  });

  ToolExecutor tools() =>
      ToolExecutor(tasks, reminders, FakeMemory(), NoopScheduler(),
          clock: () => _now, preferences: prefs);

  Future<AssistantSession> open(String chat, {bool qwen = false}) async {
    final s = AssistantSession(
      engine: qwen ? model : RuleEngine(clock: () => _now),
      tools: tools(),
      memory: FakeMemory(),
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      pending: PendingRepo(db),
      conversationId: chat,
      clock: () => _now,
    );
    await s.start();
    addTearDown(s.close);
    return s;
  }

  Future<Task> task(String title) async => (await tasks.list(includeDone: true))
      .singleWhere((t) => t.title == title);

  Future<List<Reminder>> alerts(Task t) => reminders.forTask(t.id);

  test(
      'a timed meeting gets alerts and an optional details question that '
      'survives detours, restart and chat switch, and replans the follow-up',
      () async {
    final s = await open('a');
    final r1 = await s.handle('I have a meeting with Aditya tomorrow at 3pm');
    expect(r1, contains('When does it end'));
    var m = await task('meeting with Aditya');
    expect(m.dueAt, _at(16, 15));
    expect(m.awaiting, TaskRepo.details);
    expect({
      for (final r in await alerts(m)) r.kind: r.triggerAt
    }, {
      'reminder': _at(16, 15),
      'follow_up': _at(16, 16)
    }, reason: 'no end known yet: follow-up at start + 60 min');

    // New work in between neither answers nor drops the question.
    expect(await s.handle('add task buy milk'), contains('buy milk'));
    expect((await task('meeting with Aditya')).awaiting, TaskRepo.details);

    // A fresh session in another chat (as after a restart).
    final s2 = await open('b');
    final r2 = await s2.handle(
        'The meeting with Aditya ends at 4:30pm, it is about the Q3 budget');
    expect(r2, allOf(contains('4:30 PM'), contains('Q3 budget')));
    m = await task('meeting with Aditya');
    expect(m.endsAt, _at(16, 16, 30));
    expect(m.subject, 'the Q3 budget');
    expect(m.awaiting, isNull);
    expect(
        (await alerts(m)).singleWhere((r) => r.kind == 'follow_up').triggerAt,
        _at(16, 16, 30),
        reason: 'a known end replaces the estimate');
    expect((await tasks.list()).length, 2,
        reason: 'same task updated, nothing new');
  });

  test('a question about meeting details never changes its end time', () async {
    final s = await open('a');
    await s.handle('I have a meeting with Aditya tomorrow at 3pm');
    await s.handle('Does the meeting with Aditya end at 4:30pm?');
    final meeting = await task('meeting with Aditya');
    expect(meeting.endsAt, isNull);
    expect(
        (await alerts(meeting))
            .singleWhere((r) => r.kind == 'follow_up')
            .triggerAt,
        _at(16, 16));
  });

  test(
      'early completion cancels the follow-up, asks how it went once, and '
      'stores the answer', () async {
    final s = await open('a');
    await s.handle('I have a meeting with Aditya tomorrow at 3pm');
    final m = await task('meeting with Aditya');
    final r = await s.handle('The meeting with Aditya is over');
    expect(r, allOf(contains('done'), contains('How did it go')));
    expect(await alerts(m), isEmpty, reason: 'future follow-up cancelled');
    expect(
        (await task('meeting with Aditya')).awaiting, TaskRepo.outcomeQuestion);

    final r2 = await s.handle('It went well, we agreed on the budget');
    expect(r2, contains('noted'));
    final done = await task('meeting with Aditya');
    expect(done.outcome, 'It went well, we agreed on the budget');
    expect(done.awaiting, isNull);
    expect(await tasks.awaitingAnswers(), isEmpty);
  });

  test(
      'a completion that already says how it went is acknowledged, not asked again',
      () async {
    final s = await open('a');
    await s.handle('I have a meeting with Aditya tomorrow at 3pm');
    final r = await s.handle(
        'Finished the meeting with Aditya early, we agreed to ship Friday');
    expect(r, contains('done'));
    expect(r, isNot(contains('How did it go')));
    final m = await task('meeting with Aditya');
    expect(m.done, isTrue);
    expect(m.outcome, 'we agreed to ship Friday');
    expect(m.awaiting, isNull,
        reason: 'no details or outcome question left open');
    expect(await alerts(m), isEmpty);
  });

  test('an ordinary errand completion is not treated as a meeting', () async {
    await tasks.create('buy milk');
    final s = await open('a');
    final r = await s.handle('I bought milk');
    expect(r, contains('buy milk'));
    expect(r, isNot(contains('How did')));
    expect((await task('buy milk')).awaiting, isNull);
  });

  test('the arrangement task stays separate from the attendance reminder',
      () async {
    final arrange = await tasks.create('arrange meeting with Aditya');
    final s = await open('a');
    final r = await s.handle('I have a meeting with Aditya tomorrow at 3pm');
    expect(r,
        contains('#${arrange.id} "arrange meeting with Aditya" is still open'));
    final kept = await task('arrange meeting with Aditya');
    expect(kept.done, isFalse);
    expect(kept.dueAt, isNull);
    expect(await alerts(kept), isEmpty);
    expect(await alerts(await task('meeting with Aditya')), isNotEmpty);
  });

  test(
      'a progress update in another chat links the right task through global '
      'context and is discussed, never turned into a task or a change',
      () async {
    await ConversationRepo(db)
        .add('a', 'user', 'Ask Aditya to set up the client meeting');
    final client = await tasks.create('client meeting', due: _at(16, 11));
    final s = await open('b', qwen: true);
    final r = await s.handle("Aditya hasn't replied");
    expect(r, contains('nudge him'));
    final p = model.prompts.last;
    expect(p.kind, PromptKind.reply);
    expect(
        p.context,
        allOf(contains('client meeting'),
            contains('Ask Aditya to set up the client meeting')));
    expect((await tasks.list()).single.id, client.id,
        reason: 'no task invented');
    expect((await task('client meeting')).dueAt, _at(16, 11));
    expect(await reminders.upcoming(), isEmpty);
  });

  test('two Adityas: asks which; a model reply claiming an action falls back',
      () async {
    await tasks.create('call Aditya Rao');
    final sharma = await tasks.create('email Aditya Sharma');
    model.reply = '{"type":"respond","text":"I\'ve sent Aditya a reminder."}';
    final s = await open('a', qwen: true);
    final ask = await s.handle("Aditya still hasn't replied");
    expect(
        ask,
        allOf(contains('Which one'), contains('call Aditya Rao'),
            contains('email Aditya Sharma')));
    final r = await s.handle('#${sharma.id}');
    expect(
        r,
        allOf(contains('email Aditya Sharma'),
            contains("haven't changed anything")));
    expect(r, isNot(contains('sent')));
    expect((await tasks.list()).length, 2);
    expect(await reminders.upcoming(), isEmpty);
  });

  test('questions, negations and hypotheticals never become updates or writes',
      () async {
    await tasks.create('call Aditya Rao');
    final s = await open('a', qwen: true);
    for (final t in [
      'Has Aditya replied?',
      "What if Aditya hasn't replied?",
      "Don't remind me daily at 8am to stretch",
      'Should I remind myself daily at 8am?',
    ]) {
      await s.handle(t);
    }
    expect((await tasks.list()).map((t) => t.title), ['call Aditya Rao']);
    expect(await reminders.upcoming(), isEmpty);
    expect(model.prompts.where((p) => p.kind == PromptKind.reply), isEmpty);
  });

  test('a daily reminder until a named date confirms the exact date and year',
      () async {
    final s = await open('a');
    final r = await s
        .handle('remind me daily at 8:46 AM until 5 November to take medicine');
    expect(r, allOf(contains('every day at 8:46 AM'), contains('5 Nov 2099')));
    final t = await task('take medicine');
    expect(t.dailyMinute, 8 * 60 + 46);
    expect(t.dueAt, _at(16, 8, 46), reason: "today's 8:46 has passed");
    expect(t.deadlineAt, DateTime(2099, 11, 5, 8, 46));
    expect((await alerts(t)).single.triggerAt, _at(16, 8, 46));
    // No time: ask, save nothing.
    expect(await s.handle('remind me daily until 5 November to stretch'),
        contains('What time each day'));
    expect((await tasks.list()).where((t) => t.title.contains('stretch')),
        isEmpty);
  });

  test('nudge mode schedules a timed errand without repeating remind me',
      () async {
    await prefs
        .save(const ReminderPreferences(multiple: true, leadMinutes: [30]));
    final s = await open('a');
    await s.handle('I want to buy milk today at 5pm');
    final milk = await task('buy milk');
    expect({for (final r in await alerts(milk)) r.kind: r.triggerAt},
        {'pre': _at(15, 16, 30), 'reminder': _at(15, 17)});
    expect(RuleEngine().parseCreate('I want to travel'), isNull,
        reason: 'an untimed wish is not automatically a commitment');
  });

  test(
      'an errand uses the evening review rather than an automatic hourly follow-up',
      () async {
    final s = await open('a');
    await s.handle('remind me to buy milk today at 5pm');
    final milk = await task('buy milk');
    expect((await alerts(milk)).map((r) => r.kind), ['reminder']);
  });

  test('a new display chat can answer the global missing-time question',
      () async {
    final first = await open('a');
    await first.handle('remind me to call Mum');
    final second = await open('b');
    await second.handle('5pm');
    final call = await task('call Mum');
    expect(call.dueAt, _at(15, 17));
    expect(await PendingRepo(db).get(ConversationRepo.mainChatId), isNull);
  });

  test('a full name answers a person clarification naturally', () async {
    await tasks.create('call Aditya Kumar');
    await tasks.create('email Aditya Sharma');
    final s = await open('a');
    expect(await s.handle("Aditya hasn't replied"), contains('Which one'));
    final answer = await s.handle('Aditya Sharma');
    expect(answer, contains('email Aditya Sharma'));
    expect(answer, isNot(contains('Which one')));
    expect((await tasks.list()).length, 2);
  });

  test('new progress during a clarification replaces the old news', () async {
    await tasks.create('call Aditya Kumar');
    await tasks.create('email Aditya Sharma');
    final s = await open('a', qwen: true);
    await s.handle("Aditya hasn't replied");
    await s.handle('Aditya Sharma has replied');
    expect(model.prompts.last.user, 'Aditya Sharma has replied');
  });

  test('an evening review invites conversation even with no outstanding tasks',
      () {
    final text = reviewText(
        (unresolved: <Task>[], finished: <Task>[], tomorrow: <Task>[]), _now);
    expect(text.toLowerCase(), contains('how was your day'));
    expect(text.toLowerCase(), contains('tomorrow'));
    expect(text, contains('?'));
  });

  test('a task-specific early alert leaves the saved preferences alone',
      () async {
    await prefs.save(const ReminderPreferences());
    final s = await open('a');
    await s
        .handle('remind me to call the bank tomorrow at 3pm 15 minutes before');
    final t = await task('call the bank');
    expect({for (final r in await alerts(t)) r.kind: r.triggerAt},
        {'pre': _at(16, 14, 45), 'reminder': _at(16, 15)});
    final saved = await prefs.get();
    expect(saved.multiple, isFalse);
    expect(saved.leadMinutes, [30, 10]);
  });

  test(
      'briefing groups overdue, today, upcoming and undated work with the next alert',
      () async {
    await tasks.create('pay rent', due: _at(14, 9));
    await tasks.create('call Mum', due: _at(15, 17));
    await tasks.create('dentist', due: _at(18, 10));
    await tasks.create('buy bread');
    await tools().execute(ToolCall(
        'create_reminder', {'title': 'water plants', 'at': _at(15, 12)}));
    final s = await open('a');
    final r = await s.handle('brief me');
    int at(String s) => r.indexOf(s);
    for (final s in [
      'Overdue:',
      'pay rent',
      'Today:',
      'call Mum',
      'water plants',
      'Coming up:',
      'dentist',
      'No date yet:',
      'buy bread',
      'Next alert: water plants'
    ]) {
      expect(at(s), greaterThanOrEqualTo(0), reason: s);
    }
    expect(at('pay rent'), lessThan(at('Today:')));
    expect(at('dentist'), lessThan(at('No date yet:')));
  });

  group('pure readers', () {
    test('event titles and completions', () {
      expect(isEventTitle('meeting with Aditya'), isTrue);
      expect(isEventTitle('dentist'), isTrue);
      expect(isEventTitle('arrange meeting with Aditya'), isFalse);
      expect(isEventTitle('buy milk'), isFalse);
      expect(eventDone('The meeting with Aditya is over, it went well'),
          (ref: 'meeting with Aditya', outcome: 'it went well'));
      for (final t in [
        "the meeting isn't over yet",
        'is the meeting over?',
        'I had a meeting tomorrow at 3pm',
        'the milk is done',
      ]) {
        expect(eventDone(t), isNull, reason: t);
      }
    });

    test('meeting details resolve against the start', () {
      final start = _at(16, 15);
      final d = eventDetails('it ends at 4', start)!;
      expect(d.end, _at(16, 16));
      expect(d.note, contains('4 PM'));
      expect(eventDetails('it lasts an hour', start)!.end, _at(16, 16));
      expect(eventDetails("it's about hiring", start)!.subject, 'hiring');
      expect(eventDetails('sounds good', start), isNull);
    });

    test('model replies must stay grounded prose', () {
      const facts = 'Task: #3 client meeting';
      expect(safeReply('Hope Aditya gets back soon. Want a reminder?', facts),
          isTrue);
      expect(safeReply("I've scheduled a follow-up.", facts), isFalse);
      expect(safeReply('Want a reminder at 5?', facts), isFalse,
          reason: 'ungrounded time');
      expect(safeReply('Task #3 is waiting on Aditya.', facts), isTrue);
      expect(Prompt(PromptKind.reply, 'hi', context: facts).render(now: _now),
          allOf(contains(Prompt.replySystem), contains('Facts:\n$facts')));
      expect(Prompt.replyGrammar, startsWith('root ::='));
    });

    test('the review text keeps ignored work without moving it', () {
      final t = Task({
        'id': 4,
        'title': 'pay rent',
        'status': 'pending',
        'priority': 1,
        'due_at': _at(14, 9).millisecondsSinceEpoch
      });
      final text = reviewText(
          (unresolved: [t], finished: [], tomorrow: []), _now,
          ignored: {4: 2});
      expect(
          text,
          allOf(contains('pay rent'), contains('earlier check-in'),
              contains('How did')));
    });
  });
}
