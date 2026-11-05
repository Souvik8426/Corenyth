import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/backup/backup_format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/backup_fixture.dart';

final _now = DateTime.utc(2026, 10, 31);
final _old = _now.subtract(const Duration(days: 31)).millisecondsSinceEpoch;

Map<String, Object?> _memory(int id, String content,
        {String status = 'active', int? successor, bool expired = false}) =>
    {
      'id': id,
      'content': content,
      'category': 'fact',
      'importance': 0.5,
      'createdAt': 1,
      'updatedAt': 1,
      'lastAccessedAt': null,
      'opId': null,
      'source': null,
      'status': status,
      'supersededBy': successor,
      'observedAtUtc': null,
      'observationOffsetMin': null,
      'factDate': null,
      'deletedAt': status == 'deleted' ? _old : null,
      'expiresAt': expired ? _now.millisecondsSinceEpoch : null,
    };

Map<String, Object?> _event(int id, int owner, String event,
        {String? old, String? text}) =>
    {
      'id': id,
      'memoryId': owner,
      'event': event,
      'oldContent': old,
      'newContent': text,
      'actor': 'user',
      'opId': null,
      'createdAt': id,
    };

Future<Map<String, Object?>> _snapshot(DatabaseExecutor db) async => {
      for (final table in [
        'memories',
        'memory_history',
        'memories_fts',
        'extraction_state',
        'extraction_sources',
      ])
        table: table == 'memories_fts'
            ? await db.query(table, columns: ['docid', 'content'])
            : await db.query(table),
    };

/// Counts guard reads while retaining real transaction/savepoint behavior.
class _CountingTransaction extends Fake implements Transaction {
  final Transaction tx;
  final List<String> guards;
  _CountingTransaction(this.tx, this.guards);

