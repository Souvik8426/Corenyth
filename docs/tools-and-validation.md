# Tools and validation

The model never changes app state. It proposes one JSON tool call. Code validates the call, then runs it.

## Tools

Defined in `toolSchemas` (`lib/assistant/tools.dart`). Argument types: `s` string, `i` integer, `d` ISO-8601 datetime,
`b` bool. A trailing `!` marks a required argument.

| Tool | Arguments |
|---|---|
| `create_task` | `title!` `notes` `due` `priority` |
| `edit_task` | `id!` `title` `notes` `due` `priority` |
| `complete_task` | `id!` |
| `delete_task` | `id!` |
| `list_tasks` | `from` `to` `include_done` |
| `create_reminder` | `title!` `at!` `task_id` |
| `edit_reminder` | `id!` `title` `at` |
| `cancel_reminder` | `id!` |
| `search_memory` | `query!` |
| `respond` | `text!` (no state change; the text is the reply) |

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
   - Strings: non-empty after trim, at most 500 chars, trimmed on store.
   - Integers: accept int or numeric string. Priority also accepts words: `low`=0, `normal`/`medium`=1, `high`=2.
     Priority must be 0..2.
   - Datetimes: `DateTime.tryParse`. Invalid raises `ToolError`.
   - Bools: must be a real bool.
   - Unknown extra fields are dropped.

Any `ToolError` means the call is never executed.

## Execution (`ToolExecutor.execute`)

| Tool | Behaviour |
|---|---|
| `create_task` | Inserts with priority (default 1). Refreshes the widget. Reply: "Added task …". |
| `edit_task` | Exactly one of `id` or `target_title` (exact current title; `title` is the new one). Needs at least one field. Ambiguous title → asks which. Refreshes the widget. |
| `complete_task` / `delete_task` | Id or exact (case/punctuation-insensitive) title. Several matches → lists them and asks which; never guesses. Refreshes the widget. |
| `list_tasks` | Pending tasks by default. Returns "No tasks." when empty. |
| `create_reminder` | Rejects times in the past. Rejects an unknown `task_id`. Inserts with a pending `schedule` intent, schedules, clears the intent. Schedule failure deletes the row and says it was not saved. |
| `edit_reminder` | `id` or `target_title`. Only enabled reminders. Re-schedules; on failure restores the old values and alarm (if that also fails, the intent stays pending for startup). |
| `cancel_reminder` | Id or exact title. Disables the row with a pending `cancel` intent first, then cancels the alarm. On platform failure it says the alarm may still go off and retries at startup; never re-armed. |
| `search_memory` | Returns top memories or "I have nothing stored about that." |
| `respond` | Returns the text. |

Errors (`ToolError`) reach the user as the reply text. Other exceptions are not caught here. The widget refresh after
a task write is best effort and never fails the call.

## Grammar sync

`toolGrammar` is generated from `toolSchemas`, so the grammar and the validator read the same table. When you add a
tool or argument, update `toolSchemas` and the `ToolExecutor` switch. The grammar follows automatically. Also update
the tool list in `Prompt.actionSystem` (`engine.dart`), which is hand-written.
