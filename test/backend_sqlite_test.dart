import 'dart:io';

import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/v2_db.dart';

void main() {
  test('v2 migration preserves messages and backfills chat metadata', () async {
    final migrated = await openMigratedV2(seed: (db) async {
      await db.insert('reminders', {'title': 'old', 'trigger_at': 9000});
      await db.insert(
          'tasks', {'title': 'legacy', 'created_at': 1, 'due_at': 9000});
      await db.insert('conversations', {
        'id': 1,
        'session_id': 'old-chat',
        'role': 'user',
        'content': 'Help me plan my day',
        'created_at': 1000
      });
      await db.insert('conversations', {
        'id': 2,
        'session_id': 'old-chat',
        'role': 'assistant',
        'content': 'Here are your tasks',
        'created_at': 2000
      });
    });
    {
      expect(await migrated.getVersion(), dbVersion);
      // v7 durable operation identity & data preservation:
      final legacyTask =
          (await migrated.query('tasks', where: "title = 'legacy'")).single;
      expect(legacyTask['op_id'], isNull);
      final legacyReminder =
          (await migrated.query('reminders', where: "title = 'old'")).single;
      expect(legacyReminder['op_id'], isNull);

      // Home-screen widget tasks query preserves compatibility:
      final widgetRows =
          await migrated.query('tasks', columns: ['title', 'status', 'due_at']);
      expect(widgetRows, isNotEmpty);

      // Operations table and OperationJournal work correctly:
      final journal = OperationJournal(migrated);
      await journal.begin('op-v7', 'chat-v7', 'hash-v7');
      final op = await journal.get('op-v7');
      expect(op, isNotNull);
      expect(op!.status, OperationJournal.started);
      expect(op.chatId, 'chat-v7');
      expect(op.textHash, 'hash-v7');

      final repo = ConversationRepo(migrated);
      final chats = await repo.listChats();
      expect(chats.single.id, 'old-chat');
      expect(chats.single.title, 'Help me plan my day');
      expect(chats.single.updatedAt.millisecondsSinceEpoch, 2000);
      expect((await repo.messages('old-chat')).map((m) => m.content),
          ['Help me plan my day', 'Here are your tasks']);
      final empty = await repo.createChat();
      expect((await repo.listChats()).length, 2);
      expect(await repo.messages(empty), isEmpty);
      await repo.add(empty, 'user', 'A fresh question');
      await repo.add(empty, 'assistant', 'An answer');
      expect((await repo.listChats()).first.title, 'A fresh question');
      await repo.deleteChat('old-chat');
      expect(await repo.messages('old-chat'), isEmpty);
      expect((await repo.listChats()).single.id, empty);

      // v4 tasks.alert_plan: legacy tasks kept, with no stored plan.
      final legacy = await migrated.query('tasks', where: "title = 'legacy'");
      expect(
          (legacy.single['due_at'], legacy.single['alert_plan']), (9000, null));

      // v3 reminder intent column: existing rows are in sync.
      final reminders = ReminderRepo(migrated);
      expect((await reminders.get(1))!.sync, isNull);
      final r = await reminders.create('Call Mom', DateTime(2099));
      expect(r.sync, 'schedule');
      expect((await reminders.pending()).map((r) => r.id), [r.id]);
      await reminders.synced(r.id);
      expect(await reminders.pending(), isEmpty);
      await reminders.cancel(r.id);
      final cancelled = (await reminders.get(r.id))!;
      expect((cancelled.enabled, cancelled.sync), (false, 'cancel'));
      expect(await reminders.upcoming(), isEmpty, reason: 'never re-armed');
    }
  });
  test('fresh openAppDb onCreate and FTS probe', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('corenyth-probe-db');
    final path = '${dir.path}/assistant.db';
    try {
      final db = await openAppDb(path: path);
      final memRepo = MemoryRepo(db);
      final id1 = await memRepo.add('User prefers short direct answers');
      final id2 = await memRepo.add('User lives in Bangalore');
      expect(id2, greaterThan(id1));
      final hits = await memRepo.search('answers');
      expect(hits.map((m) => m.content),
          contains('User prefers short direct answers'));
      await db.update('memories', {'content': 'User prefers concise answers'},
          where: 'id = ?', whereArgs: [id1]);
      final hits2 = await memRepo.search('concise');
      expect(hits2.map((m) => m.content),
          contains('User prefers concise answers'));
      await memRepo.delete(id1);
      final hits3 = await memRepo.search('concise');
      expect(hits3, isEmpty);
      await db.close();
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
