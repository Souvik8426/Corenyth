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
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  for (final existing in <List<String>>[
    [],
    ['deleted_at'],
    ['expires_at'],
    ['deleted_at', 'expires_at'],
  ]) {
    test('v10 migration preserves rows with existing columns $existing',
        () async {
      final dir = await Directory.systemTemp.createTemp('memory-v11-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/v10.db';
      final legacy =
          await openDatabase(path, version: 10, onCreate: (db, _) async {
        // The provenance migration requires the real v10 journal/source tables.
        await db.execute('CREATE TABLE conversations(id INTEGER PRIMARY KEY, '
            'session_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, '
            'created_at INTEGER NOT NULL)');
        await db.execute('CREATE TABLE chats(id TEXT PRIMARY KEY)');
        await db.execute('CREATE TABLE operations(op_id TEXT PRIMARY KEY, '
            'chat_id TEXT NOT NULL, text_hash TEXT NOT NULL, status TEXT NOT NULL, '
            'action TEXT, receipt TEXT, created_at INTEGER NOT NULL, '
            'updated_at INTEGER NOT NULL)');
        await db.execute('''CREATE TABLE memories(
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          content TEXT NOT NULL, category TEXT NOT NULL DEFAULT 'fact',
          importance REAL NOT NULL DEFAULT 0.5,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
          last_accessed_at INTEGER, embedding BLOB,
          op_id TEXT, source TEXT, status TEXT NOT NULL DEFAULT 'active',
          superseded_by INTEGER, content_hash TEXT,
          subject_key TEXT, attribute_key TEXT, observed_at_utc INTEGER,
          observation_offset_min INTEGER, fact_date TEXT)''');
        await db.execute(
            'CREATE INDEX memories_status_hash ON memories(status, content_hash)');
        await db.execute(
            'CREATE INDEX memories_slot ON memories(status, subject_key, attribute_key)');
        await db.execute(
            'CREATE VIRTUAL TABLE memories_fts USING fts4(content, tokenize=unicode61)');
        await db.execute('''CREATE TRIGGER mem_ai AFTER INSERT ON memories BEGIN
          INSERT INTO memories_fts(docid, content) VALUES (new.id, new.content); END''');
        for (final column in existing) {
          await db.execute('ALTER TABLE memories ADD COLUMN $column INTEGER');
        }
      });
      final seed = <String, Object?>{
        'content': 'legacy fact',
        'created_at': 1000,
        'updated_at': 1000,
        'content_hash': 'preserved hash',
        for (final column in existing) column: 1234,
      };
      final id = await legacy.insert('memories', seed);
      await legacy.close();

      final db = await openAppDb(path: path);
      addTearDown(db.close);
      expect(await db.getVersion(), dbVersion);
      final v12Tables = (await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type = 'table'"))
          .map((row) => row['name']);
      expect(v12Tables, containsAll(['extraction_state', 'extraction_sources']));
      final columns = (await db.rawQuery('PRAGMA table_info(memories)'))
          .map((row) => row['name']);
      expect(columns, containsAll(['deleted_at', 'expires_at']));
      final row = (await db.query('memories')).single;
      expect(row['id'], id);
      for (final entry in seed.entries) {
        expect(row[entry.key], entry.value);
      }
      for (final column in ['deleted_at', 'expires_at']) {
        expect(row[column], existing.contains(column) ? 1234 : null);
      }
      expect(await db.query('memory_history'), isEmpty);
      expect(await db.rawQuery('PRAGMA foreign_key_list(memory_history)'),
          isEmpty);
      expect(
          (await db.rawQuery('PRAGMA index_info(memory_history_mem)'))
              .map((row) => row['name']),
          ['memory_id', 'id']);
      final repo = MemoryRepo(db);
      final added = await repo.add('migrated database accepts writes');
      expect((await repo.history(added)).single['event'], 'add');
    });
  }

  group('memory mutation history', () {
    late Database db;
    late MemoryRepo repo;
    late ToolExecutor executor;

    setUp(() async {
      final dir = await Directory.systemTemp.createTemp('memory-history-');
      db = await openAppDb(path: '${dir.path}/test.db');
      repo = MemoryRepo(db);
      executor =
          ToolExecutor(TaskRepo(db), ReminderRepo(db), repo, NoopScheduler());
      addTearDown(() async {
        await db.close();
        await dir.delete(recursive: true);
      });
    });

    test('schema checks accept only the specified events and actors', () async {
      final row = <String, Object?>{
        'memory_id': 99,
        'event': 'add',
        'actor': 'rules',
        'created_at': 1,
      };
      for (final event in [
        'add',
        'bump',
        'supersede',
        'delete',
        'restore',
        'purge',
        'edit',
        'accept',
        'reject',
      ]) {
        await db.insert('memory_history', {...row, 'event': event});
      }
      for (final actor in ['user', 'rules', 'model', 'system']) {
        await db.insert('memory_history', {...row, 'actor': actor});
      }
      await expectLater(
          db.insert('memory_history', {...row, 'event': 'unknown'}),
          throwsA(isA<DatabaseException>()));
      await expectLater(
          db.insert('memory_history', {...row, 'actor': 'unknown'}),
          throwsA(isA<DatabaseException>()));
      expect(await repo.history(99), hasLength(13));
    });

    test('add and bump each write exactly one ordered row with provenance',
        () async {
      final id = await repo.add('  A durable fact  ',
          actor: 'user', opId: 'add-op', source: 'chat:one');
      expect(await repo.add('a DURABLE fact!', actor: 'model', opId: 'bump-op'),
          id);
      final history = await repo.history(id);
      expect(history.map((row) => row['event']), ['add', 'bump']);
      expect(history.map((row) => row['actor']), ['user', 'model']);
      expect(history.map((row) => row['op_id']), ['add-op', 'bump-op']);
      expect(history.first['old_content'], isNull);
      expect(history.first['new_content'], 'A durable fact');
      expect(history.last['old_content'], 'A durable fact');
      expect(history.last['new_content'], 'A durable fact');
      expect(history.every((row) => (row['created_at'] as int) > 0), isTrue);
      expect(
          (await db.query('memories')).single['importance'], closeTo(0.6, .01));
    });

    test('slot superseding logs once and removes the old FTS row', () async {
      final old = await repo.add('User lives in Pune');
      final saved = await repo.add('User lives in Mumbai',
          actor: 'user', opId: 'move-op');
      final history = await repo.history(old);
      expect(history.map((row) => row['event']), ['add', 'supersede']);
      expect(history.last['actor'], 'user');
      expect(history.last['op_id'], 'move-op');
      expect(history.last['old_content'], 'User lives in Pune');
      expect(history.last['new_content'], isNull,
          reason: 'replacement text stays in the successor history');
      expect((await repo.history(saved)).single['new_content'],
          'User lives in Mumbai');
      expect((await repo.history(saved)).single['event'], 'add');
      expect(await repo.search('Pune'), isEmpty);
      expect(await repo.activeIdForContent('User lives in Pune'), isNull);
      expect(await repo.activeIdForContent('  USER lives in Mumbai!  '), saved);
      await repo.supersede(old, saved);
      await repo.supersede(saved, saved);
      expect(await repo.history(old), hasLength(2));
      expect(await repo.history(saved), hasLength(1));
    });

    test('direct supersede and delete log once; history survives deletion',
        () async {
      final old = await repo.add('original fact');
      final saved = await repo.add('replacement fact');
      await repo.supersede(old, saved, actor: 'system', opId: 'replace-op');
      expect((await repo.history(old)).last['event'], 'supersede');
      expect((await repo.history(old)).last['actor'], 'system');
      // Soft deletion only applies to active rows; superseded history stays.
      expect(await repo.delete(old), isFalse);
      expect((await repo.history(old)).map((row) => row['event']),
          ['add', 'supersede']);
      final superseded =
          (await db.query('memories', where: 'id = ?', whereArgs: [old])).single;
      expect(superseded['status'], 'superseded');
      expect(superseded['deleted_at'], isNull);
      expect(await repo.delete(saved), isTrue);
      expect(await repo.delete(saved), isFalse);
      final history = await repo.history(saved);
      expect(history.map((row) => row['event']), ['add', 'delete']);
      expect(history.last['old_content'], 'replacement fact');
      expect(history.last['new_content'], isNull);
      final deleted =
          (await db.query('memories', where: 'id = ?', whereArgs: [saved])).single;
      expect(deleted['status'], 'deleted');
      expect(deleted['deleted_at'], isA<int>());
      expect(await repo.all(), isEmpty);
    });

    test('correction uses every term, active status, and excludes the new row',
        () async {
      final old = await repo.add('morning coffee ritual');
      final partial = await repo.add('morning tea ritual');
      final inactive = await repo.add('evening coffee ritual');
      await db.update('memories', {'status': 'suggested'},
          where: 'id = ?', whereArgs: [inactive]);
      final saved = await repo.addCorrection('new coffee ritual',
          replaces: 'coffee ritual', actor: 'user', opId: 'correct-op');
      expect((await repo.history(old)).last['event'], 'supersede');
      expect((await repo.history(old)).last['op_id'], 'correct-op');
      expect(await repo.history(partial), hasLength(1));
      expect(await repo.history(inactive), hasLength(1));
      expect((await repo.history(saved)).single['actor'], 'user');
      expect(await repo.activeIdForContent('new coffee ritual'), saved);
    });

    for (final count in [3, 4]) {
      test('correction cap with $count candidates', () async {
        final ids = <int>[];
        for (var i = 0; i < count; i++) {
          ids.add(await repo.add('coffee ritual number $i'));
        }
        await repo.addCorrection('switching to tea', replaces: 'coffee ritual');
        for (final id in ids) {
          final history = await repo.history(id);
          expect(history.map((row) => row['event']),
              count <= 3 ? ['add', 'supersede'] : ['add']);
        }
      });
    }

    test('correction retains the every-term filter after FTS normalization',
        () async {
      final accent = await repo.add('café ritual');
      await repo.addCorrection('new ritual', replaces: 'cafe ritual');
      expect(await repo.history(accent), hasLength(1));
      await repo.addCorrection('another ritual', replaces: 'the and my');
      expect(await repo.history(accent), hasLength(1));
    });

    test('overlapping slot and correction superseding logs only once',
        () async {
      final old = await repo.add('User likes coffee');
      final saved = await repo.addCorrection('User likes tea',
          replaces: 'coffee', actor: 'user');
      expect((await repo.history(old)).map((row) => row['event']),
          ['add', 'supersede']);
      expect((await repo.history(saved)).single['event'], 'add');
    });

    test('a failed insert in an outer transaction rolls back its history',
        () async {
      await expectLater(db.transaction((tx) async {
        await MemoryRepo(tx).add('fact before failure');
        expect(await tx.query('memory_history'), hasLength(1));
        await tx.insert('memories', {'created_at': 1, 'updated_at': 1});
      }), throwsA(isA<DatabaseException>()));
      expect(await db.query('memories'), isEmpty);
      expect(await db.query('memories_fts'), isEmpty);
      expect(await db.query('memory_history'), isEmpty);
    });

    test('a failed history insert rolls back add and bump', () async {
      await expectLater(repo.add('not committed', actor: 'unknown'),
          throwsA(isA<DatabaseException>()));
      expect(await db.query('memories'), isEmpty);
      expect(await db.query('memory_history'), isEmpty);
      final id = await repo.add('committed fact');
      final before = (await db.query('memories')).single;
      await expectLater(repo.add('committed fact', actor: 'unknown'),
          throwsA(isA<DatabaseException>()));
      expect((await db.query('memories')).single, before);
      expect(await repo.history(id), hasLength(1));
    });

    test('failed correction history rolls back insert, supersede, and FTS',
        () async {
      final id = await repo.add('coffee ritual');
      await db.execute(
          '''CREATE TRIGGER fail_history BEFORE INSERT ON memory_history
        WHEN new.event = 'supersede' BEGIN
        SELECT RAISE(ABORT, 'forced history failure'); END''');
      await expectLater(repo.addCorrection('tea ritual', replaces: 'coffee'),
          throwsA(isA<DatabaseException>()));
      expect((await repo.all()).single.id, id);
      expect((await repo.search('coffee')).single.id, id);
      expect(await repo.search('tea'), isEmpty);
      expect((await db.query('memory_history')).single['event'], 'add');
    });

    test('failed delete history rolls back the memory and FTS deletion',
        () async {
      final id = await repo.add('retained fact');
      await db.execute(
          '''CREATE TRIGGER fail_history BEFORE INSERT ON memory_history
        WHEN new.event = 'delete' BEGIN
        SELECT RAISE(ABORT, 'forced history failure'); END''');
      await expectLater(repo.delete(id), throwsA(isA<DatabaseException>()));
      expect((await repo.search('retained')).single.id, id);
      expect(await repo.history(id), hasLength(1));
    });

    test('save_memory recovery withholds unknown provenance despite matching content',
        () async {
      final id = await repo.add('User likes coffee');
      final receipt = await executor.run(
          ToolCall('save_memory', {'content': '  USER likes coffee!  '}),
          recovering: true);
      expect(receipt.status, ReceiptStatus.failed);
      expect(receipt.error, memoryRecoveryUnresolved);
      expect(await repo.history(id), hasLength(1));
    });

    test('save_memory correction carries actor and operation to every event',
        () async {
      final old = await repo.add('morning coffee ritual');
      await executor.run(
          ToolCall('save_memory', {
            'content': 'morning tea ritual',
            'replaces': 'coffee',
            'explicit': true,
          }),
          operationId: 'explicit-op');
      final added = await repo.activeIdForContent('morning tea ritual');
      for (final id in [old, added!]) {
        final row = (await repo.history(id)).last;
        expect(row['actor'], 'user');
        expect(row['op_id'], 'explicit-op');
      }
    });

    test(
        'session marks explicit remember as user and incidental facts as rules',
        () async {
      final session = AssistantSession(
          engine: RuleEngine(),
          tools: executor,
          memory: repo,
          profile: ProfileRepo(db),
          taskRepo: TaskRepo(db),
          conversations: ConversationRepo(db));
      await session.start();
      addTearDown(session.close);
      await session.handle('remember that I like green tea');
      final explicitId = (await repo.all()).single.id;
      expect((await repo.history(explicitId)).single['actor'], 'user');
      await session.handle('I live in Pune');
      final incidental =
          (await repo.all()).singleWhere((memory) => memory.id != explicitId);
      expect((await repo.history(incidental.id)).single['actor'], 'rules');
    });
  });
}
