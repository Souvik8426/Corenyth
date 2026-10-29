# Data model

One SQLite file, `assistant.db`, in the app's databases directory (`getDatabasesPath()`). The Android widget reads the
same file directly, so the `tasks` columns are a contract with `WidgetProvider.kt`. Schema version: 9
(`lib/data/db.dart`). v2 added `assistant_profile`; v3 added `chats` (backfilled from existing messages) and
`reminders.sync`; v4 added `reminders.kind`, `tasks.alert_plan` and `assistant_preferences`; v5 added
`pending_clarifications`; v6 adds event details, daily schedules, global task questions, message metadata,
proactive occurrence keys and evening review participation. v7 adds the operation journal and task/reminder operation IDs; v8 adds memory provenance, active/superseded status and replacement links. Existing rows and saved preference choices are kept
(old reminders become `kind = 'reminder'`, old tasks get no stored plan). `test/backend_sqlite_test.dart` runs the
real v2 → v8 migration and fresh `onCreate` with `sqflite_common_ffi`; macOS uses system SQLite through the sqlite3 hook so production FTS4 retrieval is exercised.

## Tables

**tasks**
- `id` INTEGER PK autoincrement
- `title` TEXT not null, `notes` TEXT
- `status` TEXT: `pending` (default) or `done`
- `created_at`, `due_at`, `completed_at` INTEGER (epoch ms)
- `op_id` TEXT nullable (v7), indexed; identifies the operation that created the task
- `priority` INTEGER 0..2, default 1
- `recurrence` TEXT (`daily` for a daily reminder; otherwise null)
- `ends_at`, `deadline_at`, `awaiting_at` INTEGER nullable (epoch ms); event end, confirmed recurrence deadline,
  and when the optional task question was opened
- `subject`, `outcome`, `awaiting` TEXT nullable; `awaiting` is `details` or `outcome`, shared across chats
- `daily_minute` INTEGER nullable (minutes after midnight); `due_at` holds the next occurrence separately from its deadline
- `alert_plan` TEXT (v4): JSON of the requested notification plan, `{"lead":[30,10],"follow":60}` (`lead` empty =
  single alert, no `follow` = no follow-up). Kept after its alerts fire or were skipped. Null = no plan, or the plan
  was cancelled/completed (never regenerated).

**reminders**
- `id` PK, `task_id` FK → tasks(id) ON DELETE SET NULL
- `title` TEXT not null, `trigger_at` INTEGER (epoch ms), `enabled` INTEGER 1/0
- `op_id` TEXT nullable (v7), indexed; identifies the operation that created the reminder
- `kind` TEXT (v4): `reminder` (event time), `pre` (early alert) or `follow_up` (fixed "How did X go?" text)
- `sync` TEXT: pending platform alarm operation, `schedule` or `cancel`; null once the platform call succeeded.
  The intent is written before the platform call; startup reconciliation (`ReminderScheduler.rescheduleAll`) re-arms
  enabled upcoming rows, retries pending cancels, and clears intents that succeed. A disabled row is never re-armed.

**assistant_preferences** (v4)
- single row `id = 1`: `multiple`, `follow_up` (0/1, both off by default), `lead_minutes` TEXT (`'30,10'`, 1–3 values
  of 1–1440), `follow_up_minutes` (default 60, 5–1440), `quiet_start` / `quiet_end` (minutes after midnight, null =
  off, may wrap midnight)

**chats**
- `id` TEXT PK (= `conversations.session_id`), `title` TEXT (first user message, 60 chars; empty = "New chat"),
  `created_at`, `updated_at`

**assistant_profile**
- single row `id = 1`: `name`, `occupation`, `tone`, `onboarding_complete`

**conversations**
- `id` PK, `session_id` TEXT, `role` TEXT, `content` TEXT, `created_at` INTEGER
- `task_id` nullable FK to tasks with ON DELETE SET NULL, `kind` nullable TEXT; used for proactive message context
- Index `conv_session(session_id, id)`

**memories**
- `id` PK, `content` TEXT, `category` TEXT default `fact`, `importance` REAL default 0.5
- `created_at`, `updated_at`, `last_accessed_at` INTEGER, `embedding` BLOB (reserved for a future embedder)
- v8: `op_id`, `source` TEXT nullable; `status` TEXT default `active`; `superseded_by` INTEGER nullable. Superseded rows are excluded from active retrieval.

**memories_fts** (FTS4, `tokenize=unicode61`) with triggers `mem_ai`, `mem_au`, `mem_ad` that keep it in sync with
`memories.content`. FTS4 is used because older Android SQLite builds lack FTS5.

**operations** (v7): `op_id` TEXT PK, `chat_id`, `text_hash`, `status` TEXT not null; `action`, `receipt` TEXT nullable; `created_at`, `updated_at` INTEGER. The journal stores the validated action and receipt for replay/recovery. Task/reminder operation stamps allow committed rows to be recovered without recomputing a relative time after restart. It is not a substitute for delivery verification.

`PRAGMA foreign_keys = ON` is set on open.

