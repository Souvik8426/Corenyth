import 'package:assistant/data/repos.dart';
import 'package:assistant/services/backup/backup_format.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'support/backup_fixture.dart';

/// Plan 1.3 / 1.6.2: backup format v3 carries memory observation fields,
/// every memory status and the memory history; v1 and v2 still restore.

const _v3MemoryKeys = [
  'observedAtUtc',
  'observationOffsetMin',
  'factDate',
  'deletedAt',
  'expiresAt',
];

/// A test database with the FTS4 index a fresh install has (the host v2
/// migration lacks it), so the restore's search-index handling is exercised.
Future<Database> _db() async {
  final db = await openTestDb();
  await db.execute('CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts '
      'USING fts4(content, tokenize=unicode61)');
  await db.execute('''CREATE TRIGGER IF NOT EXISTS mem_ai AFTER INSERT ON memories BEGIN
      INSERT INTO memories_fts(docid, content) VALUES (new.id, new.content); END''');
  await db.execute('''CREATE TRIGGER IF NOT EXISTS mem_ad AFTER DELETE ON memories BEGIN
      DELETE FROM memories_fts WHERE docid = old.id; END''');
  return db;
}

/// One memory in every status, with observations and history.
Future<Map<String, int>> _seed(Database db) async {
  final repo = MemoryRepo(db);
  final observed = DateTime.utc(2026, 10, 30, 20);
  final active = await repo.add('my exam is tomorrow',
      observedAt: observed, observationOffsetMin: 330);
  final yearly = await repo.add("my mom's birthday is June 4",
      observedAt: observed, observationOffsetMin: -420);
  final old = await repo.add('I drink green tea');
  final replacement = await repo.add('I drink black tea');
  await repo.supersede(old, replacement);
  final deleted = await repo.add('I met Priya yesterday',
      observedAt: observed, observationOffsetMin: 0);
  expect(await repo.delete(deleted), isTrue);
  final suggested = await repo.add('I like hiking');
  await db.update('memories',
      {'status': 'suggested', 'expires_at': 1900000000000},
      where: 'id = ?', whereArgs: [suggested]);
  await db.delete('memories_fts', where: 'docid = ?', whereArgs: [suggested]);
  return {
    'active': active,
    'yearly': yearly,
    'superseded': old,
    'replacement': replacement,
    'deleted': deleted,
    'suggested': suggested,
  };
}

Future<Set<int>> _ftsIds(Database db) async => {
      for (final r in await db.rawQuery('SELECT docid FROM memories_fts'))
        r['docid'] as int
    };

Future<Set<int>> _activeIds(Database db) async => {
      for (final r in await db.query('memories',
          columns: ['id'], where: "status = 'active'"))
        r['id'] as int
    };

/// The exported archive rewritten as format [version]: the v3 memory
/// fields and history gone, and for v1 the mood section too.
String _downgrade(BackupHarness h, String path, int version) {
  final entries = readEntries(path);
  final manifest =
      Map<String, Object?>.from(entries[manifestEntryName] as Map);
  final data = Map<String, Object?>.from(entries[dataEntryName] as Map);
  manifest['formatVersion'] = version;
  data['formatVersion'] = version;
  data.remove('memoryHistory');
  if (version < 2) data.remove('messageMoods');
  final counts = manifest['counts'];
  if (counts is Map) {
    final c = Map<String, Object?>.from(counts)..remove('memoryHistory');
    if (version < 2) c.remove('messageMoods');
    manifest['counts'] = c;
  }
  data['memories'] = [
    for (final m in (data['memories'] as List).cast<Map>())
      {
        for (final e in m.entries)
          if (!_v3MemoryKeys.contains(e.key)) e.key as String: e.value
      }
  ];
  return writeArchive(h.folder, manifest, data, name: 'v$version.corenyth');
}

