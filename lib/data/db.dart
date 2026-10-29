import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Single SQLite file. The Android widget reads `tasks` from the same file
/// (see WidgetProvider.kt), so keep the file name and the tasks columns stable.
const dbFileName = 'assistant.db';

/// Current schema version. Every upgrade is additive (see each `_create…`).
const dbVersion = 9;

/// [version] below [dbVersion] only for migration tests (e.g. a v6 file).
Future<Database> openAppDb(
    {String? path,
    bool singleInstance = false,
    int version = dbVersion}) async {
  path ??= p.join(await getDatabasesPath(), dbFileName);
  // Each Flutter engine needs its own connection; recovering another engine's
  // single-instance connection can roll back an in-flight transaction.
  return openDatabase(path, version: version, singleInstance: singleInstance,
      onConfigure: (db) async {
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
      last_accessed_at INTEGER, embedding BLOB,
      op_id TEXT, source TEXT, status TEXT NOT NULL DEFAULT 'active',
      superseded_by INTEGER)''');
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
    await _createFollowThrough(db);
    await _createOperations(db);
    await _createMemoryProvenance(db);
    await _createMessageMoods(db);
  }, onUpgrade: (db, oldVersion, newVersion) async {
    if (oldVersion < 2) await _createProfileTable(db);
    if (oldVersion < 3) {
      await createChatsTable(db);
      await db.execute('ALTER TABLE reminders ADD COLUMN sync TEXT');
    }
    if (oldVersion < 4) await _createAssistantPreferences(db);
    if (oldVersion < 5) await _createPending(db);
    if (oldVersion < 6 && newVersion >= 6) await _createFollowThrough(db);
    if (oldVersion < 7 && newVersion >= 7) await _createOperations(db);
    if (oldVersion < 8 && newVersion >= 8) await _createMemoryProvenance(db);
    if (oldVersion < 9 && newVersion >= 9) await _createMessageMoods(db);
  });
}

/// v9 per-turn mascot mood records, keyed by the `conversations` row of the
/// user message the turn submitted (see [MoodRepo]). `mood` null = the model
/// reported no listed mood (unknown provenance) — the UI renders calm and
/// never infers one from text. Additive: old rows simply have no record and
/// display unknown/calm without any inference. Deleting a chat cascades.
Future<void> _createMessageMoods(DatabaseExecutor db) async {
  await db.execute('''CREATE TABLE message_moods(
    message_id INTEGER PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
    chat_id TEXT NOT NULL,
    mood TEXT,
    intensity REAL NOT NULL DEFAULT 0.25,
    confidence REAL,
    source TEXT NOT NULL,
    created_at INTEGER NOT NULL)''');
  await db.execute('CREATE INDEX message_moods_chat ON message_moods(chat_id)');
}

/// v8 memory provenance, status, and superseding support. Additive columns.
Future<void> _createMemoryProvenance(DatabaseExecutor db) async {
  final columns = (await db.rawQuery('PRAGMA table_info(memories)'))
      .map((row) => row['name'])
      .toSet();
  for (final entry in {
    'op_id': 'TEXT',
    'source': 'TEXT',
    'status': "TEXT NOT NULL DEFAULT 'active'",
    'superseded_by': 'INTEGER',
  }.entries) {
    if (!columns.contains(entry.key)) {
      await db.execute(
          'ALTER TABLE memories ADD COLUMN ${entry.key} ${entry.value}');
    }
  }
}

/// v7 durable operation identity (see OperationJournal). Additive only:
/// `tasks.op_id` / `reminders.op_id` name the submitted turn whose write
/// created the row, in the same insert, so a retry after a crash finds the
/// committed rows instead of writing them again. `operations` journals each
/// submitted turn (status, the validated action for crash recovery, and its
/// receipt); `text_hash` is a SHA-256 prefix, never the message. Old rows keep
/// null op ids; the widget's `tasks(title,status,due_at)` read is unchanged.
Future<void> _createOperations(DatabaseExecutor db) async {
  await db.execute('ALTER TABLE tasks ADD COLUMN op_id TEXT');
  await db.execute('ALTER TABLE reminders ADD COLUMN op_id TEXT');
  await db.execute('CREATE INDEX tasks_op ON tasks(op_id)');
  await db.execute('CREATE INDEX reminders_op ON reminders(op_id)');
  await db.execute('CREATE TABLE operations(op_id TEXT PRIMARY KEY, '
      'chat_id TEXT NOT NULL, text_hash TEXT NOT NULL, status TEXT NOT NULL, '
      'action TEXT, receipt TEXT, '
      'created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL)');
}

/// v6 follow-through. Only nullable columns and new tables, so old rows and
/// the widget's `tasks(title,status,due_at)` read stay valid.
/// tasks: `ends_at`/`subject` (optional meeting details), `deadline_at`
/// (confirmed deadline; also ends a daily recurrence), `daily_minute`
/// (daily reminder time, minutes after midnight, with `recurrence` 'daily';
/// `due_at` = next occurrence), `outcome` (what the user said happened),
/// `awaiting`/`awaiting_at` (the one open question about the task:
/// 'details' or 'outcome'; global, so it survives chat switches/restarts).
/// conversations: `task_id`/`kind` tag proactive messages.
/// proactive_events: one row per delivered occurrence key (idempotency).
/// review_items: tasks raised in each evening review (`day` = yyyy-mm-dd).
/// Saved quiet-hour choices are preserved; an absent preferences row gets
/// the 22:00-07:00 default when read by the repository.
Future<void> _createFollowThrough(DatabaseExecutor db) async {
  for (final c in [
    'ends_at INTEGER',
    'subject TEXT',
    'deadline_at INTEGER',
    'daily_minute INTEGER',
    'outcome TEXT',
    'awaiting TEXT',
    'awaiting_at INTEGER',
  ]) {
    await db.execute('ALTER TABLE tasks ADD COLUMN $c');
  }
  await db.execute('ALTER TABLE conversations ADD COLUMN '
      'task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL');
  await db.execute('ALTER TABLE conversations ADD COLUMN kind TEXT');
  await db.execute('CREATE TABLE proactive_events(key TEXT PRIMARY KEY, '
      'task_id INTEGER REFERENCES tasks(id) ON DELETE SET NULL, '
      'created_at INTEGER NOT NULL)');
  await db.execute('CREATE TABLE review_items(day TEXT NOT NULL, '
      'task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE, '
      'answered INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(day, task_id))');
}

/// v5: one open clarification per chat (structured JSON, see ClarifyDraft), so
/// it survives restarts without being re-read from assistant prose.
Future<void> _createPending(DatabaseExecutor db) =>
    db.execute('CREATE TABLE pending_clarifications(chat_id TEXT PRIMARY KEY, '
        'draft TEXT NOT NULL, updated_at INTEGER NOT NULL)');

/// v4: `reminders.kind` ('reminder' = event time, 'pre' = early alert,
/// 'follow_up') groups one task's notification plan; existing rows stay
/// 'reminder'. One preferences row; both extras are off by default.
/// Quiet hours are minutes after midnight (null = off).
/// `tasks.alert_plan`: the requested plan (JSON lead minutes + follow-up
/// delay, see AlertIntent), kept after its alerts fire or were skipped, so a
/// due change regenerates it. Null = no plan (or cancelled; never re-armed).
Future<void> _createAssistantPreferences(DatabaseExecutor db) async {
  await db.execute(
      "ALTER TABLE reminders ADD COLUMN kind TEXT NOT NULL DEFAULT 'reminder'");
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
