import 'dart:convert';

import 'package:assistant/assistant/authorization.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/assistant/turn_contract.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/app_services.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/v2_db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('production session factory journals and replays an operation', () async {
    final db = await openMigratedV2();
    final services = AppServices(db, NoopScheduler(), '/missing/model.gguf');
    final session = services.newSession(conversationId: 'production-composition');
    await session.start();
    addTearDown(session.close);
    expect(session.operations, isNotNull,
        reason: 'the operation journal must be wired in the real app factory');
    const message = 'add task inspect production journal';
    const operation = 'parent-composition-op';
    final reply = await session.handle(message, operationId: operation);
    expect(await db.query('operations', where: 'op_id = ?', whereArgs: [operation]),
        hasLength(1));
    await session.handle(message, operationId: operation);
    expect(await services.tasks.list(), hasLength(1), reason: reply);
  });

  test('session journal and replay persists across AppServices and session reconstruction', () async {
    final db = await openMigratedV2();
    const message = 'add task check cross-reconstruction persistence';
    const operation = 'cross-reconstruction-op';

    // Instance 1: services and session
    final services1 = AppServices(db, NoopScheduler(), '/missing/model.gguf');
    final session1 = services1.newSession(conversationId: 'cross-recon-chat');
    await session1.start();
    final reply1 = await session1.handle(message, operationId: operation);
    expect(reply1, contains('check cross-reconstruction persistence'));
    expect(await services1.tasks.list(), hasLength(1));
    await session1.close();

    // Instance 2: reconstruct AppServices and session anew against the same database
    final services2 = AppServices(db, NoopScheduler(), '/missing/model.gguf');
    final session2 = services2.newSession(conversationId: 'cross-recon-chat');
    await session2.start();
    addTearDown(session2.close);

    // Replay across reconstruction returns the same reply and never duplicates rows
    final reply2 = await session2.handle(message, operationId: operation);
    expect(reply2, reply1);
    expect(await services2.tasks.list(), hasLength(1),
        reason: 'must not duplicate task on reconstructed session replay');
    final op = await services2.operations.get(operation);
    expect(op, isNotNull);
    expect(op!.status, OperationJournal.replied);
  });

  test('crashed executing operation recovers across service reconstruction without duplicates', () async {
    final db = await openMigratedV2();
    const message = 'add task pay electric bill';
    const operation = 'crashed-recon-op';
    final hash = sha256.convert(utf8.encode(message)).toString().substring(0, 16);

    final journal = OperationJournal(db);
    await journal.begin(operation, 'crash-chat', hash);

    // Simulate task created in DB before crash
    final tasks = TaskRepo(db);
    final preTask = await tasks.create('pay electric bill', opId: operation);

    final plan = CandidatePlan(
      interpreter: Interpreter.legacy,
      route: RouteId.rules,
      call: ToolCall('create_task', {'title': 'pay electric bill'}),
      evidence: {'title': 'said'},
      authorization: const AuthorizationReading(Authorization.request, 'cue'),
    );
    await journal.mark(operation, OperationJournal.executing, action: plan.toActionJson());

    // Reconstruct AppServices and session
    final services = AppServices(db, NoopScheduler(), '/missing/model.gguf');
    final session = services.newSession(conversationId: 'crash-chat');
    await session.start();
    addTearDown(session.close);

    final reply = await session.handle(message, operationId: operation);
    expect(reply, contains('pay electric bill'));
    expect(await services.tasks.list(), hasLength(1));
    expect((await services.tasks.list()).single.id, preTask.id);

    final op = await services.operations.get(operation);
    expect(op!.status, OperationJournal.replied);
  });

  test('startup crash reconciliation does not abandon operations active in another engine or within timeout', () async {
    final db = await openMigratedV2();
    final journal = OperationJournal(db);

    // 1. Operation currently active in memory
    journal.registerActive('active-op-1');
    await journal.begin('active-op-1', 'chat', 'hash1');

    // 2. Operation recently updated (within threshold)
    await journal.begin('recent-op-2', 'chat', 'hash2');

    // 3. Stale operation older than threshold with no rows
    await journal.begin('stale-op-3', 'chat', 'hash3');
    await db.update('operations',
        {'updated_at': DateTime.now().millisecondsSinceEpoch - 600000},
        where: 'op_id = ?', whereArgs: ['stale-op-3']);

    // 4. Stale operation older than threshold WITH rows
    await journal.begin('stale-op-4', 'chat', 'hash4');
    await db.insert('tasks', {
      'title': 'written before crash',
      'created_at': 1,
      'status': 'pending',
      'priority': 1,
      'op_id': 'stale-op-4',
    });
    await db.update('operations',
        {'updated_at': DateTime.now().millisecondsSinceEpoch - 600000},
        where: 'op_id = ?', whereArgs: ['stale-op-4']);

    final settled = await journal.recoverStale(olderThan: const Duration(minutes: 2));

    // Active in memory must NOT be abandoned
    expect(settled, isNot(contains('active-op-1')));
    expect((await journal.get('active-op-1'))!.status, OperationJournal.started);

    // Recent must NOT be abandoned
    expect(settled, isNot(contains('recent-op-2')));
    expect((await journal.get('recent-op-2'))!.status, OperationJournal.started);

    // Genuinely stale with no rows is abandoned
    expect(settled, contains('stale-op-3'));
    expect((await journal.get('stale-op-3'))!.status, OperationJournal.abandoned);

    // Genuinely stale with rows is committed
    expect(settled, contains('stale-op-4'));
    expect((await journal.get('stale-op-4'))!.status, OperationJournal.committed);
  });
}
