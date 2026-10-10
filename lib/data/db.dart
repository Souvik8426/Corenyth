import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Single SQLite file. The Android widget reads `tasks` from the same file
/// (see WidgetProvider.kt), so keep the file name and the tasks columns stable.
const dbFileName = 'assistant.db';

Future<Database> openAppDb({String? path}) async {
  path ??= p.join(await getDatabasesPath(), dbFileName);
  return openDatabase(path, version: 1, onConfigure: (db) async {
    await db.execute('PRAGMA foreign_keys = ON');
  }, onCreate: (db, _) async {
    await db.execute('''CREATE TABLE tasks(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL, notes TEXT,
      status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','done')),
      created_at INTEGER NOT NULL, due_at INTEGER, completed_at INTEGER,
      priority INTEGER NOT NULL DEFAULT 1 CHECK(priority BETWEEN 0 AND 2),
      recurrence TEXT)''');
    await db.execute('''CREATE TABLE reminders(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL,
      title TEXT NOT NULL, trigger_at INTEGER NOT NULL,
      enabled INTEGER NOT NULL DEFAULT 1)''');
    await db.execute('''CREATE TABLE conversations(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL,
      created_at INTEGER NOT NULL)''');
    await db.execute('CREATE INDEX conv_session ON conversations(session_id, id)');
    // embedding: reserved for a later ONNX embedder.
    await db.execute('''CREATE TABLE memories(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      content TEXT NOT NULL, category TEXT NOT NULL DEFAULT 'fact',
      importance REAL NOT NULL DEFAULT 0.5,
      created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
      last_accessed_at INTEGER, embedding BLOB)''');
    // FTS4 (not FTS5): guaranteed in every Android SQLite build.
    await db.execute(
        'CREATE VIRTUAL TABLE memories_fts USING fts4(content, tokenize=unicode61)');
    await db.execute('''CREATE TRIGGER mem_ai AFTER INSERT ON memories BEGIN
      INSERT INTO memories_fts(docid, content) VALUES (new.id, new.content); END''');
    await db.execute('''CREATE TRIGGER mem_au AFTER UPDATE OF content ON memories BEGIN
      UPDATE memories_fts SET content = new.content WHERE docid = new.id; END''');
    await db.execute('''CREATE TRIGGER mem_ad AFTER DELETE ON memories BEGIN
      DELETE FROM memories_fts WHERE docid = old.id; END''');
  });
}