void main() {
  test('v3 export writes the new memory fields, every status and history',
      () async {
    final db = await _db();
    final h = BackupHarness(db, await tempFolder());
    final ids = await _seed(db);
    final entries = readEntries(await h.export());
    final manifest = entries[manifestEntryName] as Map;
    final data = entries[dataEntryName] as Map;
    expect(manifest['formatVersion'], 3);
    expect(data['formatVersion'], 3);
    final byId = {
      for (final m in (data['memories'] as List).cast<Map>()) m['id']: m
    };
    expect(byId[ids['active']], containsPair('factDate', '2026-11-01'));
    expect(byId[ids['active']], containsPair('observationOffsetMin', 330));
    expect(byId[ids['active']],
        containsPair('observedAtUtc',
            DateTime.utc(2026, 10, 30, 20).millisecondsSinceEpoch));
    expect(byId[ids['yearly']], containsPair('factDate', '--06-04'));
    expect(byId[ids['superseded']], containsPair('status', 'superseded'));
    expect(byId[ids['superseded']],
        containsPair('supersededBy', ids['replacement']));
    expect(byId[ids['deleted']], containsPair('status', 'deleted'));
    expect(byId[ids['deleted']]!['deletedAt'], isA<int>());
    expect(byId[ids['suggested']], containsPair('status', 'suggested'));
    expect(byId[ids['suggested']], containsPair('expiresAt', 1900000000000));
    final events = [
      for (final r in (data['memoryHistory'] as List).cast<Map>()) r['event']
    ];
    expect(events, containsAll(['add', 'supersede', 'delete']));
  });

  test('v3 round trip restores every memory, its history and the search '
      'index of active ones only', () async {
    final db = await _db();
    final h = BackupHarness(db, await tempFolder());
    final ids = await _seed(db);
    final memoriesBefore = await rowsOf(db, 'memories');
    final historyBefore = await rowsOf(db, 'memory_history');
    expect(await _ftsIds(db), await _activeIds(db));
    final path = await h.export();

    // Changes after the backup, all of which the import must undo.
    // "my exam is tomorrow" expires at the end of 1 Nov 2026. Freeze before
    // that so this round-trip check does not depend on the wall clock.
    final repo = MemoryRepo(db, clock: () => DateTime.utc(2026, 11, 1, 12));
    await repo.add('added after the backup');
    await repo.delete(ids['active']!);
    await repo.deletePermanently(ids['yearly']!);
    await db.update('memories', {'fact_date': null});

    final preview = await h.service.readAndCheck(path);
    final result = await h.service.importBackup(preview);
    expect(result.counts['memories'], memoriesBefore.length);
    expect(result.counts['memoryHistory'], historyBefore.length);
    expect(await rowsOf(db, 'memories'), memoriesBefore);
    expect(await rowsOf(db, 'memory_history'), historyBefore);
    expect(await _ftsIds(db), await _activeIds(db),
        reason: 'deleted, superseded and suggested rows stay out of search');
    expect(await _ftsIds(db),
        {ids['active'], ids['yearly'], ids['replacement']});

    // The restored deleted memory is still restorable, back into search.
    expect((await repo.restore(ids['deleted']!)).status,
        RestoreStatus.restored);
    expect(await _ftsIds(db), contains(ids['deleted']));
    final m = (await repo.all()).singleWhere((m) => m.id == ids['active']);
    expect(m.dated, 'my exam is tomorrow (1 Nov 2026)');
  });

  test('restore without a search index still succeeds', () async {
    final db = await openTestDb();
    final h = BackupHarness(db, await tempFolder());
    final repo = MemoryRepo(db);
    final id = await repo.add('I drink green tea');
    await db.update('memories', {'status': 'suggested'},
        where: 'id = ?', whereArgs: [id]);
    final before = await rowsOf(db, 'memories');
    final preview = await h.service.readAndCheck(await h.export());
    await h.service.importBackup(preview);
    expect(await rowsOf(db, 'memories'), before);
  });

  for (final version in [1, 2]) {
    test('a v$version archive restores with null v3 fields and no history',
        () async {
      final db = await _db();
      final h = BackupHarness(db, await tempFolder());
      final repo = MemoryRepo(db);
      final old = await repo.add('I drink green tea',
          observedAt: DateTime.utc(2026, 10, 30), observationOffsetMin: 0);
      final current = await repo.add('I drink black tea');
      await repo.supersede(old, current);
      await TaskRepo(db).create('Buy milk');
      final path = _downgrade(h, await h.export(), version);

      await repo.add('added after the backup');
      final preview = await h.service.readAndCheck(path);
      expect(preview.data.formatVersion, version);
      await h.service.importBackup(preview);

      final rows = await rowsOf(db, 'memories');
      expect([for (final r in rows) r['id']], [old, current]);
      expect([for (final r in rows) r['status']], ['superseded', 'active']);
      expect(rows.first['superseded_by'], current);
      for (final r in rows) {
        for (final c in [
          'observed_at_utc',
          'observation_offset_min',
          'fact_date',
          'deleted_at',
          'expires_at',
        ]) {
          expect(r[c], isNull, reason: '$c of ${r['content']}');
        }
        expect(r['content_hash'], isNotNull, reason: 'reindexed on restore');
      }
      expect(await rowsOf(db, 'memory_history'), isEmpty);
      expect(await _ftsIds(db), {current});
      expect([for (final r in await rowsOf(db, 'tasks')) r['title']],
          ['Buy milk']);
    });
  }

  test('a v3 archive missing a v3 memory field is refused', () async {
    final db = await openTestDb();
    final h = BackupHarness(db, await tempFolder());
    await MemoryRepo(db).add('I drink green tea');
    final entries = readEntries(await h.export());
    final data = Map<String, Object?>.from(entries[dataEntryName] as Map);
    (data['memories'] as List).cast<Map>().single.remove('factDate');
    final path = writeArchive(h.folder,
        Map<String, Object?>.from(entries[manifestEntryName] as Map), data);
    await expectLater(h.service.readAndCheck(path),
        throwsA(predicate((e) => e.toString().contains('factDate'))));
  });

  test('bad memory status, fact date, offset or history event is refused',
      () async {
    final db = await openTestDb();
    final h = BackupHarness(db, await tempFolder());
    await MemoryRepo(db).add('I drink green tea');
    final path = await h.export();
    for (final (what, edit) in <(String, void Function(Map<String, Object?>))>[
      ('status', (d) => (d['memories'] as List).cast<Map>().single['status'] = 'gone'),
      ('factDate', (d) => (d['memories'] as List).cast<Map>().single['factDate'] = 'Monday'),
      ('factDate', (d) => (d['memories'] as List).cast<Map>().single['factDate'] = '2026-13-01'),
      ('observationOffsetMin',
          (d) => (d['memories'] as List).cast<Map>().single['observationOffsetMin'] = 1200),
      ('not a memory event',
          (d) => (d['memoryHistory'] as List).cast<Map>().first['event'] = 'explode'),
      ('not a memory actor',
          (d) => (d['memoryHistory'] as List).cast<Map>().first['actor'] = 'robot'),
    ]) {
      final entries = readEntries(path);
      final data = Map<String, Object?>.from(entries[dataEntryName] as Map);
      edit(data);
      final bad = writeArchive(h.folder,
          Map<String, Object?>.from(entries[manifestEntryName] as Map), data,
          name: 'bad.corenyth');
      await expectLater(h.service.readAndCheck(bad),
          throwsA(predicate((e) => e.toString().contains(what))),
          reason: what);
    }
  });
}
