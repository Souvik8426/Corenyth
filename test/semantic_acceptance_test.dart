import 'dart:convert';

import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backend_test.dart' show FakeMemory, SpyEngine;
import 'support/v2_db.dart';

void main() {
  final now = DateTime(2099, 10, 14, 7);
  late TaskRepo tasks;
  late PendingRepo pending;
  late SpyEngine model;
  late AssistantSession session;
  setUp(() async {
    final db = await openMigratedV2();
    tasks = TaskRepo(db);
    pending = PendingRepo(db);
    final memory = FakeMemory();
    model = SpyEngine();
    session = AssistantSession(
      engine: model,
      tools: ToolExecutor(tasks, ReminderRepo(db), memory, NoopScheduler(),
          clock: () => now),
      memory: memory,
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      pending: pending,
      clock: () => now,
    );
    await session.start();
    addTearDown(session.close);
  });

  test('semantic slang capture invokes the model and writes SQLite', () async {
    model.output = jsonEncode({
      'intent': 'create_task',
      'title': 'check dev console',
      'when': 'tomo'
    });
    await session.handle('I hv to check dev console tomo');
    final task = (await tasks.list()).single;
    expect(task.title, 'check dev console');
    expect(task.dueAt?.day, 15);
    expect(model.calls, 1);
  });

  test('tomorrow answer queries stored tasks rather than copying an old reply',
      () async {
    await tasks.create('today only', due: now);
    await tasks.create('tomorrow only', due: DateTime(2099, 10, 15, 9));
    await tasks.create('undated');
    model.output = jsonEncode({'intent': 'list', 'range': 'tomorrow'});
    final reply = await session.handle(
        'Wow that was fast soo tell me what are the things which are pending for tomorrow');
    expect(reply, contains('tomorrow only'));
    expect(reply, isNot(contains('today only')));
    expect(reply, isNot(contains('undated')));
    expect(model.calls, 1);
  });

  test('a model must not complete bring milk when the user bought milk',
      () async {
    final buy = await tasks.create('buy milk');
    final bring = await tasks.create('bring milk');
    model.output = jsonEncode({'intent': 'complete', 'ref': 'bring milk'});
    await session.handle('Okay i am done with buying milk');
    expect((await tasks.get(bring.id))!.done, isFalse);
    expect((await tasks.get(buy.id))!.done, isTrue);
  });

  test('a model cannot create a task from an explanatory question', () async {
    model.output = jsonEncode({'intent': 'create_task', 'title': 'buy milk'});
    await session.handle('How do I buy milk?');
    expect(await tasks.list(), isEmpty);
  });

  test(
      'an omitted model range cannot remove the user requested tomorrow filter',
      () async {
    await tasks.create('today only', due: now);
    await tasks.create('tomorrow only', due: DateTime(2099, 10, 15, 9));
    model.output = jsonEncode({'intent': 'list'});
    final reply = await session.handle('tell me what is pending for tomorrow');
    expect(reply, contains('tomorrow only'));
    expect(reply, isNot(contains('today only')));
  });

  test('personal task queries cannot be answered by ungrounded chat prose',
      () async {
    await tasks.create('tomorrow only', due: DateTime(2099, 10, 15, 9));
    model.output =
        jsonEncode({'intent': 'chat', 'reply': 'Nothing left for tomorrow.'});
    final reply = await session.handle('tell me what is pending for tomorrow');
    expect(reply, isNot('Nothing left for tomorrow.'));
    expect(reply, contains('tomorrow only'));
  });

  test('a reassuring chat answer cannot bypass a fresh task query', () async {
    await tasks.create('tomorrow only', due: DateTime(2099, 10, 15, 9));
    model.output = jsonEncode({'intent': 'chat', 'reply': "You're all set."});
    final reply = await session.handle('tell me what is pending for tomorrow');
    expect(reply, contains('tomorrow only'));
  });

  test('an explicit task date is retained even if the model omits when',
      () async {
    model.output =
        jsonEncode({'intent': 'create_task', 'title': 'check dev console'});
    await session.handle('I hv to check dev console tomo');
    final task = (await tasks.list()).single;
    expect(task.dueAt?.day, 15);
  });

  test('a model cannot silently drop a second commitment', () async {
    model.output = jsonEncode({'intent': 'create_task', 'title': 'buy eggs'});
    await session.handle('I need to buy eggs and call Mum');
    expect(await tasks.list(), isEmpty,
        reason: 'save both or clarify before saving either');
  });

  test(
      'an explicit reminder cannot become a silent task on a wrong model intent',
      () async {
    model.output = jsonEncode({
      'intent': 'create_task',
      'title': 'call Mum',
      'when': 'tomorrow at 8am'
    });
    final reply = await session.handle('remind me to call Mum tomorrow at 8am');
    expect(reply.toLowerCase(), contains('remind'));
  });
}
