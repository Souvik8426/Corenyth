import 'dart:io';

import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RecordingExecutor implements DatabaseExecutor {
  _RecordingExecutor(this.db);
  final Database db;
  final pages = <({int? limit, int? offset, int rows})>[];
  final updates =
      <({Map<String, Object?> values, String? where, List<Object?>? args})>[];
  int reads = 0;
  Future<void> Function()? beforeContent;
  Future<void> Function()? beforeUpdate;

  @override
  Future<List<Map<String, Object?>>> query(String table,
      {bool? distinct,
      List<String>? columns,
      String? where,
      List<Object?>? whereArgs,
      String? groupBy,
      String? having,
      String? orderBy,
      int? limit,
      int? offset}) async {
    reads++;
    final rows = await db.query(table,
        distinct: distinct,
        columns: columns,
        where: where,
        whereArgs: whereArgs,
        groupBy: groupBy,
        having: having,
        orderBy: orderBy,
        limit: limit,
        offset: offset);
    pages.add((limit: limit, offset: offset, rows: rows.length));
    return rows;
  }

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) async {
    reads++;
    if (sql.startsWith('SELECT * FROM memories')) {
      await beforeContent?.call();
    }
    return db.rawQuery(sql, arguments);
  }

  @override
  Future<int> update(String table, Map<String, Object?> values,
      {String? where,
      List<Object?>? whereArgs,
      ConflictAlgorithm? conflictAlgorithm}) async {
    updates.add((values: Map.of(values), where: where, args: whereArgs));
    await beforeUpdate?.call();
    return db.update(table, values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 31);
  late Database db;
  late _RecordingExecutor recording;
  late MemoryRepo repo;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('memory-bounded-access-');
    db = await openAppDb(path: '${dir.path}/test.db');
    recording = _RecordingExecutor(db);
    repo = MemoryRepo(recording, clock: () => now);
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
  });

  Future<int> insert(String content,
          {String category = 'fact',
          String status = 'active',
          double importance = 0.5,
          int? updatedAt,
          int? accessedAt}) =>
      db.insert('memories', {
        'content': content,
        'category': category,
        'status': status,
        'importance': importance,
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': updatedAt ?? now.millisecondsSinceEpoch,
        'last_accessed_at': accessedAt,
      });

  test('important filters status, category and useful content before its cap',
      () async {
    for (final status in ['deleted', 'superseded', 'suggested']) {
      await insert('User likes inactive tea', status: status, importance: 1);
    }
    await insert('User likes excluded tea', category: 'other', importance: 1);
    await insert('finished with tea', importance: 1);
    final preference = await insert('User prefers tea', category: 'preference');
    final fact = await insert('User works in astronomy');
    final person = await insert('My sister likes painting', category: 'person');
    expect((await repo.important(limit: 10)).map((m) => m.id),
        [preference, fact, person]);
    expect(recording.pages, [(limit: 50, offset: 0, rows: 4)]);
    expect(recording.updates, isEmpty);
  });

  test('important orders importance, updated time, then ascending id',
      () async {
    final low = await insert('User likes low tea', importance: 0.1);
    final old = await insert('User likes old tea', updatedAt: 1);
    final firstTie = await insert('User likes first tea');
    final secondTie = await insert('User likes second tea');
    final high = await insert('User likes high tea', importance: 0.9);
    expect((await repo.important(limit: 5)).map((m) => m.id),
        [high, firstTie, secondTie, old, low]);
  });

  test(
      'important crosses rejected pages and stops once enough useful rows exist',
      () async {
    for (var i = 0; i < 100; i++) {
      await insert('finished with marker$i');
    }
    final target = await insert('User likes tea');
    await insert('User likes coffee');
    expect((await repo.important(limit: 1)).single.id, target);
    expect(recording.pages, [
      (limit: 50, offset: 0, rows: 50),
      (limit: 50, offset: 50, rows: 50),
      (limit: 50, offset: 100, rows: 2),
    ]);
  });

  test('important scans at most five pages even when useful rows follow',
      () async {
    for (var i = 0; i < 249; i++) {
      await insert('finished with marker$i');
    }
    final lastEligible = await insert('User likes tea');
    await insert('User likes coffee');
    expect(
        (await repo.important(limit: 1000)).map((m) => m.id), [lastEligible]);
    expect(recording.pages, [
      for (var page = 0; page < 5; page++)
        (limit: 50, offset: page * 50, rows: 50),
    ]);
  });

  test('important returns no more than 250 useful rows for a large limit',
      () async {
    for (var i = 0; i < 251; i++) {
      await insert('User likes marker$i');
    }
    expect(await repo.important(limit: 1000), hasLength(250));
    expect(recording.pages, hasLength(5));
  });

  test('important stops at an empty page and nonpositive limits do not query',
      () async {
    expect(await repo.important(limit: 0), isEmpty);
    expect(await repo.important(limit: -1), isEmpty);
    expect(recording.reads, 0);
    expect(await repo.important(), isEmpty);
    expect(recording.pages, [(limit: 50, offset: 0, rows: 0)]);
  });

  test('search stamps only returned IDs once using its captured timestamp',
      () async {
    final ids = <int>[];
    for (var i = 0; i < 5; i++) {
      ids.add(await insert('needle marker$i', accessedAt: 123));
    }
    var clockCalls = 0;
    repo = MemoryRepo(recording, clock: () {
      clockCalls++;
      return now.add(Duration(days: clockCalls - 1));
    });
    final results = await repo.search('needle', limit: 3);
    expect(results, hasLength(3));
    expect(recording.updates, hasLength(1));
    final update = recording.updates.single;
    expect(update.values, {'last_accessed_at': now.millisecondsSinceEpoch});
    expect(update.where, "status = 'active' AND id IN (?,?,?)");
    expect(update.args, results.map((m) => m.id).toList());
    expect(clockCalls, 1);
    // Returned snapshots retain the timestamp read before this access.
    expect(
        results.every((m) => m.lastAccessedAt!.millisecondsSinceEpoch == 123),
        isTrue);
    for (final row in await db.query('memories')) {
      expect(row['last_accessed_at'],
          update.args!.contains(row['id']) ? now.millisecondsSinceEpoch : 123);
      expect(row['updated_at'], now.millisecondsSinceEpoch);
    }
  });

  test('search excludes inactive matches from results and timestamp writes',
      () async {
    for (final status in ['deleted', 'superseded', 'suggested']) {
      await insert('needle inactive', status: status, accessedAt: 123);
    }
    final active = await insert('needle active', accessedAt: 123);
    expect((await repo.search('needle')).single.id, active);
    expect(recording.updates.single.args, [active]);
    final inactive = await db.query('memories', where: "status != 'active'");
    expect(inactive.every((r) => r['last_accessed_at'] == 123), isTrue);
  });

  test('batch update rechecks active status if a returned row becomes inactive',
      () async {
    final target = await insert('needle target', accessedAt: 123);
    recording.beforeUpdate = () => db
        .update('memories', {'status': 'deleted'},
            where: 'id = ?', whereArgs: [target])
        .then((_) {});
    expect((await repo.search('needle')).single.id, target);
    expect(recording.updates, hasLength(1));
    expect((await db.query('memories')).single['last_accessed_at'], 123);
  });

  test('search skips updates for every empty-result path', () async {
    final target = await insert('needle target', accessedAt: 123);
    expect(await repo.search('the and my'), isEmpty);
    expect(await repo.search('needle', limit: 0), isEmpty);
    expect(await repo.search('needle', limit: -1), isEmpty);
    expect(recording.reads, 0);
    expect(await repo.search('absent'), isEmpty);
    recording.beforeContent = () => db
        .update('memories', {'status': 'deleted'},
            where: 'id = ?', whereArgs: [target])
        .then((_) {});
    expect(await repo.search('needle'), isEmpty);
    expect(recording.updates, isEmpty);
    expect((await db.query('memories')).single['last_accessed_at'], 123);
  });
}
