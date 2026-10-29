import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/semantic.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/v2_db.dart';

/// 14 Oct 2099, 07:00 (future: ReminderRepo.upcoming uses the wall clock).
final _now = DateTime(2099, 10, 14, 7);

class _Memory extends MemoryRepo {
  _Memory(super.db);
  @override
  Future<int> add(String content,
          {String category = 'fact',
          double importance = 0.5,
          String? opId,
          String? source}) async =>
      1;
  @override
  Future<List<Memory>> search(String query, {int limit = 3}) async => [];
  @override
  Future<List<Memory>> important({int limit = 3}) async => [];
}

/// Stand-in for Qwen: answers each message with the plan a correct model would
/// emit for it (only the semantic JSON the grammar allows). Records prompts.
class _Planner extends LlmEngine {
  final plans = <String, String>{};
  final prompts = <Prompt>[];
  @override
  String get name => 'qwen-standin';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}
  @override
  Future<String> complete(Prompt p) async {
    prompts.add(p);
    return plans[p.user] ?? '{"intent":"chat","reply":"Okay!"}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late TaskRepo tasks;
  late ReminderRepo reminders;
  late _Planner model;
  late ToolExecutor tools;

  setUp(() async {
    db = await openMigratedV2();
    tasks = TaskRepo(db);
    reminders = ReminderRepo(db);
    model = _Planner();
    tools = ToolExecutor(tasks, reminders, _Memory(db), NoopScheduler(),
        clock: () => _now, preferences: ReminderPreferencesRepo(db));
  });

  Future<AssistantSession> open([DateTime? now]) async {
    tools = ToolExecutor(tasks, reminders, _Memory(db), NoopScheduler(),
        clock: () => now ?? _now, preferences: ReminderPreferencesRepo(db));
    final s = AssistantSession(
      engine: model,
      tools: tools,
      memory: _Memory(db),
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      pending: PendingRepo(db),
      conversationId: 'chat',
      clock: () => now ?? _now,
    );
    await s.start();
    return s;
  }

  Future<Task> one(String title) async => (await tasks.list(includeDone: true))
      .singleWhere((t) => t.title == title);

  test('screenshot conversation: model plans, app validates, SQLite answers',
      () async {
    await tools.execute(ToolCall('create_reminder',
        {'title': 'buy milk', 'at': DateTime(2099, 10, 14, 12)})); // today
    await tasks.create('bring milk');
    await tasks.create('Calculate 46+50',
        due: DateTime(2099, 10, 15, 23, 20)); // legacy, kept
    await tasks.create('dentist', due: DateTime(2099, 10, 15, 16));
    // An old build's raw list sits in this chat's history.
    await ConversationRepo(db).add('chat', 'assistant',
        '#1 buy milk (due 2026-10-14T12:03:12.000)\n#3 Calculate 46+50 (due 2026-10-15T23:20:24.000)\n#2 bring milk');
    final s = await open();
    const meet = 'schedule a meet with ceo of komal goyal studios';
    model.plans.addAll({
      'Morning 8:10 am remind me i have to schedule a meet with ceo of komal goyal studios':
          '{"intent":"create_reminder","title":"$meet","when":"Morning 8:10 am"}',
      'Wow that was fast soo tell me what are the things which are pending for tomorrow':
          '{"intent":"list","range":"tomorrow"}',
      'Remind me i have to call pratham bhaiya too':
          '{"intent":"create_reminder","title":"call pratham bhaiya too"}',
      'I hv to check dev console tomo':
          '{"intent":"create_task","title":"check dev console","when":"tomo"}',
    });

    final r1 = await s.handle(
        'Morning 8:10 am remind me i have to schedule a meet with ceo of komal goyal studios');
    expect(r1, allOf(contains(meet), contains('8:10 AM')));
    expect((await one(meet)).dueAt, DateTime(2099, 10, 14, 8, 10));
    expect(s.lastDiagnostics, containsPair('model', 'called'));
    expect(s.lastDiagnostics, containsPair('db', 'ok'));

    final r2 = await s.handle(
        'Wow that was fast soo tell me what are the things which are pending for tomorrow');
    expect(r2, startsWith('Due tomorrow:'));
    expect(r2, allOf(contains('dentist'), contains('Calculate 46+50')));
    expect(
        r2,
        isNot(anyOf(
            contains('bring milk'), contains('buy milk'), contains(meet))),
        reason: 'tomorrow only: no today, no undated');
    expect(r2, isNot(contains('2026-')), reason: 'fresh rows, not history');
    expect(model.prompts.last.render(now: _now),
        isNot(contains('2026-10-14T12:03')),
        reason: 'old assistant lists never reach the model');

    final r3 = await s.handle('Remind me i have to call pratham bhaiya too');
    expect(r3, contains('"call pratham bhaiya"'));
    expect(await PendingRepo(db).get(ConversationRepo.mainChatId),
        contains('call pratham bhaiya'));

    final r4 = await s.handle('I hv to check dev console tomo');
    expect(r4, contains('check dev console'));
    expect((await one('check dev console')).dueAt, DateTime(2099, 10, 15, 9));
    expect(await PendingRepo(db).get(ConversationRepo.mainChatId),
        contains('call pratham bhaiya'),
        reason: 'the new task did not consume the pending reminder');
    expect(model.prompts.last.pending, contains('call pratham bhaiya'));

    await s.close();
    final again = await open(); // app restart
    final calls = model.prompts.length;
    expect(await again.handle('5pm'), contains('call pratham bhaiya'));
    expect(model.prompts.length, calls,
        reason: 'a pure time answer needs no model');
    final alarm = (await reminders.upcoming())
        .singleWhere((r) => r.title == 'call pratham bhaiya');
    expect(alarm.triggerAt, DateTime(2099, 10, 14, 17));
    expect(await PendingRepo(db).get('chat'), isNull);
    expect(await tasks.byTitle('Calculate 46+50'), hasLength(1));
  });

  test('the model may answer a pending question in its own words', () async {
    final s = await open();
    model.plans['remind me to stretch'] =
        '{"intent":"create_reminder","title":"stretch"}';
    await s.handle('remind me to stretch');
    model.plans['ok make that in twenty minutes pls'] =
        '{"intent":"answer_pending","when":"in twenty minutes"}';
    await s.handle('ok make that in twenty minutes pls');
    expect((await reminders.upcoming()).single.triggerAt,
        _now.add(const Duration(minutes: 20)));
    model.plans['remind me to nap'] =
        '{"intent":"create_reminder","title":"nap"}';
    await s.handle('remind me to nap');
    model.plans['forget that one'] = '{"intent":"cancel_pending"}';
    expect(await s.handle('forget that one'), contains('dropped "nap"'));
    expect(await PendingRepo(db).get('chat'), isNull);
  });

  test('model prose about tasks is never shown; reads come from SQLite',
      () async {
    await tasks.create('pay rent');
    final s = await open();
    model.plans['so what is up'] =
        '{"intent":"chat","reply":"You have #1 buy milk (due 2026-10-14T12:03)."}';
    final r = await s.handle('so what is up');
    expect(r, isNot(contains('buy milk')));
    expect(s.lastFallbackReason, contains('did not fit'));
    model.plans['anything left?'] = '{"intent":"list","range":"all"}';
    expect(await s.handle('anything left?'),
        allOf(contains('Pending tasks:'), contains('pay rent')));
  });

  test('negations, questions, invented ids and invented dates never write',
      () async {
    await tasks.create('buy milk');
    await tasks.create('bring milk');
    final s = await open();
    model.plans.addAll({
      "don't remind me to call Bob tomorrow":
          '{"intent":"create_reminder","title":"call Bob","when":"tomorrow"}',
      'Am I done with buy milk?': '{"intent":"complete","ref":"buy milk"}',
      'I finished it': '{"intent":"complete","ref":"2"}',
      'I need to water the plants':
          '{"intent":"create_task","title":"water the plants","when":"tomorrow 8am"}',
      'remind me to call Al next blue moon':
          '{"intent":"create_reminder","title":"call Al","when":"next blue moon"}',
    });
    expect(await s.handle("don't remind me to call Bob tomorrow"),
        contains("won't save"));
    expect(
        await s.handle('Am I done with buy milk?'), allOf(contains('buy milk'), contains('still pending')));
    await s.handle('I finished it');
    expect((await tasks.list()).length, 2,
        reason: 'no completion from an invented id');
    await s.handle('I need to water the plants');
    expect((await one('water the plants')).dueAt, isNull,
        reason: 'date the user never said');
    expect(await s.handle('remind me to call Al next blue moon'),
        contains('couldn\'t read "next blue moon"'));
    expect(await reminders.upcoming(), isEmpty);
    expect(await PendingRepo(db).get(ConversationRepo.mainChatId),
        contains('call Al'));
  });

  test(
      'ambiguous references ask; a number picks; slang completion matches stems',
      () async {
    await tasks.create('buy milk');
    await tasks.create('bring milk');
    final s = await open();
    model.plans['milk is sorted'] = '{"intent":"complete","ref":"milk"}';
    expect(await s.handle('milk is sorted'),
        allOf(contains('#1'), contains('#2'), contains('Which')));
    await s.handle('#2');
    expect((await tasks.get(2))!.done, isTrue);
    expect((await tasks.get(1))!.done, isFalse);
    model.plans['finally done buying milk'] =
        '{"intent":"complete","ref":"buying milk"}';
    await s.handle('finally done buying milk');
    expect((await tasks.get(1))!.done, isTrue);
  });

  test(
      'semantic contract: strict parser, grammar, compact prompt, native grammar',
      () async {
    expect(parseSemantic('{"intent":"list","range":"tomorrow"}').range,
        'tomorrow');
    for (final bad in [
      '{"intent":"drop_db"}',
      '{"intent":"list","range":"next week"}',
      '{"intent":"create_task","title":3}',
      '{"type":"respond","text":"#1 buy milk"}',
    ]) {
      expect(() => parseSemantic(bad), throwsA(isA<ToolError>()), reason: bad);
    }
    for (final w in [...semanticIntents, ...semanticRanges]) {
      expect(semanticGrammar, contains('\\"$w\\"'));
    }
    final p = Prompt(PromptKind.plan, 'hi',
        tasks: '#1 buy milk',
        pending: 'reminder "x" still needs a time',
        history: [Message('assistant', '#9 stale list')]);
    final r = p.render(now: _now);
    expect(
        r,
        allOf(contains('Current tasks:\n#1 buy milk'), contains('Pending:'),
            isNot(contains('stale list'))));
    // The mood-envelope instruction grew the fixed prompt; ~3550 chars
      // is still ~890 tokens, well inside the 2048-token window.
    expect(r.length, lessThan(4200), reason: 'well inside a 2048-token window');

    const ch = MethodChannel('assistant/llm');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    MethodCall? seen;
    messenger.setMockMethodCallHandler(ch, (c) async {
      seen = c;
      return '{"intent":"chat","reply":"hi"}';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(ch, null));
    await LlamaChannelEngine('m').complete(p);
    expect(seen!.arguments['grammar'], semanticGrammar);
    expect(seen!.arguments['maxTokens'], 140);
  });

  test('"that one" means the last task; after a list it asks which', () async {
    final s = await open();
    model.plans['add milk tomorrow'] =
        '{"intent":"create_task","title":"milk","when":"tomorrow"}';
    await s.handle('add milk tomorrow');
    model.plans['mark that done'] = '{"intent":"complete","ref":"that"}';
    await s.handle('mark that done');
    expect((await one('milk')).done, isTrue);
    await tasks.create('pay rent');
    await tasks.create('call Bob');
    model.plans['what is pending'] = '{"intent":"list","range":"all"}';
    await s.handle('what is pending');
    expect(await s.handle('mark that done'), contains('Which one'));
    expect((await tasks.list()).length, 2);
  });

  test('rename and reminder commands are never turned into task changes',
      () async {
    await tasks.create('Buy milk');
    final s = await open();
    model.plans['rename task Buy milk to Buy oat milk'] =
        '{"intent":"complete","ref":"Buy milk"}';
    await s.handle('rename task Buy milk to Buy oat milk');
    expect((await one('Buy oat milk')).done, isFalse);
    await tools.execute(ToolCall('create_reminder',
        {'title': 'Dentist', 'at': DateTime(2099, 10, 14, 15)}));
    model.plans['cancel reminder Dentist'] =
        '{"intent":"delete","ref":"Dentist"}';
    expect(await s.handle('cancel reminder Dentist'),
        contains('Cancelled reminder'));
    expect(await tasks.byTitle('Dentist'), hasLength(1),
        reason: 'the task itself stays');
  });

  test('the model cannot add words the user never said to a title', () async {
    final s = await open();
    model.plans['I need to buy eggs'] =
        '{"intent":"create_task","title":"buy duck eggs"}';
    await s.handle('I need to buy eggs');
    expect((await tasks.list()).single.title, 'buy eggs',
        reason: 'rules, not the invented title');
  });

  test(
      'labelled context: last task and earlier user words, never assistant text',
      () async {
    await ConversationRepo(db)
        .add('chat', 'assistant', '#9 stale list from an old build');
    final s = await open();
    model.plans['add milk tomorrow'] =
        '{"intent":"create_task","title":"milk","when":"tomorrow"}';
    await s.handle('add milk tomorrow');
    await s.handle('hmm');
    final r =
        model.prompts.lastWhere((p) => p.kind == PromptKind.plan).render();
    expect(
        r,
        allOf(
            contains('Now: Wed 2099-10-14T07:00'),
            contains('Last task mentioned: #1 milk (due tomorrow'),
            contains('Earlier user message: add milk tomorrow'),
            isNot(contains('stale list'))));
  });

  test(
      'trust boundary: extra or incompatible fields and corrupt drafts are rejected',
      () {
    for (final bad in [
      '{"intent":"chat","title":"x"}',
      '{"intent":"list","bogus":1}',
      '{"intent":"complete","when":"tomorrow","range":"all"}',
    ]) {
      expect(() => parseSemantic(bad), throwsA(isA<ToolError>()), reason: bad);
    }
    expect(ClarifyDraft.fromJson({'tool': 'drop', 'title': 'x'}), isNull);
    expect(
        ClarifyDraft.fromJson(
            {'tool': 'create_task', 'title': 'x', 'multiple': 'yes'}),
        isNull);
    expect(
        ClarifyDraft.fromJson(
            {'tool': 'create_task', 'title': 'x', 'time': '25 o\'clock'}),
        isNull);
    expect(
        ClarifyDraft.fromJson(
                {'tool': 'create_reminder', 'title': 'x', 'time': '8:10 AM'})!
            .time,
        '8:10 AM');
  });

  test('"that" is the task a reminder is about, never just the newest task',
      () async {
    final s = await open();
    model.plans['remind me to buy milk at 5pm'] =
        '{"intent":"create_reminder","title":"buy milk","when":"5pm"}';
    await s
        .handle('remind me to buy milk at 5pm'); // older task, with its alerts
    await tasks.create('buy bread'); // newer, unrelated
    await s.handle('remind me to buy milk at 5pm'); // repeat: no new task
    expect(await tasks.byTitle('buy milk'), hasLength(1));
    model.plans['mark that done'] = '{"intent":"complete","ref":"that"}';
    await s.handle('mark that done');
    expect((await one('buy milk')).done, isTrue);
    expect((await one('buy bread')).done, isFalse);
  });

  test('a standalone reminder leaves no task context', () async {
    await tasks.create('buy bread');
    final s = AssistantSession(
      engine: model,
      tools: ToolExecutor(tasks, reminders, _Memory(db), NoopScheduler(),
          clock: () => _now),
      memory: _Memory(db),
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      pending: PendingRepo(db),
      clock: () => _now,
    );
    await s.start();
    model.plans['remind me to stretch at 5pm'] =
        '{"intent":"create_reminder","title":"stretch","when":"5pm"}';
    await s.handle('remind me to stretch at 5pm');
    model.plans['mark that done'] = '{"intent":"complete","ref":"that"}';
    expect(await s.handle('mark that done'), contains('Which one'));
    expect((await one('buy bread')).done, isFalse);
  });
}
