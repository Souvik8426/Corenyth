import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _RecordingScheduler extends NoopScheduler {
  final scheduled = <Reminder>[];
  @override
  Future<void> schedule(Reminder r) async => scheduled.add(r);
}

class _SlowOptionalEngine extends LlmEngine {
  bool optionalCalled = false;
  Future<void>? slowFuture;

  @override
  String get name => 'slow-engine';

  @override
  Future<bool> load() async => true;

  @override
  Future<void> unload() async {}

  @override
  Future<String> complete(Prompt p) async => '';

  @override
  Future<String> completeStreaming(Prompt p,
      {void Function(String text)? onText,
      void Function(String raw)? onRaw}) async {
    if (p.kind == PromptKind.reply && p.context?.contains('mascot mood') == true) {
      optionalCalled = true;
      if (slowFuture != null) await slowFuture;
      onRaw?.call('{"mood": "happy", "intensity": 0.8, "confidence": 0.9}');
      return '{"mood": "happy"}';
    }
    return '';
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('P6 Memory indexing, schema v10 and migration', () {
    test('v10 migration adds hash, slot columns, indices, and backfills legacy memories', () async {
      final dir = await Directory.systemTemp.createTemp('corenyth_v10_mig_');
      final dbPath = p.join(dir.path, 'v9.db');

      // Create v9 schema manually
      final v9Db = await openDatabase(
        dbPath,
        version: 9,
        onCreate: (db, _) async {
          await db.execute('''CREATE TABLE memories(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            content TEXT NOT NULL, category TEXT NOT NULL DEFAULT 'fact',
            importance REAL NOT NULL DEFAULT 0.5,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
            last_accessed_at INTEGER, embedding BLOB,
            op_id TEXT, source TEXT, status TEXT NOT NULL DEFAULT 'active',
            superseded_by INTEGER)''');
          await db.execute(
              'CREATE VIRTUAL TABLE memories_fts USING fts4(content, tokenize=unicode61)');
          await db.execute('''CREATE TABLE conversations(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL,
            created_at INTEGER NOT NULL, task_id INTEGER, kind TEXT)''');
          await db.execute('''CREATE TABLE tasks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL, notes TEXT, status TEXT NOT NULL DEFAULT 'pending',
            priority INTEGER NOT NULL DEFAULT 1, created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL, due_at INTEGER, recurrence TEXT,
            op_id TEXT)''');
          await db.execute('''CREATE TABLE reminders(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL, trigger_at INTEGER NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1, task_id INTEGER,
            sync TEXT, op_id TEXT)''');
          await db.execute('''CREATE TABLE operations(
            op_id TEXT PRIMARY KEY, chat_id TEXT NOT NULL,
            text_hash TEXT NOT NULL, status TEXT NOT NULL,
            action TEXT, receipt TEXT,
            created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)''');
          await db.execute('''CREATE TABLE message_moods(
            message_id INTEGER PRIMARY KEY, chat_id TEXT NOT NULL,
            mood TEXT, intensity REAL NOT NULL DEFAULT 0.25,
            confidence REAL, source TEXT NOT NULL, created_at INTEGER NOT NULL)''');
        },
      );

      // Seed with legacy memories without hash or slots
      await v9Db.insert('memories', {
        'content': 'User likes green tea',
        'category': 'preference',
        'importance': 0.6,
        'created_at': 1000,
        'updated_at': 1000,
        'status': 'active',
      });
      await v9Db.insert('memories', {
        'content': 'User lives in Bangalore',
        'category': 'fact',
        'importance': 0.5,
        'created_at': 2000,
        'updated_at': 2000,
        'status': 'active',
      });
      await v9Db.close();

      // Open through openAppDb to trigger upgrade to v10
      final v10Db = await openAppDb(path: dbPath);
      expect(await v10Db.getVersion(), dbVersion);
      expect(dbVersion, 10);

      // Verify new columns exist
      final columns = (await v10Db.rawQuery('PRAGMA table_info(memories)'))
          .map((r) => r['name'] as String)
          .toSet();
      expect(columns, containsAll([
        'content_hash',
        'subject_key',
        'attribute_key',
        'observed_at_utc',
        'observation_offset_min',
        'fact_date',
      ]));

      // Verify indices exist
      final indices = (await v10Db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'memories'"))
          .map((r) => r['name'] as String)
          .toSet();
      expect(indices, containsAll(['memories_status_hash', 'memories_slot']));

      // Verify deterministic backfill
      final rows = await v10Db.query('memories', orderBy: 'id ASC');
      expect(rows.length, 2);

      final row1 = rows[0];
      final expectedHash1 =
          sha256.convert(utf8.encode('user likes green tea')).toString();
      expect(row1['content_hash'], expectedHash1);
      expect(row1['subject_key'], 'user');
      expect(row1['attribute_key'], 'pref:drink:kind');
      expect(row1['observed_at_utc'], isNull);

      final row2 = rows[1];
      final expectedHash2 =
          sha256.convert(utf8.encode('user lives in bangalore')).toString();
      expect(row2['content_hash'], expectedHash2);
      expect(row2['subject_key'], 'user');
      expect(row2['attribute_key'], 'location:residence');

      // Now add new memory using MemoryRepo and verify fast dedupe / superseding
      final repo = MemoryRepo(v10Db);
      final newId = await repo.add('I like coffee now, not green tea',
          category: 'preference');

      // Prior tea preference must be superseded
      final teaRow = (await v10Db.query('memories',
          where: "content = 'User likes green tea'")).single;
      expect(teaRow['status'], 'superseded');
      expect(teaRow['superseded_by'], newId);

      // Active coffee preference must be present with indexed slot
      final coffeeRow = (await v10Db.query('memories',
          where: "content LIKE '%coffee%'")).single;
      expect(coffeeRow['status'], 'active');
      expect(coffeeRow['subject_key'], 'user');
      expect(coffeeRow['attribute_key'], 'pref:drink:kind');

      await v10Db.close();
      await dir.delete(recursive: true);
    });
  });

  group('P3 Foreground completion order and independent optional mood', () {
    test('foreground reply settles without awaiting optional mood', () async {
      final dir = await Directory.systemTemp.createTemp('corenyth_p3_');
      final db = await openAppDb(path: p.join(dir.path, 'p3.db'));
      final tasks = TaskRepo(db);
      final reminders = ReminderRepo(db);
      final memory = MemoryRepo(db);
      final conversations = ConversationRepo(db);
      final operations = OperationJournal(db);
      final profile = ProfileRepo(db);
      final moods = MoodRepo(db);
      final scheduler = _RecordingScheduler();
      final engine = _SlowOptionalEngine();

      // Block optional mood generation with an unsettled future
      final slow = Completer<void>();
      engine.slowFuture = slow.future;

      final session = AssistantSession(
        engine: engine,
        tools: ToolExecutor(tasks, reminders, memory, scheduler, clock: DateTime.now),
        memory: memory,
        profile: profile,
        taskRepo: tasks,
        conversations: conversations,
        operations: operations,
        moods: moods,
      );
      await session.start();

      String receivedReply = '';
      final stopwatch = Stopwatch()..start();
      final reply = await session.handle('add task buy milk', onText: (t) {
        receivedReply = t;
      });

      // Foreground turn completes immediately
      expect(stopwatch.elapsedMilliseconds, lessThan(2000));
      expect(reply, contains('buy milk'));
      expect(receivedReply, reply);

      // Assistant message and operation journal are committed before settlement
      final lastMsg = (await conversations.recent(session.id, n: 1)).single;
      expect(lastMsg.role, 'assistant');
      expect(lastMsg.content, reply);

      final op = await operations.get(session.lastOperationId!);
      expect(op, isNotNull);
      expect(op!.status, OperationJournal.replied);

      // Release optional mood
      slow.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await session.close();
      await db.close();
      await dir.delete(recursive: true);
    });
  });
}
