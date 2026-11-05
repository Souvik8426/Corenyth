import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'repos.dart' show extractMemorySlot;

/// Single SQLite file. The Android widget reads `tasks` from the same file
/// (see WidgetProvider.kt), so keep the file name and the tasks columns stable.
const dbFileName = 'assistant.db';

/// Current schema version. Every upgrade is additive (see each `_create…`).
const dbVersion = 13;

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
      superseded_by INTEGER,
      content_hash TEXT,
      subject_key TEXT,
      attribute_key TEXT,
      observed_at_utc INTEGER,
      observation_offset_min INTEGER,
      fact_date TEXT)''');
    await db.execute(
        'CREATE INDEX memories_status_hash ON memories(status, content_hash)');
    await db.execute(
        'CREATE INDEX memories_slot ON memories(status, subject_key, attribute_key)');
    // FTS4 (not FTS5): guaranteed in every Android SQLite build.
    await db.execute(
        'CREATE VIRTUAL TABLE memories_fts USING fts4(content, tokenize=unicode61)');
    await _createActiveMemoryFtsTriggers(db);
    await _createProfileTable(db);
    await createChatsTable(db);
    await _createAssistantPreferences(db);
    await _createPending(db);
    await _createFollowThrough(db);
    await _createOperations(db);
    await _createMemoryProvenance(db);
    await _createMessageMoods(db);
    await _createMemoryHistory(db);
    await _createMemoryExtraction(db);
    await _createExtractionProvenance(db);
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
    if (oldVersion < 10 && newVersion >= 10) await _createMemoryIndexing(db);
    if (oldVersion < 11 && newVersion >= 11) await _createMemoryHistory(db);
    if (oldVersion < 12 && newVersion >= 12) {
      await _createMemoryExtraction(db);
      await _createActiveMemoryFtsTriggers(db);
    }
    if (oldVersion < 13 && newVersion >= 13) {
      await _createExtractionProvenance(db);
    }
  }, onOpen: (db) async {
    // Plan 1.6.1: record the journal mode before deciding on WAL. Logged
    // only; this does not change the mode.
    try {
      final rows = await db.rawQuery('PRAGMA journal_mode');
      lastJournalMode =
          rows.isEmpty ? null : rows.first.values.first as String?;
      if (kDebugMode) debugPrint('assistant.db journal_mode=$lastJournalMode');
    } catch (_) {}
  });
}

/// The `PRAGMA journal_mode` the last [openAppDb] connection reported, or
/// null if it could not be read (plan 1.6.1; diagnostics only).
String? lastJournalMode;

/// v13: no historical link is inferred. Both links and write markers are
/// local processing state, excluded from backups. Deleting the source revokes
/// its proof while retaining the legacy journal for conservative recovery.
Future<void> _createExtractionProvenance(DatabaseExecutor db) async {
  await db
      .execute('ALTER TABLE operations ADD COLUMN source_message_id INTEGER '
          'REFERENCES conversations(id) ON DELETE SET NULL');
  await db.execute('CREATE UNIQUE INDEX operations_source '
      'ON operations(source_message_id)');
  for (final event in ['INSERT', 'UPDATE']) {
    await db.execute('''CREATE TRIGGER operation_source_${event.toLowerCase()}
      BEFORE $event ON operations WHEN new.source_message_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM conversations c
        WHERE c.id = new.source_message_id AND c.session_id = new.chat_id
          AND c.role = 'user')
      BEGIN SELECT RAISE(ABORT, 'Invalid operation source'); END''');
  }
  await db.execute('''CREATE TRIGGER operation_source_identity
    BEFORE UPDATE OF source_message_id ON operations
    WHEN old.source_message_id IS NOT NULL AND new.source_message_id IS NOT NULL
      AND old.source_message_id != new.source_message_id
    BEGIN SELECT RAISE(ABORT, 'Operation source is immutable'); END''');
  await db.execute('''CREATE TRIGGER conversation_source_identity
    BEFORE UPDATE OF session_id, role ON conversations
    WHEN EXISTS (SELECT 1 FROM operations o WHERE o.source_message_id = old.id)
      AND (new.session_id != old.session_id OR new.role != old.role)
    BEGIN SELECT RAISE(ABORT, 'Linked source identity is immutable'); END''');
  await db.execute('''CREATE TABLE memory_write_sources(
    message_id INTEGER PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE)
    ''');
  await db.execute('''CREATE TRIGGER memory_write_source_verified
    BEFORE INSERT ON memory_write_sources
    WHEN NOT EXISTS (SELECT 1 FROM operations o JOIN conversations c
      ON c.id = o.source_message_id
      WHERE c.id = new.message_id AND c.role = 'user'
        AND c.session_id = o.chat_id)
    BEGIN SELECT RAISE(ABORT, 'Unverified memory source'); END''');
}

/// v12 storage only: no opt-in, watermark, or executable job is created.
/// These local processing records are deliberately outside the backup format.
/// Backup replacement deletes conversations/chats, cascading these records;
/// imported suggestions remain reviewable but have no extraction provenance.
/// An explicit future opt-in must establish a new baseline after import.
Future<void> _createMemoryExtraction(DatabaseExecutor db) async {
  await db.execute('''CREATE TABLE extraction_state(
    chat_id TEXT PRIMARY KEY REFERENCES chats(id) ON DELETE CASCADE,
    last_message_id INTEGER NOT NULL)''');
  // The source key survives accepting/rejecting/purging its memory, preventing
  // a second suggestion for that message. suggestion_id retains the audit
  // identity after removal; memory_id follows an accepted active row until
  // purge. No source text is copied here.
  await db.execute('''CREATE TABLE extraction_sources(
    message_id INTEGER PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,
    suggestion_id INTEGER NOT NULL UNIQUE,
    memory_id INTEGER REFERENCES memories(id) ON DELETE SET NULL)''');
  await db.execute(
      'CREATE INDEX extraction_sources_memory ON extraction_sources(memory_id)');
}

/// Both new databases and v11 upgrades index active rows only. Some legacy
/// host fixtures omit FTS entirely; keep their migration path supported.
Future<void> _createActiveMemoryFtsTriggers(DatabaseExecutor db) async {
  final fts = await db.query('sqlite_master',
      columns: ['name'], where: 'name = ?', whereArgs: ['memories_fts']);
  if (fts.isEmpty) return;
  for (final trigger in ['mem_ai', 'mem_au', 'mem_ad']) {
    await db.execute('DROP TRIGGER IF EXISTS $trigger');
  }
  await db.execute('''CREATE TRIGGER mem_ai AFTER INSERT ON memories
    WHEN new.status = 'active' BEGIN
    INSERT INTO memories_fts(docid, content) VALUES (new.id, new.content); END''');
  await db.execute(
      '''CREATE TRIGGER mem_au AFTER UPDATE OF content, status ON memories BEGIN
    DELETE FROM memories_fts WHERE docid = old.id;
    INSERT INTO memories_fts(docid, content)
      SELECT new.id, new.content WHERE new.status = 'active'; END''');
  await db.execute('''CREATE TRIGGER mem_ad AFTER DELETE ON memories BEGIN
    DELETE FROM memories_fts WHERE docid = old.id; END''');
  await db.execute('DELETE FROM memories_fts WHERE docid NOT IN '
      "(SELECT id FROM memories WHERE status = 'active')");
}

/// v11 memory audit trail; no foreign key so history survives a purge.
Future<void> _createMemoryHistory(DatabaseExecutor db) async {
  await db.execute('''CREATE TABLE memory_history(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    memory_id INTEGER NOT NULL,
    event TEXT NOT NULL CHECK(event IN ('add','bump','supersede','delete','restore','purge','edit','accept','reject')),
    old_content TEXT, new_content TEXT,
    actor TEXT NOT NULL CHECK(actor IN ('user','rules','model','system')),
    op_id TEXT,
    created_at INTEGER NOT NULL)''');
  await db.execute(
      'CREATE INDEX memory_history_mem ON memory_history(memory_id, id)');
  final columns = (await db.rawQuery('PRAGMA table_info(memories)'))
      .map((row) => row['name'])
      .toSet();
  for (final column in ['deleted_at', 'expires_at']) {
    if (!columns.contains(column)) {
      await db.execute('ALTER TABLE memories ADD COLUMN $column INTEGER');
    }
  }
}

/// v10 indexed personal memory representation (content_hash, slot keys, observation metadata).
Future<void> _createMemoryIndexing(DatabaseExecutor db) async {
  final columns = (await db.rawQuery('PRAGMA table_info(memories)'))
      .map((row) => row['name'])
      .toSet();
  for (final entry in {
    'content_hash': 'TEXT',
    'subject_key': 'TEXT',
    'attribute_key': 'TEXT',
    'observed_at_utc': 'INTEGER',
    'observation_offset_min': 'INTEGER',
    'fact_date': 'TEXT',
  }.entries) {
    if (!columns.contains(entry.key)) {
      await db.execute(
          'ALTER TABLE memories ADD COLUMN ${entry.key} ${entry.value}');
    }
  }
  await db.execute(
      'CREATE INDEX IF NOT EXISTS memories_status_hash ON memories(status, content_hash)');
  await db.execute(
      'CREATE INDEX IF NOT EXISTS memories_slot ON memories(status, subject_key, attribute_key)');

  // Deterministic backfill in migration transaction without inference.
  await indexMemoryRows(db);
}

/// Fills the derived lookup columns (content hash, slot keys) of every
/// memory row from its text. Used by the v10 migration and after a backup
/// restore, whose rows carry content but not these derived keys.
Future<void> indexMemoryRows(DatabaseExecutor db) async {
  final rows = await db.query('memories', columns: ['id', 'content']);
  for (final r in rows) {
    final id = r['id'] as int;
    final content = r['content'] as String? ?? '';
    final norm = content
        .toLowerCase()
        .replaceAll(RegExp(r'[.!?]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final hash = sha256.convert(utf8.encode(norm)).toString();
    final slot = extractMemorySlot(content);
    await db.update(
      'memories',
      {
        'content_hash': hash,
        'subject_key': slot?.subject,
        'attribute_key': slot?.slot,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }
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