**proactive_events** (v6): `key` TEXT PK, `task_id` nullable FK to tasks ON DELETE SET NULL, `created_at` INTEGER.
An alert occurrence uses `alert:<reminder id>:<trigger ms>`; a daily review uses `review:yyyy-mm-dd`.
`ConversationRepo.addProactive` records the key and main-chat message atomically. Deleting display history preserves
keys so reopening cannot replay previously delivered occurrences. The reserved main chat id is `main`.

**review_items** (v6): `day` TEXT, `task_id` FK to tasks ON DELETE CASCADE, `answered` INTEGER default 0;
composite primary key `(day, task_id)`. Ignored tasks remain review candidates without changing their deadlines.

When there is no preferences row, quiet hours default to 22:00–07:00. Saved times and explicit off are preserved.
The evening review minute is 30 minutes before quiet start, or 21:30 when quiet hours are explicitly off.
Every committed preference save notifies the scheduler, including enabling follow-ups and changing quiet hours.

`ConversationRepo.relevant` retrieves matching user messages across display chats, excluding assistant assertions.
`TaskRepo.setEventDetails` preserves the supplied end and regenerates its follow-up plan, including quiet-hour skips.
`setDaily` and `advanceDaily` keep the deadline separate, skip missed occurrences, and preserve a future snooze.

**pending_clarifications** (v5): `chat_id` TEXT PK, `draft` TEXT (JSON `{"tool","title","multiple"?,
"follow_up"?,"time"?}`), `updated_at`. New missing-time questions use the reserved `main` key so any display chat
can answer them. Legacy per-chat rows remain readable in their original chat. Task-specific meeting details/outcome
questions use the task's `awaiting` field instead. Typed target picks use `pick:<chat>` keys, storing the intended tool, arguments, candidate IDs, optional shift and asked-at time; they survive restart and expire after six hours.

## Repositories (`lib/data/repos.dart`)

- **TaskRepo**: `create`, `get`, `list(from, to, includeDone)` ordered by due date (nulls last), priority, id;
  `update`, `complete`, `delete`.
- **ReminderRepo**: `create` (with `sync = 'schedule'`), `get`, `upcoming()` (enabled and in the future), `update`,
  `cancel` (`enabled = 0`, `sync = 'cancel'` in one write), `synced`, `pending`, `delete`, `byTitle` (one match per
  plan, its event alert), `createPlan`, `forTask`, `cancelGroup`, `followUpTasks`, `planOf`, `restorePlan`.
- **ReminderPreferencesRepo**: `get`, `save` (validates; turning follow-ups off cancels queued follow-ups and strips
  them from stored plans, in one transaction).

## Notification plans

- `reminderPlan(at, prefs, multiple, followUp, now)` (pure) gives the alerts: early alerts at the lead offsets,
  the event alert, and a follow-up `follow_up_minutes` after the start. Early alerts and the follow-up are skipped
  when past or in quiet hours; the event alert is always kept.
- `createPlan` saves the task (or, with `task_id`, replaces that task's plan: old alerts get a cancel intent and the
  due time moves), the alerts and `tasks.alert_plan` in one transaction. `restorePlan` undoes a failed replacement.
- `TaskRepo.update` is shared by chat and the Tasks page. Done or due cleared: every linked alert is cancelled and
  `alert_plan` cleared. New due time with a stored plan: the plan is regenerated from it with the current quiet
  hours, so offsets skipped before come back when the new time allows. Rows are reused per kind and offset (same
  notification id), missing ones are inserted with new ids, leftovers are cancelled. Tasks without a stored plan
  (pre-v4) shift their alerts and drop ones now past or in quiet hours. A rename renames the alerts.
- Every change is a pending intent (`sync`), applied by `ReminderScheduler.syncPending` after the write and retried
  at startup; a cancelled row is never re-armed.
- **ConversationRepo**: `createChat`, `add`, `listChats` (newest first), `messages`, `deleteChat`, `recent(session, n)`.
- **MemoryRepo**: `add`, `search`, `delete`, `all`.

## Memory rules

- `add` dedupes normalized text without ignoring word order, raising duplicate importance by 0.1 (capped at 1.0).
  The dedupe is an O(n) scan. Fine for thousands of rows.
- `search(query)`: tokenizes into lowercase terms of 2+ letters or digits, drops common stop words, then runs an FTS
  `OR` match. Results are scored by term hits (×2), importance, and recency (30-day decay). The top 3 are returned.
  Their `last_accessed_at` is updated.
- Memory holds user facts and preferences only. Tasks and reminders are answered from the database, not from memory.

- Correction uses recognized subject/attribute slots. Insertion and supersession share a transaction; replaced facts leave the FTS index. Slot recognition is bounded and is not general semantic memory understanding.
- `relevantForContext` retrieves active relevant facts with bounded preference fallback for planning and prose prompts. Durable personal facts are excluded from replayed chat history so deleted/replaced facts are not restored through that path.
- `TaskRepo.relevantTasks` ranks relevant tasks and explicit older IDs before the context cap. Mutable task facts remain sourced from task rows.
- Memory is local SQLite; Mem0 and an embedding runtime are not connected.

## v9 message moods

`message_moods` links a model-origin mood reading to its user conversation row. It stores chat ID, optional mood/confidence, intensity, source and timestamp; deleting the message cascades to its mood record. Missing readings retain unknown provenance and display the calm fallback.
