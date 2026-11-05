import 'dart:convert';
import 'dart:io';

import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late MemoryRepo memory;
  late PendingRepo pending;
  late ToolExecutor executor;
  late AssistantSession session;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('memory-forget-');
    db = await openAppDb(path: '${dir.path}/test.db');
    memory = MemoryRepo(db);
    pending = PendingRepo(db);
    final tasks = TaskRepo(db);
    executor = ToolExecutor(tasks, ReminderRepo(db), memory, NoopScheduler());
    session = AssistantSession(
      engine: RuleEngine(),
      tools: executor,
      memory: memory,
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      pending: pending,
    );
    await session.start();
    addTearDown(() async {
      await session.close();
      await db.close();
      await dir.delete(recursive: true);
    });
  });

  test('F1 exact fact deletes with exact_memory evidence', () async {
    final id = await memory.add('User likes green tea');
    expect(await session.handle('forget that I like green tea'),
        allOf(startsWith('Forgot "'), contains('undo')));
    expect(await memory.all(), isEmpty);
    final deleted =
        (await db.query('memories', where: 'id = ?', whereArgs: [id])).single;
    expect(deleted['status'], 'deleted');
    expect(deleted['deleted_at'], isA<int>());
    expect(session.lastTurn!.plan.evidence['target'], 'exact_memory');
  });

  test('F2 unrelated wake-up terms never delete the morning coffee', () async {
    final id = await memory.add('User drinks coffee every morning');
    final reply = await session.handle('forget that I wake up every morning');
    expect((await memory.all()).single.id, id);
    // The every-value-term rule excludes this partial retrieval hit.
    expect(reply, contains("couldn't identify"));
    expect(await pending.get('pick:${session.id}'), isNull);
  });

  test('F3 a filtered candidate is stored and #id deletes with pick evidence',
      () async {
    final id = await memory.add('User drinks coffee every morning');
    final reply = await session.handle('forget every morning');
    expect(reply,
        'Which memory should I forget?\n#$id User drinks coffee every morning');
    expect((await memory.all()).single.id, id);
    final pick = jsonDecode((await pending.get('pick:${session.id}'))!) as Map;
    expect(pick['tool'], 'delete_memory');
    expect(pick['ids'], [id]);
    expect(pick['args'], isEmpty);
    expect(await session.handle('#$id'),
        allOf(startsWith('Forgot "'), contains('undo')));
    expect(await memory.all(), isEmpty);
    final deleted =
        (await db.query('memories', where: 'id = ?', whereArgs: [id])).single;
    expect(deleted['status'], 'deleted');
    expect(deleted['deleted_at'], isA<int>());
    expect(session.lastTurn!.plan.evidence['target'], 'pick');
    expect(await pending.get('pick:${session.id}'), isNull);
  });

  test('F4 shared slot and coffee value deletes with slot_memory evidence',
      () async {
    final id = await memory.add('User prefers black coffee');
    expect(await session.handle('forget that I like coffee'),
        allOf(startsWith('Forgot "'), contains('undo')));
    expect(await memory.all(), isEmpty);
    final deleted =
        (await db.query('memories', where: 'id = ?', whereArgs: [id])).single;
    expect(deleted['status'], 'deleted');
    expect(deleted['deleted_at'], isA<int>());
    expect(session.lastTurn!.plan.evidence['target'], 'slot_memory');
  });

  test('F5 shared slot without a value match preserves tea', () async {
    final id = await memory.add('User prefers tea');
    expect(await session.handle('forget that I like coffee'),
        contains("couldn't identify"));
    expect((await memory.all()).single.id, id);
  });

  test('F6 empty memory has no match', () async {
    expect(await session.handle('forget that I like tea'),
        contains("couldn't identify"));
    expect(await memory.all(), isEmpty);
  });

  test('F7 four value-matching candidates require selection in Memories',
      () async {
    for (final fact in [
      'User visited pune',
      'User studied in pune',
      'User has family in pune',
      'User travels to pune',
    ]) {
      await memory.add(fact);
    }
    expect(await session.handle('forget that I live in pune'),
        'Several memories match. Please choose one in Memories.');
    expect(await memory.all(), hasLength(4));
    expect(await pending.get('pick:${session.id}'), isNull);
  });

  test('F8 forget it retains the pronoun guard', () async {
    final id = await memory.add('User likes tea');
    await session.handle('forget it');
    expect(session.lastTurn!.plan.route, isNot(RouteId.explicitMemory));
    expect((await memory.all()).single.id, id);
  });

  test('F9 executor rejects query-only and non-integer ids without deletion',
      () async {
    final id = await memory.add('User likes tea');
    for (final args in <Map<String, Object?>>[
      {'query': 'tea'},
      {},
      {'id': '$id'},
      {'id': 1.0},
    ]) {
      await expectLater(
          executor.execute(ToolCall('delete_memory', args)),
          throwsA(isA<ToolError>().having(
              (e) => e.message, 'message', 'delete_memory needs an id')));
      expect((await memory.all()).single.id, id);
    }
  });

  test('exact matching normalizes spaces, case and trailing punctuation',
      () async {
    final id = await memory.add('  User likes green   tea.!?  ');
    final match = await memory.matchForForget(' USER likes green tea!! ');
    expect(match.evidence, ForgetEvidence.exact);
    expect(match.memories.single.id, id);
  });

  test('superseded exact hashes cannot target inactive memories', () async {
    await memory.add('User likes green tea');
    final active = await memory.add('User likes black coffee');
    final match = await memory.matchForForget('User likes green tea');
    expect(match.evidence, ForgetEvidence.none);
    expect(match.memories, isEmpty);
    expect((await memory.all()).single.id, active);
  });

  test('empty value terms do not offer every memory as a candidate', () async {
    await memory.add('User likes tea');
    final match = await memory.matchForForget('User likes');
    expect(match.evidence, ForgetEvidence.none);
    expect(match.memories, isEmpty);
  });
}
