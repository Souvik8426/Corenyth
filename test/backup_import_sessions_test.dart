import 'dart:async';
import 'dart:io';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/backup/backup_format.dart';
import 'package:assistant/services/backup/backup_service.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:assistant/services/session_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'support/backup_fixture.dart';

const _timeout = Duration(seconds: 5);

/// Answers the create-task plan; cancel is recorded and does not stop a tool.
class _Engine extends LlmEngine {
  final cancelStarted = Completer<void>();

  @override
  String get name => 'held-import';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}
  @override
  Future<String> complete(Prompt p) async =>
      '{"intent":"create_task","title":"buy milk"}';
  @override
  Future<void> cancel() async {
    if (!cancelStarted.isCompleted) cancelStarted.complete();
  }
}

/// Holds `create_task` until [release]: a write in flight during the import.
class _HeldTools extends ToolExecutor {
  _HeldTools(super.tasks, super.reminders, super.memory, super.scheduler);
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<ExecutionReceipt> run(ToolCall c,
      {String? operationId,
      bool recovering = false,
      MemoryWriteSource? memorySource}) async {
    if (c.tool == 'create_task') {
      if (!started.isCompleted) started.complete();
      await release.future;
    }
    return super.run(c,
        operationId: operationId,
        recovering: recovering,
        memorySource: memorySource);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late BackupHarness h;
  late _Engine engine;
  late _HeldTools tools;
  late AssistantSession session;
  late SessionRegistry registry;
  late BackupPreview preview;
  late TaskRepo tasks;

  Future<List<String>> titles() async =>
      [for (final t in await tasks.list()) t.title];

  Future<void> setUpWorld({Duration settle = _timeout}) async {
    db = await openTestDb();
    tasks = TaskRepo(db);
    h = BackupHarness(db, await tempFolder());
    // The backup holds one task; the live data then differs from it.
    await tasks.create('from backup');
    final path = await h.export();
    await db.delete('tasks');
    await tasks.create('local only');

    engine = _Engine();
    tools = _HeldTools(
        tasks, ReminderRepo(db), MemoryRepo(db), NoopScheduler());
    session = AssistantSession(
      engine: engine,
      tools: tools,
      memory: tools.memory,
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      pending: PendingRepo(db),
      conversationId: 'import-chat',
    );
    await session.start();
    registry = SessionRegistry(settleTimeout: settle)..register(session);
    h.service.sessions = registry;
    preview = await h.service.readAndCheck(path);
    addTearDown(() async {
      if (!tools.release.isCompleted) tools.release.complete();
      await session.close();
    });
  }

  test('import settles an in-flight turn first, then restores exactly the backup',
      () async {
    await setUpWorld();
    final turn = session.handle('add task buy milk');
    await tools.started.future.timeout(_timeout);
    expect(session.hasActiveTurn, isTrue);

    final importing = h.service.importBackup(preview);
    // The import cancels the turn and waits; the running write may finish.
    await engine.cancelStarted.future.timeout(_timeout);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await titles(), ['local only'],
        reason: 'the restore must not start while the turn is unsettled');
    tools.release.complete();

    final result = await importing.timeout(_timeout);
    await turn.timeout(_timeout).catchError((_) => '');
    expect(await titles(), ['from backup'],
        reason: 'a late write from the old turn must not survive the restore');
    expect(session.hasActiveTurn, isFalse);
    expect(session.writesPaused, isFalse, reason: 'sessions resume after');

    // The recovery copy was taken after the turn settled, so it holds the
    // turn's committed write.
    final recovery = await h.service.readAndCheck(result.path);
    expect([for (final t in recovery.data.tasks) t['title']],
        containsAll(['local only', 'buy milk']));
  });

  test('turns are blocked during the restore and resume afterwards', () async {
    await setUpWorld();
    Object? duringRestore;
    h.service.testHook = (step) async {
      if (step == 'restore') {
        try {
          await session.handle('add task blocked');
        } catch (e) {
          duringRestore = e;
        }
      }
    };
    await h.service.importBackup(preview);
    expect(duringRestore, isA<StateError>());
    expect(await titles(), ['from backup']);
    tools.release.complete();
    expect(await session.handle('add task buy milk').timeout(_timeout),
        contains('buy milk'));
  });

  test('sessions resume when the restore itself fails', () async {
    await setUpWorld();
    h.service.testHook = (step) async {
      if (step == 'restore') throw StateError('disk full');
    };
    await expectLater(
        h.service.importBackup(preview), throwsA(isA<BackupException>()));
    expect(await titles(), ['local only']);
    expect(session.writesPaused, isFalse);
    expect(registry.suspended, isFalse);
  });

  test('fails closed: unsettled session aborts the import, data unchanged',
      () async {
    await setUpWorld(settle: const Duration(milliseconds: 200));
    final turn = session.handle('add task buy milk');
    await tools.started.future.timeout(_timeout);
    final before = {
      for (final t in ['tasks', 'reminders', 'conversations', 'operations'])
        t: await db.query(t, orderBy: 'rowid'),
    };
    final files = Directory(h.folder.path).listSync().length;

    await expectLater(
        h.service.importBackup(preview),
        throwsA(isA<BackupException>().having((e) => e.message, 'message',
            allOf(contains('not imported'), contains('unchanged')))));

    expect(h.service.lastError.value, contains('unchanged'));
    expect(h.service.busy.value, isFalse);
    expect(Directory(h.folder.path).listSync(), hasLength(files),
        reason: 'no recovery copy is written for a refused import');
    for (final t in before.keys) {
      expect(await db.query(t, orderBy: 'rowid'), before[t], reason: t);
    }
    expect(session.writesPaused, isFalse,
        reason: 'a refused import leaves the session usable');
    expect(registry.suspended, isFalse);

    tools.release.complete();
    await turn.timeout(_timeout);
    expect(await titles(), containsAll(['local only', 'buy milk']));
    expect(await titles(), isNot(contains('from backup')));
  });
}
