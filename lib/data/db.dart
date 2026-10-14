import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Single SQLite file. The Android widget reads `tasks` from the same file
/// (see WidgetProvider.kt), so keep the file name and the tasks columns stable.
const dbFileName = 'assistant.db';

Future<Database> openAppDb({String? path}) async {
  path ??= p.join(await getDatabasesPath(), dbFileName);
  return openDatabase(path, version: 5, onConfigure: (db) async {
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
      enabled INTEGER NOT NULL DEFAULT 1, sync TEXT)''');
    await db.execute('''CREATE TABLE conversations(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id TEXT NOT NULL, role TEXT NOT NULL, content TEXT NOT NULL,
      created_at INTEGER NOT NULL)''');
    await db
        .execute('CREATE INDEX conv_session ON conversations(session_id, id)');
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
    await db.execute(
        '''CREATE TRIGGER mem_au AFTER UPDATE OF content ON memories BEGIN
      UPDATE memories_fts SET content = new.content WHERE docid = new.id; END''');
    await db.execute('''CREATE TRIGGER mem_ad AFTER DELETE ON memories BEGIN
      DELETE FROM memories_fts WHERE docid = old.id; END''');
    await _createProfileTable(db);
    await createChatsTable(db);
    await _createAssistantPreferences(db);
    await _createPending(db);
  }, onUpgrade: (db, oldVersion, newVersion) async {
    if (oldVersion < 2) await _createProfileTable(db);
    if (oldVersion < 3) {
      await createChatsTable(db);
      await db.execute('ALTER TABLE reminders ADD COLUMN sync TEXT');
    }
    if (oldVersion < 4) await _createAssistantPreferences(db);
    if (oldVersion < 5) await _createPending(db);
  });
}

/// v5: one open clarification per chat (structured JSON, see ClarifyDraft), so
/// it survives restarts without being re-read from assistant prose.
Future<void> _createPending(DatabaseExecutor db) => db.execute(
    'CREATE TABLE pending_clarifications(chat_id TEXT PRIMARY KEY, '
    'draft TEXT NOT NULL, updated_at INTEGER NOT NULL)');

/// v4: `reminders.kind` ('reminder' = event time, 'pre' = early alert,
/// 'follow_up') groups one task's notification plan; existing rows stay
/// 'reminder'. One preferences row; both extras are off by default.
/// Quiet hours are minutes after midnight (null = off).
/// `tasks.alert_plan`: the requested plan (JSON lead minutes + follow-up
/// delay, see AlertIntent), kept after its alerts fire or were skipped, so a
/// due change regenerates it. Null = no plan (or cancelled; never re-armed).
Future<void> _createAssistantPreferences(DatabaseExecutor db) async {
  await db.execute("ALTER TABLE reminders ADD COLUMN kind TEXT NOT NULL DEFAULT 'reminder'");
  await db.execute('ALTER TABLE tasks ADD COLUMN alert_plan TEXT');
  await db.execute('CREATE TABLE assistant_preferences('
      'id INTEGER PRIMARY KEY CHECK(id = 1), '
      'multiple INTEGER NOT NULL DEFAULT 0, follow_up INTEGER NOT NULL DEFAULT 0, '
      "lead_minutes TEXT NOT NULL DEFAULT '30,10', "
      'follow_up_minutes INTEGER NOT NULL DEFAULT 60, '
      'quiet_start INTEGER, quiet_end INTEGER)');
}

/// v3 also adds `reminders.sync`: a platform alarm operation ('schedule' or
/// 'cancel') persisted before it runs and cleared once it succeeded; startup
/// reconciliation retries whatever is still pending (see ReminderScheduler).
///
/// v3: one row per conversation (`conversations.session_id`), backfilled from
/// existing messages. Title = first user message (60 chars); empty chats allowed.
Future<void> createChatsTable(DatabaseExecutor db) async {
  await db.execute('''CREATE TABLE chats(
    id TEXT PRIMARY KEY, title TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)''');
  await db.execute('''INSERT INTO chats(id, title, created_at, updated_at)
    SELECT c.session_id,
      COALESCE((SELECT substr(u.content, 1, 60) FROM conversations u
        WHERE u.session_id = c.session_id AND u.role = 'user'
        ORDER BY u.id LIMIT 1), ''),
      MIN(c.created_at), MAX(c.created_at)
    FROM conversations c GROUP BY c.session_id''');
}

Future<void> _createProfileTable(DatabaseExecutor db) => db.execute('''
  CREATE TABLE assistant_profile(
    id INTEGER PRIMARY KEY CHECK(id = 1),
    name TEXT NOT NULL DEFAULT '',
    occupation TEXT NOT NULL DEFAULT '',
    tone TEXT NOT NULL DEFAULT 'cheerful',
    onboarding_complete INTEGER NOT NULL DEFAULT 0)
''');
