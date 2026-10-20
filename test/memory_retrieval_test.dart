import 'dart:io';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'screenshot_replies_test.dart' show ScriptedEngine;
import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/assistant/engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('memory-real-');
    db = await openAppDb(path: '${dir.path}/test.db');
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
  });
  test(
      'real FTS retrieval, correction, provenance and deletion survive restart',
      () async {
    final repo = MemoryRepo(db);
    final old = await repo.add('I prefer short answers',
        category: 'preference', source: 'chat:A', opId: 'turn1');
    await repo.add('I prefer coffee without sugar', category: 'preference');
    final corrected = await repo.add('I prefer detailed answers',
        category: 'preference', source: 'chat:B', opId: 'turn2');
    expect(await repo.search('short'), isEmpty);
    final active = await repo.relevantForContext('answers');
    expect(active.first.id, corrected);
    expect(active.any((m) => m.id == old), isFalse);
    expect((await repo.search('coffee')).single.content,
        contains('without sugar'));
    expect(active.first.source, 'chat:B');
    final recreated = MemoryRepo(db);
    await recreated.delete(corrected);
    expect(await recreated.search('answers'), isEmpty);
    expect(
        (await recreated.relevantForContext('answers'))
            .any((m) => m.id == corrected),
        isFalse);
  });
  test('older task relevance is ranked before prompt caps', () async {
    final repo = TaskRepo(db);
    for (var i = 0; i < 15; i++) {
      await repo.create('routine $i');
    }
    final target = await repo.create('submit astronomy proposal');
    expect((await repo.relevantTasks('astronomy', cap: 3)).first.id, target.id);
    expect((await repo.relevantTasks('#${target.id}', cap: 3)).first.id,
        target.id);
  });
  test('production repositories inject active memory into planning and replies',
      () async {
    final memory = MemoryRepo(db), tasks = TaskRepo(db);
    await memory.add('I prefer short answers', category: 'preference');
    final model = ScriptedEngine();
    model.outputs[PromptKind.plan] =
        '{"intent":"chat","reply":"Let us work through that."}';
    model.outputs[PromptKind.reply] =
        '{"type":"respond","text":"That sounds promising."}';
    final session = AssistantSession(
        engine: model,
        tools: ToolExecutor(tasks, ReminderRepo(db), memory, NoopScheduler()),
        memory: memory,
        profile: ProfileRepo(db),
        taskRepo: tasks,
        conversations: ConversationRepo(db));
    await session.start();
    addTearDown(session.close);
    await session.handle('I am thinking about answers for my presentation');
    expect(model.prompts.where((p) => p.kind == PromptKind.plan), isNotEmpty);
    expect(
        model.prompts
            .firstWhere((p) => p.kind == PromptKind.plan)
            .render(),
        contains('short answers'));
    await tasks.create('call Aditya');
    await session.handle("Aditya hasn't replied");
    expect(model.prompts.where((p) => p.kind == PromptKind.reply), isNotEmpty);
    expect(
        model.prompts
            .firstWhere((p) => p.kind == PromptKind.reply)
            .personalContext,
        contains('short answers'));
    await session.handle('actually I prefer detailed answers now');
    expect(await memory.search('short'), isEmpty);
    expect(
        (await memory.search('detailed')).single.content, contains('detailed'));
    await session.handle('forget that I prefer detailed answers');
    expect(await memory.search('detailed'), isEmpty);
    model.prompts.clear();
    await session.handle('Can we discuss my presentation answers again?');
    expect(model.prompts.every((p) => !p.render().contains('short answers')),
        isTrue);
  });
  test('bounded prompt candidates retain current request and pending fields',
      () {
    final p = Prompt(PromptKind.plan, 'CURRENT REQUEST',
        tasks: '#42 astronomy',
        pending: 'reminder needs time',
        personalContext: 'optional preference',
        history: [Message('user', 'old words')]);
    for (final candidate in p.candidates()) {
      expect(candidate, contains('CURRENT REQUEST'));
      expect(candidate, contains('reminder needs time'));
      expect(candidate, contains('#42 astronomy'));
    }
  });
}
