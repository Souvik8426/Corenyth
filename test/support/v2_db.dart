import 'dart:io';

import 'package:assistant/data/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// A v2 `assistant.db` (as shipped in v2, minus the FTS4 index the host FFI
/// SQLite lacks), optionally seeded, then migrated to the current version by
/// [openAppDb]; closed and deleted on test teardown. Fresh `onCreate` cannot run on the host (FTS4).
Future<Database> openMigratedV2(
    {Future<void> Function(Database db)? seed}) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = await Directory.systemTemp.createTemp('corenyth-db');
  final path = '${dir.path}/assistant.db';
  final old = await openDatabase(path, version: 2, onCreate: (db, _) async {
    await db.execute('CREATE TABLE tasks(id INTEGER PRIMARY KEY AUTOINCREMENT, '
        "title TEXT NOT NULL, notes TEXT, status TEXT NOT NULL DEFAULT 'pending', "
        'created_at INTEGER NOT NULL, due_at INTEGER, completed_at INTEGER, '
        'priority INTEGER NOT NULL DEFAULT 1, recurrence TEXT)');
    await db.execute('CREATE TABLE reminders(id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL, '
        'title TEXT NOT NULL, trigger_at INTEGER NOT NULL, '
        'enabled INTEGER NOT NULL DEFAULT 1)');
    await db.execute('CREATE TABLE conversations (id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'session_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL, '
        'created_at INTEGER NOT NULL)');
    await db.execute('CREATE TABLE memories(id INTEGER PRIMARY KEY AUTOINCREMENT, '
        "content TEXT NOT NULL, category TEXT NOT NULL DEFAULT 'fact', "
        'importance REAL NOT NULL DEFAULT 0.5, created_at INTEGER NOT NULL, '
        'updated_at INTEGER NOT NULL, last_accessed_at INTEGER, embedding BLOB)');
    await db.execute('CREATE TABLE assistant_profile(id INTEGER PRIMARY KEY CHECK(id = 1), '
        "name TEXT NOT NULL DEFAULT '', occupation TEXT NOT NULL DEFAULT '', "
        "tone TEXT NOT NULL DEFAULT 'cheerful', onboarding_complete INTEGER NOT NULL DEFAULT 0)");
    await seed?.call(db);
  });
  await old.close();
  final db = await openAppDb(path: path);
  addTearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  return db;
}
