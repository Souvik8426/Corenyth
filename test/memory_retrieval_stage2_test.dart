import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RecordingExecutor implements DatabaseExecutor {
  _RecordingExecutor(this.db);
  final Database db;
  final calls =
      <({String sql, List<Object?> args, List<Map<String, Object?>> rows})>[];
  Future<void> Function()? beforeContent;

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
      [List<Object?>? arguments]) async {
    if (sql.startsWith('SELECT * FROM memories')) {
      await beforeContent?.call();
    }
    final rows = await db.rawQuery(sql, arguments);
    calls.add((sql: sql, args: arguments ?? [], rows: rows));
    return rows;
  }

  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) =>
      db.update(table, values,
          where: where,
          whereArgs: whereArgs,
          conflictAlgorithm: conflictAlgorithm);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Feed known binary statistics through the public search path. The ordinary
// tests below separately exercise real SQLite matchinfo blobs and FTS queries.
class _StatisticsExecutor implements DatabaseExecutor {
  _StatisticsExecutor(this.candidates, this.memories);
  final List<Map<String, Object?>> candidates, memories;

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) async =>
      sql.contains('matchinfo(') ? candidates : memories;

  @override
  Future<int> update(String table, Map<String, Object?> values,
          {String? where,
          List<Object?>? whereArgs,
          ConflictAlgorithm? conflictAlgorithm}) async =>
      1;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Uint8List _blob(List<int> values) {
  final bytes = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    bytes.setUint32(i * 4, values[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime.utc(2026, 10, 31);

  group('two-stage retrieval with SQLite FTS4', () {
    late Database db;
    late _RecordingExecutor recording;
    late MemoryRepo repo;

    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      final dir = await Directory.systemTemp.createTemp('memory-stage2-');
      db = await openAppDb(path: '${dir.path}/test.db');
      recording = _RecordingExecutor(db);
      repo = MemoryRepo(recording, clock: () => now);
      addTearDown(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
    });

    Future<int> insert(String content,
            {double importance = 0.5,
            int ageDays = 0,
            String status = 'active',
            String category = 'fact'}) =>
        db.insert('memories', {
          'content': content,
          'category': category,
          'importance': importance,
          'status': status,
          'created_at': now.millisecondsSinceEpoch,
          'updated_at':
              now.subtract(Duration(days: ageDays)).millisecondsSinceEpoch,
        });

    test('loads only 60 shortlisted contents and accesses only returned rows',
        () async {
      for (var i = 0; i < 100; i++) {
        await insert('needle marker$i', importance: 0.1);
      }
      final target = await insert('needle target', importance: 0.9);
      final results = await repo.search('needle');
      expect(results, hasLength(3));
      expect(results.first.id, target);
      expect(recording.calls, hasLength(2));
      final first = recording.calls.first;
      expect(first.sql, contains("matchinfo(memories_fts, 'pcnalx')"));
      expect(first.rows, hasLength(101));
      expect(
          first.rows.every((r) =>
              r.keys
                  .toSet()
                  .containsAll(['id', 'importance', 'updated_at', 'mi']) &&
              r.length == 4),
          isTrue);
      expect(first.rows.every((r) => r['mi'] is Uint8List), isTrue);
      expect(recording.calls.last.rows, hasLength(60));
      expect(recording.calls.last.args, hasLength(60));
      expect(recording.calls.last.args, contains(target));
      final accessed = await db.query('memories',
          columns: ['id', 'last_accessed_at'],
          where: 'last_accessed_at IS NOT NULL');
      expect(accessed.map((r) => r['id']),
          unorderedEquals(results.map((m) => m.id)));
      expect(
          accessed.every(
              (r) => r['last_accessed_at'] == now.millisecondsSinceEpoch),
          isTrue);
    });

    test('shortlist grows to four times limits above fifteen', () async {
      for (var i = 0; i < 100; i++) {
        await insert('needle marker$i');
      }
      expect(await repo.search('needle', limit: 20), hasLength(20));
      expect(recording.calls.last.args, hasLength(80));
      expect(recording.calls.last.rows, hasLength(80));
    });

    test('rare query terms beat widespread partial matches', () async {
      for (var i = 0; i < 70; i++) {
        await insert('tea record$i');
      }
      final target = await insert('tea jasmine');
      expect((await repo.search('tea jasmine', limit: 1)).single.id, target);
    });

    test('BM25 favors shorter documents with the same hit frequency', () async {
      await insert('quasar ${List.filled(40, 'filler').join(' ')}');
      final target = await insert('quasar');
      expect((await repo.search('quasar', limit: 1)).single.id, target);
    });

    test('BM25 rewards term frequency at equal document lengths', () async {
      await insert('quasar other filler');
      final target = await insert('quasar quasar filler');
      expect((await repo.search('quasar', limit: 1)).single.id, target);
    });

    test('importance and thirty-day recency retain their weights', () async {
      final old = await insert('needle old', importance: 0.9, ageDays: 60);
      final low = await insert('needle low', importance: 0.1);
      final target = await insert('needle current', importance: 0.9);
      expect(
          (await repo.search('needle')).map((m) => m.id), [target, old, low]);
    });

    test('prefixes, Unicode and repeated terms keep matching safely', () async {
      final target = await insert('café compass naïve 東京');
      expect((await repo.search('CAFE comp cafe')).single.id, target);
      expect(recording.calls.first.args, ['cafe* OR comp*']);
      expect((await repo.search('naive 東京')).single.id, target);
      expect(await repo.search('" OR * -- ;'), isEmpty);
    });

    test('exact term score breaks equal BM25 scores before id order', () async {
      await insert('café');
      final exact = await insert('cafe');
      expect((await repo.search('cafe', limit: 1)).single.id, exact);
      expect((await repo.search('cafe', limit: 1)).single.id, exact);
    });

    test('inactive rows left in FTS cannot enter either retrieval stage',
        () async {
      await insert('I prefer quiet mornings',
          status: 'deleted', category: 'preference', importance: 1);
      await insert('I prefer quiet evenings',
          status: 'superseded', category: 'preference', importance: 1);
      final active =
          await insert('I prefer quiet afternoons', category: 'preference');
      expect((await repo.search('quiet')).single.id, active);
      expect(recording.calls.first.rows.map((r) => r['id']), [active]);
      // Use the real executor for relevantForContext's preference fallback.
      expect(
          (await MemoryRepo(db, clock: () => now).relevantForContext('quiet'))
              .single
              .id,
          active);
    });

    test('stage two rechecks status before loading a shortlisted memory',
        () async {
      final target = await insert('needle target');
      recording.beforeContent = () async {
        await db.update('memories', {'status': 'deleted'},
            where: 'id = ?', whereArgs: [target]);
      };
      expect(await repo.search('needle'), isEmpty);
      expect((await db.query('memories')).single['last_accessed_at'], isNull);
    });

    test('empty queries, absent matches and nonpositive limits return no rows',
        () async {
      await insert('needle target');
      expect(await repo.search('the and my'), isEmpty);
      expect(await repo.search('needle', limit: 0), isEmpty);
      expect(await repo.search('needle', limit: -1), isEmpty);
      expect(recording.calls, isEmpty);
      expect(await repo.search('absent'), isEmpty);
      expect(recording.calls, hasLength(1));
    });
  });

  // These thresholds distinguish each sigmoid band, little-endian n > 255,
  // column lengths, document frequency (not total hits), and phrase offsets.
  for (final parameters in [
    (3, 5.0, 0.7),
    (6, 7.0, 0.6),
    (9, 9.0, 0.5),
    (15, 10.0, 0.5),
    (16, 12.0, 0.5)
  ]) {
    final (termCount, midpoint, steepness) = parameters;
    test('BM25 binary statistics and sigmoid for $termCount query terms',
        () async {
      final content = List.generate(termCount, (i) => 'term$i').join(' ');
      // p=2, c=2, n=1024; a=[12,8], l=[9,4]. Nonzero hits are
      // phrase 0/column 1 and phrase 1/column 0; all other cells are zero.
      final statistics = [
        2,
        2,
        1024,
        12,
        8,
        9,
        4,
        0,
        0,
        0,
        2,
        200,
        64,
        3,
        900,
        512,
        0,
        0,
        0
      ];
      final noHits = [
        2,
        2,
        1024,
        12,
        8,
        9,
        4,
        0,
        0,
        0,
        0,
        200,
        64,
        0,
        900,
        512,
        0,
        0,
        0
      ];
      final raw = math.log(1 + 960.5 / 64.5) *
              2 *
              2.2 /
              (2 + 1.2 * (0.25 + 0.75 * 4 / 8)) +
          math.log(1 + 512.5 / 512.5) *
              3 *
              2.2 /
              (3 + 1.2 * (0.25 + 0.75 * 9 / 12));
      double sigmoid(double value) =>
          1 / (1 + math.exp(-steepness * (value - midpoint)));
      final delta = 2 * (sigmoid(raw) - sigmoid(0));
      for (final offset in [-0.00001, 0.00001]) {
        Map<String, Object?> memory(int id, double importance) => {
              'id': id,
              'content': content,
              'category': 'fact',
              'importance': importance,
              'updated_at': now.millisecondsSinceEpoch,
            };
        final first = memory(1, 0.5), second = memory(2, 0.5 + delta + offset);
        final executor = _StatisticsExecutor([
          {...first, 'mi': _blob(statistics)},
          {...second, 'mi': _blob(noHits)},
        ], [
          first,
          second
        ]);
        final results = await MemoryRepo(executor, clock: () => now)
            .search(content, limit: 1);
        expect(results.single.id, offset < 0 ? 1 : 2);
      }
    });
  }
}
