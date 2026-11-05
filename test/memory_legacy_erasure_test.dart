import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/backup/backup_format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/backup_fixture.dart';

final _now = DateTime.utc(2026, 10, 31);
final _old = _now.subtract(const Duration(days: 31)).millisecondsSinceEpoch;

Map<String, Object?> _memory(int id, String content,
        {String status = 'active', int? successor, bool noDeletedAt = false}) =>
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
      'deletedAt': status == 'deleted' && !noDeletedAt ? _old : null,
      'expiresAt': null,
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late MemoryRepo repo;
  late BackupHarness h;
  setUp(() async {
    final dir = await tempFolder();
    db = await openAppDb(path: '${dir.path}/legacy.db');
    addTearDown(db.close);
    repo = MemoryRepo(db, clock: () => _now);
    h = BackupHarness(db, await tempFolder());
  });

  // Same route as the privacy tests: a real archive through validator+restore.
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
    await h.service.importBackup(await h.service.readAndCheck(file));
  }

  Future<List<Object?>> ftsIds() async => [
        for (final r in await db.query('memories_fts', columns: ['docid']))
          r['docid']
      ];

  // Legacy supersede events carry replacement text with no target identity
  // (the per-event copy that older builds wrote). Three layouts of it.
  final layouts = <String, List<Map<String, Object?>>>{
    'copy of an older version of the target': [
      _event(1, 1, 'add', text: 'Predecessor A'),
      _event(2, 2, 'add', text: 'Original target B'),
      _event(3, 2, 'edit', old: 'Original target B', text: 'Private target B'),
      _event(4, 3, 'add', text: 'Surviving C'),
      _event(5, 1, 'supersede', old: 'Predecessor A', text: 'Original target B'),
    ],
    'copy owned by the target itself': [
      _event(1, 1, 'add', text: 'Predecessor A'),
      _event(2, 2, 'add', text: 'Private target B'),
      _event(3, 3, 'add', text: 'Surviving C'),
      _event(4, 2, 'supersede', old: 'Private target B', text: 'Surviving C'),
    ],
    'orphan copy with no owner': [
      _event(1, 1, 'add', text: 'Predecessor A'),
      _event(2, 2, 'add', text: 'Private target B'),
      _event(3, 3, 'add', text: 'Surviving C'),
      _event(4, 99, 'supersede', old: 'Gone', text: 'Private target B'),
    ],
  };

  for (final entry in layouts.entries) {
    test('explicit erase removes the target despite a legacy ${entry.key}',
        () async {
      await importFixture([
        _memory(1, 'Predecessor A', status: 'superseded', successor: 2),
        _memory(2, 'Private target B'),
        _memory(3, 'Surviving C'),
      ], entry.value);
      // A source link and a conversation row the erasure must unlink.
      final msg = await db.insert('conversations', {
        'session_id': 's',
        'role': 'user',
        'content': 'hello',
        'created_at': 1,
      });
      await db.insert('extraction_sources',
          {'message_id': msg, 'suggestion_id': 2, 'memory_id': 2});
      expect(await ftsIds(), contains(2));
      expect(await repo.legacyErasureBlocked(), isTrue);
      final survivorHistory = await repo.history(3);

      expect(await repo.deletePermanently(2), isTrue);

      expect(await db.query('memories', where: 'id = 2'), isEmpty);
      expect(await ftsIds(), isNot(contains(2)));
      expect((await db.query('memories', where: 'id = 1')).single['superseded_by'],
          isNull);
      expect(
          (await db.query('extraction_sources')).single['memory_id'], isNull);
      for (final row in await repo.history(2)) {
        expect(row['old_content'], isNull);
        expect(row['new_content'], isNull);
      }
      // No history row anywhere still carries the target's text, in any
      // version, and nothing else is left as an unattributed copy.
      final texts = [
        for (final r in await db.query('memory_history'))
          '${r['old_content']} ${r['new_content']}'
      ].join('|');
      expect(texts, isNot(contains('Private target B')));
      expect(texts, isNot(contains('Original target B')));
      expect(await repo.legacyErasureBlocked(), isFalse);
      // Unrelated memories keep their own add history.
      expect(await repo.history(3), survivorHistory);
      expect((await repo.all()).map((m) => m.id), containsAll([3]));
      final export = readEntries(await h.export())[dataEntryName] as Map;
      expect(export.toString(), isNot(contains('Private target B')));
      expect(export.toString(), isNot(contains('Original target B')));
    });
  }

  test('explicit erase also works inside a caller transaction', () async {
    await importFixture([
      _memory(1, 'Predecessor A', status: 'superseded', successor: 2),
      _memory(2, 'Private target B'),
    ], layouts.values.first.where((e) => e['memoryId'] != 3).toList());
    await db.transaction((tx) async {
      expect(await MemoryRepo(tx, clock: () => _now).deletePermanently(2),
          isTrue);
      expect(await tx.query('memories', where: 'id = 2'), isEmpty);
    });
    expect(await db.query('memories', where: 'id = 2'), isEmpty);
  });

  test('legacy deleted row without a deletion time is still erasable',
      () async {
    await importFixture([
      _memory(1, 'Old private note', status: 'deleted', noDeletedAt: true),
      _memory(2, 'Owner'),
    ], [
      _event(1, 1, 'add', text: 'Old private note'),
      _event(2, 2, 'supersede', text: 'Unattributed copy'),
    ]);
    // Automatic purge stays closed: it cannot tell what the copy belongs to.
    final auto = await repo.cleanupDeleted();
    expect(auto.purged, 0);
    expect(await db.query('memories', where: 'id = 1'), hasLength(1));
    // The user's erase from Recently deleted still works.
    expect((await repo.deleted()).map((m) => m.id), [1]);
    expect(await repo.deletePermanently(1), isTrue);
    expect(await db.query('memories', where: 'id = 1'), isEmpty);
    expect(
        (await db.query('memory_history', where: 'memory_id = 1'))
            .every((r) => r['new_content'] == null && r['old_content'] == null),
        isTrue);
  });

  test('automatic purge still fails closed, then recovers after an explicit erase',
      () async {
    await importFixture([
      _memory(1, 'Legacy owner'),
      _memory(2, 'Old deletion A', status: 'deleted'),
      _memory(3, 'Old deletion B', status: 'deleted'),
    ], [
      _event(1, 1, 'supersede', text: 'Unattributed private copy'),
      _event(2, 2, 'add', text: 'Old deletion A'),
      _event(3, 3, 'add', text: 'Old deletion B'),
    ]);
    final result = await repo.cleanupDeleted();
    expect(result.purged, 0);
    expect(result.blocked, isA<MemoryPrivacyBlocked>());
    expect(await db.query('memories'), hasLength(3));

    expect(await repo.deletePermanently(2), isTrue);
    // The ambiguity is resolved by the user's erase, so the rest can go.
    expect(await repo.purgeDeleted(), 1);
    expect((await db.query('memories')).map((r) => r['id']), [1]);
  });

  test('explicit erase rolls back completely when a late write fails',
      () async {
    await importFixture([
      _memory(1, 'Predecessor A', status: 'superseded', successor: 2),
      _memory(2, 'Private target B'),
    ], [
      _event(1, 1, 'add', text: 'Predecessor A'),
      _event(2, 2, 'add', text: 'Private target B'),
      _event(3, 1, 'supersede', old: 'Predecessor A', text: 'Private target B'),
    ]);
    final memories = await db.query('memories');
    final history = await db.query('memory_history');
    await db.execute('''CREATE TRIGGER fail_erase BEFORE INSERT ON memory_history
      WHEN new.event = 'purge'
      BEGIN SELECT RAISE(ABORT, 'forced late failure'); END''');
    await expectLater(
        repo.deletePermanently(2), throwsA(isA<DatabaseException>()));
    expect(await db.query('memories'), memories);
    expect(await db.query('memory_history'), history);
    await db.execute('DROP TRIGGER fail_erase');
    expect(await repo.deletePermanently(2), isTrue);
  });

  test('rejecting a suggestion erases it despite a legacy copy', () async {
    await importFixture([
      _memory(1, 'Predecessor A', status: 'superseded', successor: 2),
      _memory(2, 'I like painting', status: 'suggested'),
      _memory(3, 'Unrelated survivor'),
    ], [
      _event(1, 1, 'add', text: 'Predecessor A'),
      _event(2, 1, 'supersede', old: 'Predecessor A', text: 'I like painting'),
      _event(3, 2, 'add', text: 'I like painting'),
      _event(4, 3, 'add', text: 'Unrelated survivor'),
    ]);
    final survivorHistory = await repo.history(3);
    final result = await repo.rejectSuggestion(2);
    expect(result.status, SuggestionDecision.rejected);
    expect(await repo.suggestions(), isEmpty);
    expect((await db.query('memories', where: 'id = 1')).single['superseded_by'],
        isNull);
    final texts = [
      for (final r in await db.query('memory_history'))
        '${r['old_content']} ${r['new_content']}'
    ].join('|');
    expect(texts, isNot(contains('I like painting')));
    expect(await repo.history(3), survivorHistory);
  });
}
