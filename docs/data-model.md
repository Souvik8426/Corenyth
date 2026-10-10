# Data model

One SQLite file, `assistant.db`, in the app's databases directory (`getDatabasesPath()`). The Android widget reads the
same file directly, so the `tasks` columns are a contract with `WidgetProvider.kt`. Schema version: 1
(`lib/data/db.dart`).

## Tables

**tasks**
- `id` INTEGER PK autoincrement
- `title` TEXT not null, `notes` TEXT
- `status` TEXT: `pending` (default) or `done`
- `created_at`, `due_at`, `completed_at` INTEGER (epoch ms)
- `priority` INTEGER 0..2, default 1
- `recurrence` TEXT (reserved, unused)

**reminders**
- `id` PK, `task_id` FK → tasks(id) ON DELETE SET NULL
- `title` TEXT not null, `trigger_at` INTEGER (epoch ms), `enabled` INTEGER 1/0

**conversations**
- `id` PK, `session_id` TEXT, `role` TEXT, `content` TEXT, `created_at` INTEGER
- Index `conv_session(session_id, id)`

**memories**
- `id` PK, `content` TEXT, `category` TEXT default `fact`, `importance` REAL default 0.5
- `created_at`, `updated_at`, `last_accessed_at` INTEGER, `embedding` BLOB (reserved for a future embedder)

**memories_fts** (FTS4, `tokenize=unicode61`) with triggers `mem_ai`, `mem_au`, `mem_ad` that keep it in sync with
`memories.content`. FTS4 is used because older Android SQLite builds lack FTS5.

`PRAGMA foreign_keys = ON` is set on open.

## Repositories (`lib/data/repos.dart`)

- **TaskRepo**: `create`, `get`, `list(from, to, includeDone)` ordered by due date (nulls last), priority, id;
  `update`, `complete`, `delete`.
- **ReminderRepo**: `create`, `get`, `upcoming()` (enabled and in the future), `update`, `cancel` (sets `enabled = 0`).
- **ConversationRepo**: `add`, `recent(session, n)` (oldest first).
- **MemoryRepo**: `add`, `search`, `delete`, `all`.

## Memory rules

- `add` dedupes: a memory with the same set of terms (order ignored) only raises its importance by 0.1 (capped at 1.0).
  The dedupe is an O(n) scan. Fine for thousands of rows.
- `search(query)`: tokenizes into lowercase terms of 2+ letters or digits, drops common stop words, then runs an FTS
  `OR` match. Results are scored by term hits (×2), importance, and recency (30-day decay). The top 3 are returned.
  Their `last_accessed_at` is updated.
- Memory holds user facts and preferences only. Tasks and reminders are answered from the database, not from memory.
