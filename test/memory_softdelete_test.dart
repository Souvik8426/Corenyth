import 'dart:io';

import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:assistant/theme/app_theme.dart';
import 'package:assistant/ui/memories_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _WidgetMemoryRepo extends MemoryRepo {
  _WidgetMemoryRepo(super.db);
  final row = Memory({
    'id': 1,
    'content': 'I prefer quiet mornings',
    'category': 'preference',
    'importance': 0.5,
  });
  bool isDeleted = false;

  @override
  Future<bool> legacyErasureBlocked() async => false;

  @override
  Future<List<Memory>> all() async => isDeleted ? [] : [row];

  @override
  Future<List<Memory>> deleted() async => isDeleted ? [row] : [];

  @override
  Future<bool> delete(int id, {String actor = 'user', String? opId}) async {
    isDeleted = true;
    return true;
  }

  @override
  Future<RestoreResult> restore(int id) async {
    isDeleted = false;
    return RestoreResult(RestoreStatus.restored, id);
  }
}

class _WidgetProfileRepo extends ProfileRepo {
  _WidgetProfileRepo(super.db);

  @override
  Future<UserProfile?> get() async => const UserProfile(name: 'Ada');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late MemoryRepo repo;
  late DateTime now;
  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('memory-softdelete-');
    db = await openAppDb(path: '${dir.path}/test.db');
    now = DateTime.utc(2026, 10, 31);
    repo = MemoryRepo(db, clock: () => now);
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
  });

  test('delete excludes every active read and keeps a deleted row and history',
      () async {
    final id =
        await repo.add('I prefer quiet mornings', category: 'preference');
    expect((await repo.search('quiet')).single.id, id);
    expect((await repo.all()).single.id, id);
    expect((await repo.important()).single.id, id);
    expect((await repo.relevantForContext('quiet')).single.id, id);
    expect(await repo.delete(id, actor: 'user', opId: 'forget-1'), isTrue);
    expect(await repo.search('quiet'), isEmpty);
    expect(await repo.all(), isEmpty);
    expect(await repo.important(), isEmpty);
    expect(await repo.relevantForContext('quiet'), isEmpty);
    expect(await repo.activeIdForContent('I prefer quiet mornings'), isNull);
    expect((await repo.matchForForget('I prefer quiet mornings')).evidence,
        ForgetEvidence.none);
    expect((await repo.deleted()).single.id, id);
    final row = (await db.query('memories')).single;
    expect(row['deleted_at'], now.millisecondsSinceEpoch);
    final history = await repo.history(id);
    expect(history.map((e) => e['event']), ['add', 'delete']);
    expect(history.last['actor'], 'user');
    expect(history.last['op_id'], 'forget-1');
    expect(await repo.delete(id), isFalse);
    expect(await repo.history(id), hasLength(2));
  });

  test('restore reindexes the memory and logs exactly one restore', () async {
    final id = await repo.add('I prefer quiet mornings');
    await repo.delete(id);
    final result = await repo.restore(id);
    expect(result.status, RestoreStatus.restored);
    expect(result.id, id);
    expect((await repo.search('quiet')).single.id, id);
    expect((await db.query('memories')).single['deleted_at'], isNull);
    expect((await repo.history(id)).map((e) => e['event']),
        ['add', 'delete', 'restore']);
    expect((await repo.restore(id)).status, RestoreStatus.gone);
  });

  test('restore duplicate returns active id without changing deleted row',
      () async {
    final id = await repo.add('I prefer quiet mornings');
    await repo.delete(id);
    final active = await repo.add('I prefer quiet mornings');
    final result = await repo.restore(id);
    expect(result.status, RestoreStatus.duplicate);
    expect(result.id, active);
    expect((await repo.all()).single.id, active);
    expect((await repo.deleted()).single.id, id);
    expect(await repo.history(id), hasLength(2));
  });

  test('restore refuses a refilled slot', () async {
    final id = await repo.add('User likes coffee');
    await repo.delete(id);
    final active = await repo.add('User likes tea');
    expect((await repo.restore(id)).status, RestoreStatus.slotTaken);
    expect((await repo.all()).single.id, active);
    expect(await repo.history(id), hasLength(2));
  });

  test('permanent purge removes row and FTS and redacts retained history',
      () async {
    final id = await repo.add('I prefer quiet mornings');
    await repo.delete(id);
    await repo.restore(id);
    expect(await repo.deletePermanently(id), isTrue);
    expect(await db.query('memories'), isEmpty);
    expect(await db.query('memories_fts'), isEmpty);
    final history = await repo.history(id);
    expect(history.last['event'], 'purge');
    for (final row in history) {
      expect(row['old_content'], isNull);
      expect(row['new_content'], isNull);
    }
    expect(await repo.deletePermanently(id), isFalse);
    expect((await repo.restore(id)).status, RestoreStatus.gone);
  });

  test('purge and restore respect inclusive 30-day undo boundary', () async {
    final id = await repo.add('I prefer quiet mornings');
    await repo.delete(id);
    now = now.add(const Duration(days: 30));
    expect(await repo.purgeDeleted(), 0);
    expect((await repo.restore(id)).status, RestoreStatus.restored);
    await repo.delete(id);
    now = now.add(const Duration(days: 30, milliseconds: 1));
    expect((await repo.restore(id)).status, RestoreStatus.gone);
    final active = await repo.add('I work as a designer');
    expect(await repo.purgeDeleted(), 1);
    expect((await repo.all()).single.id, active);
    expect(await repo.deleted(), isEmpty);
    expect((await repo.history(id)).last['event'], 'purge');
  });

  for (final event in ['delete', 'restore', 'purge']) {
    test('$event history failure rolls back memory, FTS and redaction',
        () async {
      final id = await repo.add('I prefer quiet mornings');
      if (event != 'delete') await repo.delete(id);
      final before = await db.query('memories');
      final history = await repo.history(id);
      final fts = await db.query('memories_fts');
      await db.execute(
          '''CREATE TRIGGER fail_history BEFORE INSERT ON memory_history
        WHEN new.event = '$event' BEGIN
        SELECT RAISE(ABORT, 'forced history failure'); END''');
      await expectLater(
          switch (event) {
            'delete' => repo.delete(id),
            'restore' => repo.restore(id),
            _ => repo.deletePermanently(id),
          },
          throwsA(isA<DatabaseException>()));
      expect(await db.query('memories'), before);
      expect(await db.query('memories_fts'), fts);
      expect(await repo.history(id), history);
    });
  }

  test('delete_memory returns undo reply and persists provenance', () async {
    final id = await repo.add('I prefer quiet mornings');
    final executor =
        ToolExecutor(TaskRepo(db), ReminderRepo(db), repo, NoopScheduler());
    final call = ToolCall('delete_memory', {'id': id});
    final receipt = await executor.run(call, operationId: 'delete-op');
    expect(receipt.reply,
        'Forgot "I prefer quiet mornings". Say "undo" to bring it back.');
    final event = (await repo.history(id)).last;
    expect(event['actor'], 'user');
    expect(event['op_id'], 'delete-op');
    expect((await executor.run(call, recovering: true)).reply, receipt.reply);
    expect(await repo.history(id), hasLength(2));
  });

  testWidgets('SnackBar Undo restores a soft-deleted memory', (tester) async {
    final memory = _WidgetMemoryRepo(db);
    final id = memory.row.id;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
          body: MemoriesPage(memory: memory, profile: _WidgetProfileRepo(db))),
    ));
    await tester.pumpAndSettle();
    final delete = find.byKey(Key('delete-memory-$id'));
    await tester.ensureVisible(delete);
    await tester.tap(delete);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Memory deleted'), findsOneWidget);
    final snack = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snack.duration, const Duration(seconds: 5));
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect((await memory.all()).single.id, id);
    expect(await memory.deleted(), isEmpty);
    expect(find.byKey(Key('delete-memory-$id')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
