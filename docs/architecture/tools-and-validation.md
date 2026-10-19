# Tools and validation

The model never changes app state or chooses database ids and dates. It proposes a semantic plan; the session validates
the meaning, resolves user-provided dates and references, and builds a tool call for the executor. The rule engine can
also build validated calls directly.

## Tools

Defined in `toolSchemas` (`lib/assistant/tools.dart`). Argument types: `s` string, `i` integer, `d` ISO-8601 datetime,
`b` bool. A trailing `!` marks a required argument.

| Tool | Arguments |
|---|---|
| `create_task` | `title!` `notes` `due` `priority` |
| `edit_task` | `id` or `target_title` (exactly one), `title` `notes` `due` `priority` |
| `complete_task` | `id` or `title` (exactly one) |
| `delete_task` | `id` or `title` (exactly one) |
| `list_tasks` | `from` `to` `include_done` |
| `create_reminder` | `title!` `at!` `task_id` `multiple` `follow_up` |
| `list_reminders` | none |
| `edit_reminder` | `id` or `target_title` (exactly one), `title` `at` |
| `cancel_reminder` | `id` or `title` (exactly one) |
| `search_memory` | `query!` |
| `respond` | `text!` (no state change; the text is the reply) |

`target_title` is the current title of the item to edit, so it never mixes with the new `title`.

## Output shapes

```json
{"type":"respond","text":"Hi! How can I help?"}
{"type":"tool","tool":"create_task","arguments":{"title":"buy milk"}}
```

## Parsing (`parseToolCall`)

1. `extractJsonObject`: strips `<think>…</think>` blocks, then takes the first balanced `{…}` (tolerates code fences and
   chatter around it). Invalid JSON raises `ToolError`.
2. Checks `type` and that the tool name is known. `respond` takes `text` at the top level or in `arguments`.
3. `_validate` checks every schema field:
   - Unknown extra fields are rejected (`unknown argument`), not dropped.
   - Selector tools need exactly one of `id` or the title selector.
   - Strings: non-empty after trim, at most 500 chars, trimmed on store.
   - Integers: accept int or numeric string. Priority also accepts words: `low`=0, `normal`/`medium`=1, `high`=2.
     Priority must be 0..2; ids must be positive.
   - Datetimes: `parseLocalDateTime`, local `YYYY-MM-DDTHH:MM[:SS[.fff]]` only. Zone suffixes are rejected, and the
     fields must name a real local instant (Feb 30, 25:00 or a DST-gap hour are rejected, not normalized).
   - Bools: must be a real bool.

## Model output is a suggestion (`AssistantSession._act`)

Valid JSON is not proof of intent. `parseSemantic` checks the plan schema; `AssistantSession._act` then checks it
against the user's own words and current database state. If it fails, the rules answer instead and
`lastFallbackReason` says why.
- Reads (`respond`, `list_tasks`, `list_reminders`, `search_memory`) pass, except `search_memory` on a general
  knowledge question (it must not search personal memories) and a `respond` that claims an action it didn't take.
- Mutations need app-read authorization (including polite requests), a matching action cue, the title present in the request (or the id typed
  literally), and any date equal to the app's own parse of the text.
- `create_reminder`: `multiple` / `follow_up` must equal what the user stated (omitted unless stated; then saved
  preferences apply). `task_id` only when the request says "task N" / "task #N" / "task id N".
- Unsupported or conflicting whole-message time constraints take precedence over a valid model substring; the app asks a targeted question instead of guessing.
Both model-derived and rule-derived candidates pass through `validatePlan` in `turn_contract.dart` before execution.

Any `ToolError` means the call is never executed.

## Candidate, receipt and operation contract

`authorization.dart` distinguishes requests/statements from information questions, hypotheticals and negated actions. `CandidatePlan` carries the intended call, app-side effects, pending changes and evidence. A question mark alone does not make a polite action request read-only.

`ToolExecutor.executeWithReceipt` reports committed/replayed/read-only/no-write/failed outcomes and alarm status (`scheduled`, `permissionRequired`, `pendingRetry`, `none`). Confirmations follow persisted state and scheduler results. A scheduled receipt is not proof of physical notification delivery. Operation IDs and the journal support retry/restart recovery without creating a second reminder or shifting its time.

## Execution (`ToolExecutor.execute`)

| Tool | Behaviour |
|---|---|
| `create_task` | Inserts with priority (default 1). Refreshes the widget. Reply: "Added task …". |
| `edit_task` | Exactly one of `id` or `target_title` (exact current title; `title` is the new one). Needs at least one field. Ambiguous title → asks which. Refreshes the widget. |
| `complete_task` / `delete_task` | Id or exact (case/punctuation-insensitive) title. Several matches → lists them and asks which; never guesses. Refreshes the widget. |
| `list_tasks` | Pending tasks by default. Returns "No tasks." when empty. |
| `create_reminder` | Rejects times in the past, an unknown `task_id` and a done task ("restore it first"). A repeated request (same title and time) writes nothing. Builds the plan (`reminderPlan`, per-item `multiple`/`follow_up` overriding preferences) and saves task + alerts + stored plan in one transaction; with `task_id` it replaces that task's plan and due time. All or nothing: if any alert fails to schedule, the new task is deleted (or the prior plan, due time and alarms restored) and the reply says it was not saved, and also says when leftover alerts may still go off or earlier alarms may not be restored yet (pending intents retry). Replies list exact alert times, skipped early alerts and the follow-up time, and say so when notifications or exact alarms are off instead of promising. |
| `list_reminders` | Upcoming enabled reminders with friendly dates. |
| `edit_reminder` | `id` or `target_title` (a plan resolves to its event alert). Only enabled reminders. A plan's event alert moves the task and regenerates the whole plan via `TaskRepo.update`; on failure the prior due time and plan are regenerated. Standalone reminders re-schedule; on failure the old values and alarm are restored (if that also fails, the intent stays pending for startup). |
| `cancel_reminder` | Id or exact title. Disables the row (a plan: all its alerts, and clears the stored plan; the task stays) with a pending `cancel` intent first, then cancels the alarms. On platform failure it says the alarm may still go off and retries at startup; never re-armed. |
| `search_memory` | Returns top memories or "I have nothing stored about that." |
| `respond` | Returns the text. |

Errors (`ToolError`) reach the user as the reply text. Other exceptions are not caught here. The widget refresh after
a task write is best effort and never fails the call.

## Grammar sync

`toolGrammar` is generated from `toolSchemas`, so the grammar and the validator read the same table. When you add a
tool or argument, update `toolSchemas` and the `ToolExecutor` switch. The grammar follows automatically. Also update
the tool list in `Prompt.actionSystem` (`engine.dart`), which is hand-written.


The semantic plan grammars are separate from the legacy tool-call grammar. Both plan-v1 and opt-in plan-v2 use intent-specific branches matching the parser's allowed fields; valid grammar cannot justify skipping app-side authorization, temporal resolution or entity validation. See [reliability status](../development/reliability-status.md) for the failed held-out gate.