  @override
  Future<List<Map<String, Object?>>> query(String table,
      {bool? distinct, List<String>? columns, String? where,
      List<Object?>? whereArgs, String? groupBy, String? having,
      String? orderBy, int? limit, int? offset}) {
    if (table == 'memory_history' && (where?.contains("event = 'supersede'") ?? false)) {
      guards.add(where!);
    }
    return tx.query(table, distinct: distinct, columns: columns, where: where,
        whereArgs: whereArgs, groupBy: groupBy, having: having,
        orderBy: orderBy, limit: limit, offset: offset);
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      tx.execute(sql, arguments);

  @override
  Future<int> insert(String table, Map<String, Object?> values,
      {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      tx.insert(table, values, nullColumnHack: nullColumnHack,
          conflictAlgorithm: conflictAlgorithm);

  @override
  Future<int> update(String table, Map<String, Object?> values,
      {String? where, List<Object?>? whereArgs, ConflictAlgorithm? conflictAlgorithm}) =>
      tx.update(table, values, where: where, whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) =>
      tx.delete(table, where: where, whereArgs: whereArgs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late MemoryRepo repo;
  late BackupHarness h;
  final guardQueries = <String>[];
  setUp(() async {
    final dir = await tempFolder();
    guardQueries.clear();
    db = await openAppDb(path: '${dir.path}/import.db');
    addTearDown(db.close);
    repo = MemoryRepo(db, clock: () => _now);
    h = BackupHarness(db, await tempFolder());
  });

  // Every regression goes through the actual archive validator AND restore;
  // no SQL edits stand in for the imported initial state.
  Future<void> importFixture(List<Map<String, Object?>> memories,
      List<Map<String, Object?>> history) async {
    final entries = readEntries(await h.export());
    final data = Map<String, Object?>.from(entries[dataEntryName] as Map);
    final manifest =
        Map<String, Object?>.from(entries[manifestEntryName] as Map);
    data['memories'] = memories;
    data['memoryHistory'] = history;
    (manifest['counts'] as Map)['memories'] = memories.length;
    (manifest['counts'] as Map)['memoryHistory'] = history.length;
    final file = writeArchive(h.folder, manifest, data);
    final preview = await h.service.readAndCheck(file);
    expect(preview.data.memoryHistory, hasLength(history.length));
    await h.service.importBackup(preview);
    expect(await db.query('memories'), hasLength(memories.length));
    expect(await db.query('memory_history'), preview.data.memoryHistory);
    // Importing a compatible archive must not silently discard history text.
  }

  Future<void> revalidateRoundTrip() async {
    final before = await _snapshot(db);
    final preview = await h.service.readAndCheck(await h.export());
    await h.service.importBackup(preview);
    expect(await _snapshot(db), before);
    await h.service.readAndCheck(await h.export());
  }

  Matcher blocked(int id) => isA<MemoryPrivacyBlocked>()
      .having((e) => e.memoryId, 'memoryId', id)
      .having(
          (e) => e.toString(),
          'transparent outcome',
          allOf(contains('No permanent erasure was performed'),
              contains('privacy erasure has not completed')));

  for (final scheduled in [false, true]) {
    for (final kind in [
      'missing link and edited successor',
      'multiple supersede events',
      'single event with misleading current link',
      'orphan replacement history',
      'target owns a surviving replacement copy',
      'identical text also belongs to a survivor',
    ]) {
      for (final nested in [false, true]) {
        test(
            'imported $kind blocks purge atomically; '
            'scheduled=$scheduled nested=$nested', () async {
          final target = kind == 'multiple supersede events' ? 3 : 2;
          final memories = [
            _memory(1, 'Predecessor A',
                status: 'superseded',
                successor:
                    kind == 'missing link and edited successor' ? null : 3),
            _memory(2, 'Edited target B',
                status: scheduled && target == 2 ? 'deleted' : 'active'),
            _memory(
                3,
                kind == 'identical text also belongs to a survivor'
                    ? 'Original target B'
                    : 'Surviving C',
                status: scheduled && target == 3 ? 'deleted' : 'active'),
            // Expiry retirement commits even when the later hard purge blocks.
            _memory(4, 'Expires during maintenance', expired: true),
          ];
          final history = [
            _event(1, 1, 'add', text: 'Predecessor A'),
            _event(2, 2, 'add', text: 'Original target B'),
            _event(3, 2, 'edit',
                old: 'Original target B', text: 'Edited target B'),
            _event(4, 3, 'add',
                text: kind == 'identical text also belongs to a survivor'
                    ? 'Original target B'
                    : 'Surviving C'),
            _event(
                5,
                kind == 'orphan replacement history'
                    ? 99
                    : kind == 'target owns a surviving replacement copy'
                        ? 2
                        : 1,
                'supersede',
                old: 'Predecessor A',
                text: kind == 'target owns a surviving replacement copy'
                    ? 'Surviving C'
                    : 'Original target B'),
            if (kind == 'multiple supersede events')
              _event(6, 1, 'supersede',
                  old: 'Predecessor A', text: 'Surviving C'),
          ];
          await importFixture(memories, history);
          if (!scheduled) {
            // The user's explicit erase is never blocked by legacy copies:
            // they are redacted with the target, atomically (see
            // memory_legacy_erasure_test.dart for the full contract).
            if (nested) {
              await db.transaction((tx) async => expect(
                  await MemoryRepo(tx, clock: () => _now)
                      .deletePermanently(target),
                  isTrue));
            } else {
              expect(await repo.deletePermanently(target), isTrue);
            }
            expect(await db.query('memories', where: 'id = ?', whereArgs: [target]),
                isEmpty);
            for (final row in await repo.history(target)) {
              expect(row['old_content'], isNull);
              expect(row['new_content'], isNull);
            }
            expect(
                await db.query('memory_history',
                    where: "event = 'supersede' AND new_content IS NOT NULL "
                        "AND new_content != ''"),
                isEmpty);
            expect(await repo.legacyErasureBlocked(), isFalse);
            await revalidateRoundTrip();
            return;
          }
          final before = await _snapshot(db);
          final bHistory = await repo.history(2);
          final aHistory = await repo.history(1);
          Future<void> verifyOutcome(DatabaseExecutor executor) async {
            if (!scheduled) {
              expect(await _snapshot(executor), before);
              return;
            }
            final after = await _snapshot(executor);
            final expectedRows = [
              for (final row in before['memories'] as List<Map<String, Object?>>)
                if (row['id'] == 4)
                  {...row, 'status': 'deleted', 'deleted_at': _now.millisecondsSinceEpoch}
                else row,
            ];
            expect(after['memories'], expectedRows);
            expect(after['memories_fts'], [
              for (final row in before['memories_fts'] as List<Map<String, Object?>>)
                if (row['docid'] != 4) row,
            ]);
            final events = await MemoryRepo(executor).history(4);
            expect(events, hasLength(1));
            expect(events.single, containsPair('event', 'delete'));
            expect(events.single, containsPair('actor', 'system'));
            expect(events.single, containsPair('old_content', 'Expires during maintenance'));
            expect(after['memory_history'], [
              ...before['memory_history'] as List, events.single,
            ]);
            for (final table in ['extraction_state', 'extraction_sources']) {
              expect(after[table], before[table]);
            }
          }

          Future<void> attempt(MemoryRepo r) async {
            await expectLater(
                scheduled ? r.purgeDeleted() : r.deletePermanently(target),
                throwsA(blocked(target)));
          }

          if (nested) {
            await db.transaction((tx) async {
              await attempt(MemoryRepo(tx, clock: () => _now));
              await verifyOutcome(tx);
              expect(await MemoryRepo(tx).deletePermanently(-1), isFalse);
            });
          } else {
            await attempt(repo);
          }
          await verifyOutcome(db);
          expect(await repo.history(2), bHistory);
          expect(await repo.history(1), aHistory);
          expect(
              (await db.query('memory_history', where: 'id = 5'))
                  .single['new_content'],
              kind == 'target owns a surviving replacement copy'
                  ? 'Surviving C'
                  : 'Original target B',
              reason: 'blocked means retained, never successful erasure');
          await revalidateRoundTrip();
        });
      }
    }
  }

  for (final accept in [true, false]) {
    for (final copy in [null, '', 'I like painting', ' ']) {
      final copies = copy != null && copy.isNotEmpty;
      test(
          'imported referenced suggestion ${accept ? 'accept' : 'reject'}; '
          'replacement=${copy == null ? 'null' : '"$copy"'}', () async {
        await importFixture([
          _memory(1, 'Predecessor A', status: 'superseded', successor: 2),
          _memory(2, 'I like painting', status: 'suggested'),
          _memory(3, 'Unrelated survivor'),
        ], [
          _event(1, 1, 'add', text: 'Predecessor A'),
          _event(2, 1, 'supersede',
              old: 'Predecessor A', text: copy),
          _event(3, 2, 'add', text: 'I like painting'),
          _event(4, 3, 'add', text: 'Unrelated survivor'),
        ]);
        final before = await _snapshot(db);
        final unrelated = await repo.history(3);
        if (copies && accept) {
          // Even acceptance loses the suggestion identity and its older text.
          // Do not guess which copied versions should follow the accepted row.
          await db.transaction((tx) async {
            final r = MemoryRepo(tx);
            await expectLater(r.acceptSuggestion(2), throwsA(blocked(2)));
            expect(await _snapshot(tx), before);
          });
          expect(await _snapshot(db), before);
        } else {
          final result = accept
              ? await repo.acceptSuggestion(2)
              : await repo.rejectSuggestion(2);
          expect(
              result.status,
              accept
                  ? SuggestionDecision.accepted
                  : SuggestionDecision.rejected);
          final predecessor =
              (await db.query('memories', where: 'id = 1')).single;
          expect(predecessor['superseded_by'], accept ? result.memoryId : null);
          expect(await repo.suggestions(), isEmpty);
          for (final row in await repo.history(2)) {
            expect(row['old_content'], isNull);
            expect(row['new_content'], isNull);
          }
          // A successful acceptance remains erasable after backup restore.
          await revalidateRoundTrip();
          if (accept) {
            expect(await repo.deletePermanently(result.memoryId!), isTrue);
          }
        }
        expect(await repo.history(3), unrelated);
        await revalidateRoundTrip();
      });
    }

    test(
        'imported suggestion link repair rolls back after a late '
        '${accept ? 'accept' : 'reject'} failure', () async {
      await importFixture([
        _memory(1, 'Predecessor A', status: 'superseded', successor: 2),
        _memory(2, 'I like painting', status: 'suggested'),
      ], [
        _event(1, 1, 'add', text: 'Predecessor A'),
        _event(2, 1, 'supersede', old: 'Predecessor A'),
        _event(3, 2, 'add', text: 'I like painting'),
      ]);
      final before = await _snapshot(db);
      // Acceptance repairs links just before deleting S; rejection repairs
      // them before writing its final audit. Fail after each repair.
      await db.execute(accept
          ? '''CREATE TRIGGER fail_import_decision BEFORE DELETE ON memories
            WHEN old.id = 2
            BEGIN SELECT RAISE(ABORT, 'forced late decision failure'); END'''
          : '''CREATE TRIGGER fail_import_decision BEFORE INSERT ON memory_history
            WHEN new.event = 'reject'
            BEGIN SELECT RAISE(ABORT, 'forced late decision failure'); END''');
      await db.transaction((tx) async {
        final r = MemoryRepo(tx);
        await expectLater(
            accept ? r.acceptSuggestion(2) : r.rejectSuggestion(2),
            throwsA(isA<DatabaseException>()));
        expect(await _snapshot(tx), before);
      });
      expect(await _snapshot(db), before);
      await db.execute('DROP TRIGGER fail_import_decision');
      await revalidateRoundTrip();
    });
  }

  test(
      'imported reference to a deduplicated suggestion does not become a '
      'self-reference', () async {
    await importFixture([
      _memory(1, 'I like painting', successor: 2),
      _memory(2, 'I like painting', status: 'suggested'),
    ], [
      _event(1, 1, 'add', text: 'I like painting'),
      _event(2, 2, 'add', text: 'I like painting'),
    ]);
    final result = await repo.acceptSuggestion(2);
    expect(result.memoryId, 1);
    expect((await db.query('memories')).single['superseded_by'], isNull);
    await revalidateRoundTrip();
  });

  for (final scheduled in [false, true]) {
    for (final copy in [null, '']) {
    test(
        'imported content-free replacement audit ($copy) permits purge; '
        'scheduled=$scheduled', () async {
      await importFixture([
        _memory(1, 'Predecessor A', status: 'superseded', successor: 2),
        _memory(2, 'Private target', status: scheduled ? 'deleted' : 'active'),
        _memory(3, 'Unrelated survivor'),
      ], [
        _event(1, 1, 'add', text: 'Predecessor A'),
        _event(2, 1, 'supersede', old: 'Predecessor A', text: copy),
        _event(3, 2, 'add', text: 'Private target'),
        _event(4, 3, 'add', text: 'Unrelated survivor'),
      ]);
      final unrelated = await repo.history(3);
      if (scheduled) {
        expect(await repo.purgeDeleted(), 1);
      } else {
        expect(await repo.deletePermanently(2), isTrue);
      }
      expect(
          (await db.query('memories', where: 'id = 1')).single['superseded_by'],
          isNull);
      expect(await repo.history(3), unrelated);
      for (final row in await repo.history(2)) {
        expect(row['old_content'], isNull);
        expect(row['new_content'], isNull);
      }
      final data = readEntries(await h.export())[dataEntryName] as Map;
      expect(data.toString(), isNot(contains('Private target')));
      await revalidateRoundTrip();
    });
  }
  }

  test('blocked cleanup reports partial retirement and expiry stays recoverable', () async {
    await importFixture([
      _memory(1, 'Legacy owner'),
      _memory(2, 'Old deletion', status: 'deleted'),
      _memory(3, 'Expired exam', expired: true),
    ], [
      _event(1, 1, 'supersede', text: 'Unattributed private copy'),
      _event(2, 2, 'add', text: 'Old deletion'),
    ]);
    final result = await repo.cleanupDeleted();
    expect(result.retired, 1);
    expect(result.purged, 0);
    expect(result.blocked, blocked(2));
    expect(await repo.legacyErasureBlocked(), isTrue);
    expect((await repo.deleted()).map((m) => m.id), containsAll([2, 3]));
    expect((await repo.search('exam')), isEmpty);
    expect((await repo.restore(3)).status, RestoreStatus.restored);
    expect((await db.query('memories', where: 'id = 3')).single['expires_at'], isNull);
    expect((await repo.search('exam')).single.id, 3);
    expect((await repo.cleanupDeleted()).retired, 0);
    expect((await repo.history(1)).single['new_content'], 'Unattributed private copy');
    await revalidateRoundTrip();
  });

  test('late hard-purge failure rolls back the whole batch but keeps expiry retirement', () async {
    await importFixture([
      _memory(1, 'First deletion', status: 'deleted'),
      _memory(2, 'Second deletion', status: 'deleted'),
      _memory(3, 'Expired exam', expired: true),
    ], [
      _event(1, 1, 'add', text: 'First deletion'),
      _event(2, 2, 'add', text: 'Second deletion'),
    ]);
    final firstHistory = await repo.history(1);
    final secondHistory = await repo.history(2);
    await db.execute('''CREATE TRIGGER fail_batch_purge BEFORE INSERT ON memory_history
      WHEN new.event = 'purge' AND new.memory_id = 2
      BEGIN SELECT RAISE(ABORT, 'forced late purge failure'); END''');
    await expectLater(repo.cleanupDeleted(), throwsA(isA<DatabaseException>()));
    expect((await repo.deleted()).map((m) => m.id), containsAll([1, 2, 3]));
    expect(await repo.history(1), firstHistory);
    expect(await repo.history(2), secondHistory);
    expect((await repo.restore(3)).status, RestoreStatus.restored);
    await db.execute('DROP TRIGGER fail_batch_purge');
    expect(await repo.purgeDeleted(), 2);
    await revalidateRoundTrip();
  });

  test('imported empty supersede retains owner history and permits unrelated erasure', () async {
    await importFixture([
      _memory(1, 'Legacy owner', status: 'superseded', successor: 2),
      _memory(2, 'Successor'),
      _memory(3, 'Unrelated private target'),
    ], [
      _event(1, 1, 'add', text: 'Legacy owner'),
      _event(2, 1, 'supersede', old: 'Legacy owner', text: ''),
      _event(3, 2, 'add', text: 'Successor'),
      _event(4, 3, 'add', text: 'Unrelated private target'),
    ]);
    final ownerHistory = await repo.history(1);
    final successorHistory = await repo.history(2);
    expect(await repo.legacyErasureBlocked(), isFalse);
    expect(await repo.deletePermanently(3), isTrue);
    expect(await repo.history(1), ownerHistory);
    expect(await repo.history(2), successorHistory);
    expect((await db.query('memory_history', where: 'id = 2')).single['new_content'], '');
    final data = readEntries(await h.export())[dataEntryName] as Map;
    expect(data.toString(), isNot(contains('Unrelated private target')));
    await revalidateRoundTrip();
  });

  test('hard purge checks legacy history once for the entire batch', () async {
    await importFixture([
      for (var id = 1; id <= 20; id++)
        _memory(id, 'Old deletion $id', status: 'deleted'),
      _memory(21, 'Unrelated survivor'),
    ], [
      for (var id = 1; id <= 20; id++)
        _event(id, id, 'add', text: 'Old deletion $id'),
      _event(21, 21, 'supersede', text: ''),
    ]);
    guardQueries.clear();
    final result = await db.transaction((tx) =>
        MemoryRepo(_CountingTransaction(tx, guardQueries), clock: () => _now)
            .cleanupDeleted());
    expect(result.purged, 20);
    expect(result.blocked, isNull);
    expect(guardQueries, hasLength(1));
    expect((await repo.all()).single.id, 21);
    expect((await repo.history(21)).single['new_content'], '');
    await revalidateRoundTrip();
  });

}
