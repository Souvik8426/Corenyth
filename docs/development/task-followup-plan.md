# Follow-up Questions, Task Updates and Clash Warnings: Plan

Status: **proposal, nothing implemented.** Written 31 October 2026 against the current working tree of
`beta_version` (uncommitted changes on top of `c6492e2`; `dbVersion` 12, backup format 3). Every file and
line reference below is to that working tree. Default model: `Corenyth-Qwen3-0.6B-mood-Q4_0.gguf`,
fine-tuned on the plan-v1 contract (`training/app_prompts.py`).

Related: [memory-and-task-plan.md](memory-and-task-plan.md) (section 5B: several tasks in one message;
section 12: order of the main plan), [follow-through-device-checklist.md](follow-through-device-checklist.md).

**Contents**
1. What you asked for
2. What Corenyth does today (reproduction)
3. Root causes
4. Design in one page
5. Phase Q0: foundations
6. Phase Q1: asking, and routing the answer to the same task
7. Phase Q2: later changes update the existing task
8. Phase Q3: clash warnings
9. Phase Q4: model contract v3 (retrain)
10. Phase Q5: extras
11. Tests
12. Device checks
13. Order, sizes and suggested models
14. Decisions for you

---

## 1. What you asked for

The reference screenshot is from "Cally", not Corenyth. Our chat box says "Message Corenyth…"
(`lib/ui/chat_view.dart:360`), and the faded line at the top reads "…nothing is being added, it's only
emulation". It is treated here as the target behaviour.

| # | Requirement | Acceptance check |
|---|---|---|
| A1 | A detail given after a question goes into the **same** task. | "I gotta buy veggies" → "This evening" → "Yup onions and cabbage" leaves **one** task: *buy veggies*, this evening, items onions and cabbage. |
| A2 | A later message that changes a plan **updates** the existing task. | After the dinner thread, "Bloomberg doesn't have a table so I have to book table at Crescent" changes the booking's place to Crescent. No second booking task. |
| A3 | Questions are natural, few, and stop once what matters is known. | "I have a meeting this evening" → one question about time, place and people. After the answer, no more questions, and never transport, clothing or reasons. |
| A4 | Overlapping plans get a heads-up and are still saved. | "tonight at 10 … with wife", then "tonight at 11 … with friends" → the second is saved, with "Heads up: … at 10:00 PM, so this might overlap with it." |
| A5 | Ignoring a question loses nothing and doesn't cause repeats. | A question followed by an unrelated message: the task stays saved and the question is not asked again. |

Tasks already have a unique id (`tasks.id`, `INTEGER PRIMARY KEY AUTOINCREMENT`, `lib/data/db.dart:29-35`),
and SQLite never reuses an AUTOINCREMENT id, even after a delete. That id is the "uid" this plan uses
to track a task through a conversation. Q0.1 explains the one case where an id alone is not enough
(restoring a backup) and how the plan handles it.

---

## 2. What Corenyth does today (reproduction)

**Method.** Same as section 5B of the main plan:
- The real `AssistantSession`, `ToolExecutor` and SQLite on the host.
- A fake engine scripted with the best plan today's contract can express for each message: `create_task`, `answer_pending`, `details`, `postpone`.
- Both interpreters, plus a run with the model off.
- The clock was set to Sat 31 Oct 2026, 10:22.
- The test lived in the session scratchpad and was removed. Nothing in the repository changed.

**Thread A: the screenshot conversation** (unified interpreter; legacy is identical except turn 5, which is
`invalid_plan` because plan-v1 has no `details` intent):

| # | You | Corenyth replies | Stored |
|---|---|---|---|
| 1 | I gotta buy veggies | Added task buy veggies. When do you want to buy the veggies? | #1 *buy veggies*, no time |
| 2 | This evening | I'm not sure what you'd like me to do with that. I can add tasks, … | nothing (`rejected_answer_pending`: no open question exists) |
| 3 | Yup onions and cabbage | Added task onions and cabbage. Anything else to pick up? | #2 *onions and cabbage*: a second task |
| 4 | Also tonight have to go out for dinner soo have to book seats | Added task book seats, due today (Sat 31 Oct) at 8:00 PM. Tonight means 8 PM unless you say otherwise. Where are you going for dinner? | #3 *book seats*, 8 PM (a guess, stored as exact) |
| 5 | 4 for the family at Bloomberg | I'm not sure what you'd like me to do with that. … | nothing (`rejected_details`) |
| 6 | 8pm works | I'm not sure what you'd like me to do with that. … | nothing (`rejected_postpone`: "book seats" is not in the message) |
| 7 | Remind me to carry the gift which I bought for my wife | When should I remind you about "carry the gift which I bought for my wife"? | open time question (correct) |
| 8 | Bloomberg doesn't have a table so I have to book table at Crescent | Added task book table at Crescent. Okay. | #4: a duplicate; #3 untouched |

Result: four tasks where there should be two, and no place, party size or items stored anywhere.

**Thread C: clashes and the meeting question**

| # | You | Corenyth replies | Stored |
|---|---|---|---|
| 1 | tonight at 10 I have to go out with wife | Added task go out with wife, due today (Sat 31 Oct) at 10:00 PM. | #1 at 10 PM |
| 2 | tonight at 11 I have to go out with friends | Added task go out with friends, due today (Sat 31 Oct) at 11:00 PM. | #2 at 11 PM, **no warning** |
| 3 | I have a meeting this evening | Okay, I'll remind you today (Sat 31 Oct) at 7:00 PM: meeting. Optional: when does it end, and what is it about? Evening means 7 PM unless you say otherwise. Ooh, what is the meeting about? | reminder at 7 PM (a guess). It asks the end and subject, not the time, place or people, and the model asks the subject a second time. |
| 4 | at 6 with Aditya at the office | I'm not sure what you'd like me to do with that. … | nothing |

**Model off:**
- Thread A saves only #1.
- The rules don't read "tonight at 10 I have to go out with wife" at all, because the time comes before the statement. This is outside this plan (see section 13).

---

## 3. Root causes

| # | Cause | Where |
|---|---|---|
| R1 | **The question has no memory.** The model's follow-up line is appended to the reply as text, and nothing records which task was asked about or what was asked. The only stored questions are `ClarifyDraft`, which asks for the time of something not yet saved, and `tasks.awaiting = 'details'`, which asks for the end time and subject of a meeting that has a reminder. So "This evening" has nowhere to go. | Line set at `session.dart:2783-2791`, appended at `session.dart:599-602`; `rule_engine.dart:12-81`; `session.dart:2427-2436` |
| R2 | **Tasks can't hold the details.** The columns are title, notes, `due_at`, and the v6 meeting fields `ends_at` and `subject`. There is no place, people, party size or items, so even a perfect reading of "4 for the family at Bloomberg" has nowhere to be stored. | `db.dart:29-35`, `db.dart:298-325`; `Task` at `repos.dart:59-94` |
| R3 | **No intent for "change a detail of an existing task".** plan-v1 has create, complete, delete and postpone. plan-v2's `details` intent only reaches meetings that are awaiting details. | `semantic.dart:7-31, 68-86`; pool at `session.dart:3048-3057` |
| R4 | **Every reference has to be repeated.** complete, delete, postpone and details accept a target only when the task's own words are in the message, so "8pm works" can't refer to "book seats" even when the model gets it right. The safety rule is right; what's missing is "the task we just asked about" as a valid kind of evidence. | `session.dart:3278`, `session.dart:3061` |
| R5 | **Every create makes a new task.** `_create` never checks whether the message continues or changes a plan that already exists, which is why the Crescent duplicate appears. | `session.dart:3081-3241` |
| R6 | **Guessed times look exact.** Part-of-day defaults (morning 9, afternoon 15, evening 19, tonight 20) are stored in `due_at` like any exact time. Only a one-off note says it was a guess, so later the app can't ask for the real time or soften a clash warning. "A meeting this evening" is never asked its time, because `event_time` only fires when there is no time at all. | `temporal.dart:566-575`; `session.dart:3212-3220` |
| R7 | **The model's question is checked for safety, not relevance.** `isSafeFollowUp` rejects numbers, time words and claims of having acted. So "Are you going by car or bike?" passes, while the useful "What time should the booking be for?" is blocked by the word "time". The meeting question's wording is fixed to end time and subject. | `follow_through.dart:530-544`; `session.dart:2431-2434` |
| R8 | **There is no clash check anywhere** (no overlap code in `lib/`), and tasks have no length except a meeting's `ends_at`. | — |

---

## 4. Design in one page

**Rules every phase follows**
1. **Save first, ask after.** A task is saved as soon as it is understood, as today. Questions only refine it, so ignoring one loses nothing. Reminders still ask their time before saving, because an alert needs a time.
2. **The app decides, the model words.** App code decides from SQLite and the user's words:
   - which task a message is about;
   - which details to ask for;
   - what changed;
   - whether two plans clash.

   The model's reply line is used only when it asks exactly what the app chose.
3. **Grounded and undoable.** Every stored value is the user's own words, checked the same way titles are checked today. Every automatic change to an existing task can be undone.
4. **Ask little.**
   - The details asked for depend on the task's kind.
   - One question per turn, with at most 3 details in it.
   - At most 2 rounds per task.
   - The question stops on "skip" or when the user changes topic.
   - A setting turns questions down or off.
5. **No retrain needed for Q0–Q3.** All new routing is deterministic and runs before the model, so answers like "8pm works" also skip a model call. Q4 retrains later so the model can handle phrasings the rules miss.

**Phases**

| Phase | What it delivers |
|---|---|
| Q0 | Detail columns and change history (schema v13), backup v4, task kinds with the details to ask for each, detail readers, and an "approximate time" marker. |
| Q1 | Asking after a save, and routing the answer to the same task. This fixes threads A1–A3 and the meeting question. |
| Q2 | Later messages that change a stored detail update that task (Crescent), with undo. |
| Q3 | Clash warnings. |
| Q4 | Model contract v3 and retrain. Optional. |
| Q5 | Extras: "before I leave for dinner", the usual shopping list, people and places as memory suggestions, an adaptive question budget, UI. |

**Target conversation after Q0–Q3** (the same messages as section 2):

| # | You | Corenyth (target) | Stored |
|---|---|---|---|
| 1 | I gotta buy veggies | Added task buy veggies. When do you want to go, and anything specific to get? | #1 *buy veggies*; asked: time, items |
| 2 | This evening | Updated buy veggies: this evening (7 PM for now). | #1 due 19:00, `due_part` evening |
| 3 | Yup onions and cabbage | Added onions and cabbage to buy veggies. | #1 items [onions, cabbage] |
| 4 | Also tonight have to go out for dinner soo have to book seats | Added task book seats, tonight (8 PM for now). Where, what time, and how many people? | #2 *book seats*; asked: place, time, count |
| 5 | 4 for the family at Bloomberg | Updated book seats: at Bloomberg, 4 people, with the family. What time should I book it for? | #2 place, party size 4, people; second round because the time is still a guess |
| 6 | 8pm works | Updated book seats: today at 8:00 PM. | #2 due 20:00 exact |
| 7 | Remind me to carry the gift which I bought for my wife | When should I remind you about "carry the gift which I bought for my wife"? | open time question (as today; Q5.1 adds "before you leave for dinner (7:30 PM)?") |
| 8 | Bloomberg doesn't have a table so I have to book table at Crescent | Updated book seats: now at Crescent instead of Bloomberg (today 8:00 PM, 4 people). Say "undo" to change it back. | #2 place Crescent; history row Bloomberg → Crescent |

| # | You | Corenyth (target) |
|---|---|---|
| C1 | tonight at 10 I have to go out with wife | Added task go out with wife, due today at 10:00 PM. Where are you going? |
| C2 | tonight at 11 I have to go out with friends | Added task go out with friends, due today at 11:00 PM. Heads up: go out with wife is at 10:00 PM, so this might overlap with it. |
| C3 | I have a meeting this evening | Okay, I'll remind you this evening (7 PM for now): meeting. What time is it, where, and who's it with? |
| C4 | at 6 with Aditya at the office | Updated meeting: today at 6:00 PM, at the office, with Aditya. |

C2 asks no question, because a clash warning is that turn's follow-up. C3 and C4 ask nothing about the
end time or subject, because follow-up check-ins are off.

---

## 5. Phase Q0: foundations

### Q0.1 Schema v13 (additive)

`dbVersion` 12 → 13 (`db.dart:15`); new `_createTaskDetails(db)` called from `onCreate` and from
`onUpgrade` under `if (oldVersion < 13 && newVersion >= 13)`.

```sql
ALTER TABLE tasks ADD COLUMN place TEXT;          -- "Bloomberg", as said
ALTER TABLE tasks ADD COLUMN people TEXT;         -- "the family", "Aditya", as said
ALTER TABLE tasks ADD COLUMN party_size INTEGER;  -- 1..99, validated in Dart
ALTER TABLE tasks ADD COLUMN items TEXT;          -- JSON array of strings
ALTER TABLE tasks ADD COLUMN due_part TEXT;       -- morning|afternoon|evening|tonight; NULL = exact time
ALTER TABLE tasks ADD COLUMN awaiting_slots TEXT; -- "place,time,count" while awaiting = 'details'
ALTER TABLE tasks ADD COLUMN asked_rounds INTEGER NOT NULL DEFAULT 0;
CREATE TABLE task_history(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  field TEXT NOT NULL,           -- place|people|party_size|items|due_at|due_part|title|ends_at|subject
  old_value TEXT, new_value TEXT,
  actor TEXT NOT NULL,           -- user|rules|model|system (validated in Dart)
  op_id TEXT, chat_id TEXT,
  created_at INTEGER NOT NULL);
CREATE INDEX task_history_task ON task_history(task_id, id);
CREATE INDEX task_history_op ON task_history(op_id);
```

- **No `CHECK` on the new columns.** Older Android SQLite builds handle `CHECK` in `ADD COLUMN` inconsistently, so validation lives in `TaskRepo` and the backup checker.
- **Cascade delete.** Unlike `memory_history`, task history goes away with its task, so a deleted task leaves no details behind.
- **Widget unaffected.** The home-screen widget reads only `tasks(title, status, due_at)` (`db.dart:10-11`).
- **Columns, not a key-value table.** There are four fixed details. The Tasks page, backup, briefing and plan prompt already read task rows, and columns keep them one query away.
- **No new UID column.** `tasks.id` is already unique on the device. Restoring a backup can give an id to a different task. To guard against that, every stored pointer to a task carries its `created_at` as well (open question, pending update, undo record), and a mismatched pointer is ignored. A global UUID only matters once tasks sync between devices (the desktop plan, `docs/development/desktop-support-plan.md` in the `macos-windows-support-plan` worktree), so add `tasks.uid` then.

### Q0.2 Task model and repository

- **`Task` (`repos.dart:59-94`) gains** `place`, `people`, `partySize`, `items` (`List<String>`), `duePart`, `awaitingSlots` (`Set<String>`) and `askedRounds`.
- **`TaskRepo.setDetails(int id, TaskDetailChange c, {required String actor, String? opId, String? chatId})`** runs in one transaction:
  1. Read the row.
  2. Apply only the fields that change.
  3. Write one `task_history` row per changed field.
  4. Send a `due_at` change through the same alert re-planning as `TaskRepo.update` (`repos.dart:230-297`).
  5. Return the before/after values.

  To share that logic, move `update`'s body into `_updateTx(Transaction tx, int id, Map values)` so both methods call it inside one transaction. `_synced()` runs once after commit, as now.
- **`TaskRepo.history(int id)`.**
- **`TaskRepo.undo(String opId)`** reverts each field of that operation whose current value still equals its `new_value`, and reports reverted and skipped fields. It writes its own history rows with `actor 'user'`.
- **`TaskRepo.between(DateTime from, DateTime to)`** returns pending tasks with `due_at` in range, for Q3.
- **`TaskRepo.withDetail(String value)`** returns pending tasks whose `place` or `people` equals the normalized value, for Q2 anchors. It scans pending tasks in Dart, like `byTitle` (`repos.dart:333`).
- **`TaskRepo.create`** takes `duePart`, so the create tools can store it.

### Q0.3 Backup format v4

- `backupFormatVersion` 3 → 4 (`backup_format.dart:19`), with a new line in the version comment.
- **`tasks` table definition** (`backup_format.dart:89-112`) gains the seven columns, all nullable except `asked_rounds`, which defaults to 0. Version 1–3 archives restore with nulls and 0.
- **New `task_history` table entry.**
- **`_checkTask` rejects:**
  - `party_size` outside 1..99;
  - `due_part` outside the four names;
  - `items` that is not a JSON array of at most 20 strings of at most 40 characters each;
  - `awaiting_slots` naming an unknown detail.

### Q0.4 Task kinds and the details worth asking (`lib/assistant/task_kind.dart`, new)

`enum TaskKind { meeting, social, booking, shopping, call, deadline, other }`. `classify(title)` checks in
this order, and the first match wins:

| Kind | Matches (case-insensitive) | Examples |
|---|---|---|
| booking | `book\|reserve` + `table\|seats?\|tickets?\|room\|slot\|appointment` | book seats, reserve a table |
| meeting | `isEventTitle` (`follow_through.dart:27`) | meeting with Aditya, dentist |
| social | dinner, lunch, breakfast, brunch, date (night), party, outing, go(ing) out, hang out, movie, concert, match, wedding, trip, picnic, drinks, meet up with | go out with wife, dinner tonight |
| shopping | buy, get, pick up, order, groceries, shopping (not "get back to", not "get ready") | buy veggies, pick up milk |
| call | call, phone, ring, text, message, email + a person | call mom |
| deadline | submit, finish, send, pay, renew, file, apply | submit report |
| other | everything else; "arrange the meeting" (`isArrangement`) stays other | clean room |

**What each kind asks** (in order; at most 3 per question):

| Kind | Ask | Required | Takes up time (Q3) | Assumed length |
|---|---|---|---|---|
| meeting | time, place, people, end* | time | yes | 60 min |
| social | time, place, people | time | yes | 120 min |
| booking | place, time, count | time | yes, once it has a time | 120 min with meal words, else 60 |
| shopping | time, items† | — | no | — |
| call | time | — | no | — |
| deadline | time (the due day) | — | no | — |
| other | nothing | — | no | — |

\* `end` only when follow-up check-ins are on, because the end time moves the check-in.
† `items` only when the title is generic: veggies, vegetables, groceries, fruit, stuff, things, shopping, supplies, essentials.

- **When a detail counts as given.** A detail counts as given when the title, the message or the stored row already has it. For example, "meeting with Aditya" already names the people and "dinner at Bloomberg" the place. Q0.5's readers run on the title too.
- **Never asked, for any kind:**
  - transport;
  - clothing;
  - budget;
  - reasons;
  - menu or food choice;
  - weather;
  - agenda or subject (still accepted when offered);
  - length (other than `end` above).

  The app asks only for details from this table, and Q1.3 drops model lines that ask about anything else.

### Q0.5 Detail readers (`lib/assistant/task_details.dart`, new)

`TaskDetailReading readDetails(String text, {Set<Slot> asked = const {}, Task? task, required DateTime now})`
returns `time` (a `TemporalReading`), `place`, `people`, `count`, `items`, `declined` and `rejected` (values
inside a negated clause).

| Detail | How it is read |
|---|---|
| filler | A leading yes/yup/yeah/yep/ok/okay/sure/sounds good/perfect/great/cool and a trailing works/is fine/sounds good/would work/please are removed first. |
| time | `Temporal.read` on the rest. A clock-only answer goes on the task's existing day, as `ClarifyDraft.day` does today (`rule_engine.dart:20-24`). A part-of-day answer sets `due_part`. |
| count | 1–2 digits, or one…twelve, followed by people, persons, pax, seats, guests or "of us"; or after "for" / "table for"; or a bare number when only `count` was asked. A number Temporal used (at 4, 4pm, 4:30) is never a count. |
| people | `with (my\|the)? X`, where X is a relation word (wife, husband, partner, family, kids, mom, dad, parents, friends, team, boss, colleagues, client) or capitalized names joined by and or commas. Also "for the family" after a count, or a bare 1–3-word capitalized answer when only `people` was asked. |
| place | `at\|in\|to (the)? X`, where X is not a time phrase (Temporal's phrases are removed first) and not a people word. Up to 4 words, stopping at with, for, and, a comma, or so. Also a bare 1–4-word answer when `place` was asked and nothing else matched. |
| items | Only when `items` was asked, or for "also/plus/and <goods>" to the focused shopping task. Split on commas, "and", "&" and "plus"; articles dropped. |
| declined | The whole message is no, nope, nah, skip, not sure, dunno, no idea, nothing (specific), that's it, that's all, doesn't matter, never mind, or just the usual. |
| rejected | A value inside a negated clause ("Bloomberg doesn't have a table", "not at Bloomberg") is returned as rejected, never as the new value. Q2 uses it as the anchor. |

**Grounding.** Every value returned is a case-insensitive substring of the user's text. A property test checks this on every fixture.

| # | Text | Asked | Reading |
|---|---|---|---|
| D1 | This evening | time, items | time: today, evening part (19:00) |
| D2 | Yup onions and cabbage | items | items [onions, cabbage] |
| D3 | 4 for the family at Bloomberg | place, time, count | count 4, people "the family", place "Bloomberg" |
| D4 | 8pm works | time | 20:00 on the task's day, exact |
| D5 | at 6 with Aditya at the office | time, place, people | 18:00 (6 AM already passed, as Temporal decides today), people "Aditya", place "the office" |
| D6 | Bloomberg | place | place "Bloomberg" |
| D7 | just the usual | items | declined |
| D8 | Bloomberg doesn't have a table so I have to book table at Crescent | — | place "Crescent", rejected "Bloomberg" |
| D9 | table for two at 9 | count, time | count 2, time 21:00 on an evening task's day |
| D10 | at 4 | count, time | time, not a count |
| D11 | 4 | count | count 4 |
| D12 | with my wife | people | people "my wife" |
| D13 | where should we go? | place | nothing (a question) |
| D14 | skip | any | declined |

### Q0.6 Approximate times

- `TemporalReading` (`temporal.dart:29-80`) gains `part`. It is the part-of-day name when that default set the hour and no clock time was given (`temporal.dart:566-575`).
- `_create` and `_adjust` pass it as `due_part` to `create_task` / `create_reminder`, and the executor stores it.
- Any exact time later clears it.
- The confirmation says "tonight (8 PM for now)" instead of the separate "Tonight means 8 PM unless you say otherwise."

---

## 6. Phase Q1: asking, and routing the answer to the same task

### Q1.1 Where the open question lives

| Level | Storage | Purpose |
|---|---|---|
| Task (global) | `awaiting = 'details'`, `awaiting_slots`, `awaiting_at`, `asked_rounds` | Survives a restart and a chat switch, like today's `awaiting`. A **named** answer from any chat ("the veggies are for this evening") binds through these columns plus title or detail words. |
| Chat | PendingRepo key `ask:<chat>` (same table as `pick:` and `batch:`, `repos.dart:2461`) | Lets a **bare** answer ("8pm works") bind to the task this chat just asked about. One pointer per chat; the newest question replaces it. |

The pointer is stored as:

```json
{"kind":"ask","v":1,"task_id":2,"task_created_at":1793440920000,
 "slots":["place","time","count"],"asked_at":"2026-10-31T10:31:00","turns_left":2}
```

The pointer is valid only while all of these hold:
- the task exists, with the same `created_at`;
- the task is not done;
- `turns_left > 0`;
- it is younger than `TargetPick.maxAge` (6 h, `turn_contract.dart:164`).

A `ClarifyDraft` and an `ask:` pointer never coexist. Setting one clears the other.

### Q1.2 When to ask (in `_after`, `session.dart:2396`)

Runs after a committed `create_task` or `create_reminder`, or after a Q1 or Q2 update, for single items only:

1. `kind = classify(title)`. The missing details are the kind's list, minus anything already given (title, message, stored row), minus anything declined.
2. Time counts as missing when `due_at` is null (for kinds that ask for time) or when `due_part` is set, meaning the time is a guess.
3. **Don't ask** when:
   - the follow-up questions setting is Off (Q5.6; until that exists, always "Helpful");
   - the item came through the batch route;
   - this turn showed a clash warning (Q3.5);
   - `asked_rounds ≥ 2`;
   - the task is a daily schedule;
   - the turn only answered a reminder's time question.
4. "Essentials only" keeps only the required details.
5. Take the first 3 missing details in table order and write the question. Set the task columns and the `ask:` pointer, and add 1 to `asked_rounds`.
6. A **second round** happens only when a required detail (time for meeting, social or booking) is still missing or still a guess after the first answer.

### Q1.3 Wording

**Templates** (neutral; the user's tone comes from the model line when it can be used):

| Detail | Alone | Short form for combined questions |
|---|---|---|
| time | events: "What time is it?"; booking: "What time should I book it for?"; others: "When do you want to {title verb}?" | what time |
| place | social: "Where are you going?"; booking: "Which place?"; others: "Where is it?" | where |
| people | "Who's it with?" | who's it with |
| count | "How many people?" | how many people |
| items | "Anything specific to get?" | anything specific to get |
| end | "When does it end? Then I can check in right after." | when it ends |

- **Combining.** Two or three details use the short forms joined with commas and "and", capitalized: "Where, what time, and how many people?"
- **Model line rule.** This replaces the check at `session.dart:2783-2791` for writes that ask. A line from the model is kept only when all of these hold:
  - it passes `safeReply` and `echoes`;
  - it has no digits, day names or clock words;
  - it asks only about the chosen details.

  The line's details are found by keywords:

  | Detail | Keywords |
  |---|---|
  | time | when, what time |
  | place | where, which place, restaurant, venue |
  | people | who, whom |
  | count | how many |
  | items | anything specific, what to get / buy / pick up, which items |
  | end | end, finish |

  The line must cover every required detail that was chosen. Otherwise the template is used instead.
  - A line that asks about anything else ("car or bike?", "why?", "what kind of …?") is **dropped**.
  - A line that only adds warmth ("Nice!", ≤ 6 words, no question) may come before the template question.
- **`isSafeFollowUp`** (`follow_through.dart:539`): "when" and "time" are allowed in a question line only when time is one of the chosen details. Digits, clock words and day words stay blocked.

### Q1.4 Routing answers

- **New `RouteId.openQuestion`** (`turn_contract.dart:28`), placed right after `pendingPick`:
  - in the unified table at `session.dart:1112`;
  - in the legacy chain's `_early` at `session.dart:1481-1499`.

  It runs before the model in both interpreters.
- **Today's `eventDetails` route** (`session.dart:1659-1674`) becomes the named-answer case of this route. The end-time and subject parser (`eventDetails`, `follow_through.dart:107`) is kept, so "it ends at 4:30, about the budget" still works.
- **Add `openQuestion` to `_mechanicalRoutes`** (`session.dart:687`), as `pendingAnswer` already is. An answer like "8pm works" carries no mood worth a model call.

### Q1.5 Answer algorithm

1. Load the pointer. If it is invalid, clear it and route normally.
2. **A command is not an answer.** If `_isCommand(text)` (`session.dart:1598`) or the rules see a create, complete or list, route normally and reduce `turns_left` by 1. This is how "Also tonight … book seats" becomes a new task, and its question replaces the veggies pointer.
3. **Declined** (Q0.5): clear `awaiting`, set `asked_rounds = 2` and reply "No problem." No further asking for this task.
4. `readDetails(text, asked: slots, task: t)`. If no detail is found at all, route normally (for example "where should we go?" goes to chat) and reduce `turns_left` by 1.
5. Otherwise call `update_task_details` with every detail found, including ones not asked: "4 for the family at Bloomberg" also gives the people. Record evidence `target = 'question'` and `time = 'answer: …'`.
6. **Authorization.** An answer carries the original request's authorization, unless the answer itself is negated, hypothetical or a question (the rule documented at `turn_contract.dart:377-379`).
7. After the commit:
   - If a required detail is still missing, ask round 2.
   - If only optional asked details are unanswered, keep the pointer for exactly 1 more turn with those details. This is how "Yup onions and cabbage" still binds after "This evening".
   - Otherwise close the question.

### Q1.6 Executor tool `update_task_details`

- **Built by the app only.** It is not in `toolSchemas` (`tools.dart:32-60`), so the model's grammar and prompts don't change, like `create_daily` and `create_batch`.
- **Arguments:** `id`, and optionally:
  - `place`, `people`, `party_size`;
  - `items_add` (list);
  - `due`, `due_part` (empty string clears it);
  - `ends_at`, `subject`;
  - `title` (Q2.4 only);
  - `close` (bool).
- **Family `change`** (add it to `familyOf`, `turn_contract.dart:124`), so the validator requires write authorization and target evidence.
- **One transaction** through `TaskRepo.setDetails`. A due change moves the task's alerts, as `edit_task` does (`tools.dart:336-365`). The receipt carries `taskIds`, `reminderIds`, `at` and `alarm`.
- **Reply,** built from what changed: "Updated book seats: at Bloomberg, 4 people, with the family." / "Updated buy veggies: this evening (7 PM for now)." / "Added onions and cabbage to buy veggies."
- **Crash recovery.** History rows carry the `op_id`. A journal replay that finds rows for its `op_id` returns `replayed` and writes nothing again.

### Q1.7 The meeting question

- Today's question, "Optional: when does it end, and what is it about?" (`session.dart:2427-2436`), becomes the meeting row of the Q0.4 table: time (if missing or a guess), place, people.
- The end time is asked only when follow-up check-ins are on and those three are known.
- The existing reminder and follow-up planning is unchanged.

### Q1.8 The model path, without retraining

- When the deterministic route doesn't settle a message and an `ask:` pointer is valid, set `_lastTask` to the asked task. The plan prompt then shows `Last task mentioned: #2 book seats (…)` (`session.dart:2675`).
- A model `postpone` or `details` plan whose `ref` is that task is accepted with target evidence `question`, even when its words aren't in the message. This fixes R4 for the model path, and only while the pointer is valid.
- No change to the prompt bytes.

---

## 7. Phase Q2: later changes update the existing task

### Q2.1 Detector (`readUpdate` in `task_details.dart`)

**Target evidence, strongest first:**
- **a. anchor:** a stored `place` or `people` value of exactly one pending task appears in the message (word boundary, case-insensitive). Values under 3 characters, and generic ones (home, office, work, there), need another signal.
- **b. focus:** the task of a valid `ask:` pointer.
- **c. title words:** `named()` (`follow_through.dart:304`) gives one best match of the same kind.
- **d. pronoun:** "it", "that", "the booking", "the dinner", "the meeting" plus `_lastTask`.

**Change:**
- `readDetails` finds a value for a detail that differs from the stored one, or a new time.
- A value in `rejected` must equal the stored one ("Bloomberg doesn't have a table": Bloomberg is the old place).

**Replacement cues:** instead, rather, now, change(d), move(d), switch(ed), actually, no longer, "not … but",
doesn't have, don't have, is full, is closed, cancelled, and "so I have to / we will / I'll".

**Strength**

| Strength | When | Action |
|---|---|---|
| strong | target a or b, a change, and (a cue or the detail already had a value) | apply, with undo |
| add | target a or b, a value for an **empty** detail, no cue | apply (adding to an empty detail loses nothing) |
| weak | target c or d, with a change | confirm first |
| ambiguous | anchor matches 2 or more tasks | ask which (pick) |
| none | — | today's routes (create, …) |

### Q2.2 Placement

- **Unified:** after `openQuestion`, the batch route and `pendingAnswer`, and before `complaint` (`session.dart:1112-1150`).
- **Legacy:** before `_followThrough` (`session.dart:1080`).
- It must run before the model and rules so a create can never duplicate an existing plan.
- It only considers pending tasks due between 12 hours ago and later, or with no time.

### Q2.3 Actions

- **strong / add** → `update_task_details`, then the reply. Example: "Updated book seats: now at Crescent instead of Bloomberg (today 8:00 PM, 4 people). Say "undo" to change it back." It also stores the undo record (Q2.5).
- **weak** → confirm. PendingRepo `update:<chat>` holds `{task_id, task_created_at, change, create_call, asked_at}`. `create_call` is the create today's routes would have run (encoded with `encodeCall`, `turn_contract.dart:215`). The question: "Is this instead of "book seats" at Bloomberg tonight? Say yes to update it, or "new" to add it as a separate task."
  - "yes": apply the change.
  - "new": run `create_call` with title evidence `pending`.
  - Anything else: drop the record and route normally.
  - It is only offered when both plans are the same kind and on the same day. Otherwise the message is a new task, as today.
- **ambiguous** → `TargetPick` with tool `update_task_details` and the change as `args`. It reuses the pick route; extend `_withId` (`session.dart:3695`) for this tool.

### Q2.4 Titles

If the old value appears in the title ("book table at Bloomberg"), that span is replaced with the new value,
keeping the user's casing. Otherwise the title is unchanged ("book seats" stays). No new title words are
ever generated.

### Q2.5 Undo

- **Trigger:** the whole message is "undo", "change it back", "put it back" or "revert that", within 30 minutes of the last `update_task_details` in this chat.
- **Record:** PendingRepo `undo:<chat>` holds `{op_id, task_id, task_created_at, at}`.
- **Action:** new tool `undo_task_change {op_id}` (family `change`) calls `TaskRepo.undo`.
- **Replies:**
  - "Changed back: book seats at Bloomberg."
  - If a field was changed again since: "I can't undo that safely: the place was changed again."
- **Scope:** it also covers Q1 answers.

### Q2.6 Model path, without retraining

- In plan-v2, the `details` intent's pool (`session.dart:3048-3057`) widens from "meetings awaiting details" to "pending tasks". A plan is accepted only when `readUpdate` finds target evidence a–d and a change.
- plan-v1 (legacy) relies on the deterministic Q2 alone.

### Q2.7 Guards

- **Clause-level negation.** The check runs on the clause that carries the new value ("so I have to book table at Crescent"), not on the whole message. This is the same sentence scoping as section 5B (MB.6).
- **Questions never update.** "should I book Crescent instead?" gets a chat reply.
- **Hypotheticals never update.** "maybe Crescent" gets "Want me to switch it to Crescent?" with no stored state. The user confirms with a full sentence ("switch it to Crescent"), which is then a strong update.

---

## 8. Phase Q3: clash warnings

### Q3.1 `lib/assistant/clashes.dart` (new, pure function)

`List<Clash> clashesFor(Task t, List<Task> others)`

- **Window.** `[due_at, ends_at ?? due_at + assumed length of the kind]`. With `due_part` set, the window also covers the part's range: morning 08–12, afternoon 12–17, evening 17–21, tonight 18–24.
- **Counted:** the meeting, social and booking kinds, booking only once it has a time, and any task with `ends_at`.
- **Not counted:**
  - shopping, call, deadline and other kinds;
  - daily schedules;
  - done tasks;
  - tasks with no time;
  - reminders without a task.
- **Candidates:** `TaskRepo.between(start − 12 h, start + 12 h)`, so the list stays small.
- **Clash:** the windows overlap by more than 0 minutes. Back-to-back is not a clash.
- **Certainty:** **firm** when both times are exact and both ends are known (or both start at the same exact time); **soft** otherwise.

### Q3.2 When it runs

- After a committed create, any due change (`edit_task`, postpone, or `update_task_details` with a due), and for each item in the batch preview (section 5B, MB.4).
- Only for the task just written, naming at most 2 others, earliest first.

### Q3.3 Wording (templates; the model does not phrase facts)

| Case | Text |
|---|---|
| soft, the other is exact | Heads up: {other} is at {time}, so this might overlap with it. |
| soft, both are guesses | Heads up: you already have {other} {part}; this might clash with it. |
| firm | Heads up: this overlaps with {other} ({start}–{end}). |

Your two examples:
- **10 PM / 11 PM:** "Added task go out with friends, due today at 11:00 PM. Heads up: go out with wife is at 10:00 PM, so this might overlap with it."
- **Dinner tonight / meeting a friend tonight:** "… Heads up: you already have dinner with wife tonight; this might clash with it."

### Q3.4 Never

- block or delay the save;
- ask a yes/no question about a clash;
- warn about a task that isn't the one being written.

### Q3.5 With Q1

A turn that shows a clash warning asks no follow-up question. Only one extra sentence is added to the
confirmation.

### Q3.6 Briefing (optional)

`briefingText` (`follow_through.dart:373`) marks clashing items with "(overlaps #3)".

---

## 9. Phase Q4: model contract v3 (retrain)

Only after Q1–Q3 work deterministically on the phone. Bundle this retrain with the main plan's 3.3/3.4
retrain, so the model is trained once.

- **New intents** (in `semantic.dart` intents, fields and grammar):
  - `update {ref, when, place, people, count, items, reply}`;
  - `answer {when, place, people, count, items, reply}`, replacing `answer_pending`.

  Values must be copied from the message; the app keeps its grounding checks.
- **Pending line wording:** `Pending: asked about #2 "book seats": place, time, count`.
- **Reply guidance in the system prompt:** "ask only about what the app lists", with examples. The prompt bytes are a training contract: `engine.dart` `planSystem` / `planSystemV2` must stay identical to `training/app_prompts.py`, which `training/test_plan_contract_parity.py` checks.
- **Training rows** (`training/build_dataset.py`):
  - answers and updates for each kind;
  - the three threads from section 2 as multi-turn rows;
  - negatives: no transport, "why" or "what kind" questions;
  - `safe_follow_up` (`build_dataset.py:184`) mirroring the new app rule.
- **Gates:**
  - `answer` / `update` intent accuracy ≥ 90 % on held-out rows;
  - relevance of follow-up questions ≥ 95 %;
  - existing `intent_ok` and `envelope_ok` drop no more than 1 point;
  - device checks (section 12) pass.

---

## 10. Phase Q5: extras (each optional)

| # | Extra | How |
|---|---|---|
| Q5.1 | "before I leave for dinner" / "before the meeting" | Anchor to today's task of that kind by its noun (dinner → social or booking, meeting → meeting). The time is the start minus the first early-alert minute in preferences (default 30). The reminder's time question offers it when such a task exists: "When should I remind you: before you leave for dinner (7:30 PM), or at a set time?" The numbers come from SQLite, so they're allowed. |
| Q5.2 | "the usual" | When items were asked: the items of the last 3 completed shopping tasks with the same title words, shown for confirmation. |
| Q5.3 | Learning about your life | A relationship answer ("with my wife") or a place used in 2 or more tasks becomes a **suggested** memory (v12 suggestion storage, accept/reject in Memories). Never saved automatically. |
| Q5.4 | Adaptive budget | If 3 of the last 5 questions were ignored or declined, switch to "Essentials only" for 7 days, and switch back after 3 answers in a row. Counters live in new `assistant_preferences` columns. |
| Q5.5 | Open details in the evening review and briefing | "book seats: still no time". |
| Q5.6 | UI (through Codex, per the glass UI rule) | Tasks page: a second line on each task ("Bloomberg · 4 people · with the family"), items as a short list, and a History sheet with undo. Settings → Reminders: "Follow-up questions: Helpful / Essentials only / Off", stored in `assistant_preferences.ask_mode` (default `helpful`). |

---

## 11. Tests

New files:
- `test/task_kind_test.dart` (K)
- `test/task_details_test.dart` (D)
- `test/task_question_test.dart` (Q)
- `test/task_update_test.dart` (U)
- `test/clash_test.dart` (C)
- `test/backup_tasks_v4_test.dart` (B)

The migration check goes in `test/p3_p6_architecture_test.dart` (`dbVersion` 13). All session tests run under
both interpreters.

**K1–K7, classify:**
- buy veggies → shopping
- book seats → booking
- meeting with Aditya → meeting
- go out with wife → social
- call mom → call
- submit report → deadline
- arrange the meeting → other

**D1–D14:** the table in Q0.5, plus a property test that every value returned is a substring of the input.

**Q tests**

| # | Script | Expect |
|---|---|---|
| Q1 | Thread A turns 1–3 | 1 task: due today 19:00, `due_part` evening, items [onions, cabbage]. Turn 1 asks time and items. |
| Q2 | Thread A turns 4–6 | *book seats*: place Bloomberg, party size 4, people "the family", due 20:00 exact. Round 2 asks only the time. No new task. |
| Q3 | "I have a meeting this evening" → "at 6 with Aditya at the office", with a scripted model line "Are you driving or taking the bus?" | One question (time, place, people). The model line is dropped. After the answer: 18:00, the office, Aditya, reminder moved, no further question. |
| Q4 | A question, then "what's on tomorrow?", then another unrelated message | The list is shown; the question stays open for 1 turn, then expires and is never asked again. |
| Q5 | A question, then "skip" | Closed, `asked_rounds` 2. |
| Q6 | "remind me to call mom at 5pm"; a batch; setting Off; a clash turn; a daily schedule | No question in any of them. |
| Q7 | Asked in chat a; "the veggies are for this evening" in chat b | Updates #1. |
| Q8 | A question, then a new session (restart), then "8pm works" | Updates the task, as in `proactive_session_test.dart:82-117`. |
| Q9 | Pointer to a deleted task, or to a task restored from a backup under the same id with a different `created_at` | Ignored; routes normally. |
| Q10 | Model off | The question and answer routes work without the model. |

**U tests**

| # | Script | Expect |
|---|---|---|
| U1 | The Crescent message | Place Crescent; one history row (Bloomberg → Crescent); no new task; the reply has the undo hint. |
| U2 | "undo", then "undo" again | Place back to Bloomberg; the second says there is nothing to undo. |
| U3 | "I have to book a table at Crescent" (no Bloomberg) with *book seats* tonight | Confirm question. "yes" → updated; "new" → a separate task. |
| U4 | Two pending tasks at Bloomberg | Pick list; "#2" → updated. |
| U5 | "should I book Crescent instead?" | No change. |
| U6 | Task "book table at Bloomberg" | Title becomes "book table at Crescent". |
| U7 | "the Bloomberg dinner is at 9 now" | Due 21:00; alerts moved. |
| U8 | Journal replay of `update_task_details` | `replayed`; no duplicate history rows. |

**C tests**

| # | Script | Expect |
|---|---|---|
| C1 | 10 PM wife, then 11 PM friends | Soft warning text; both saved. |
| C2 | "dinner with wife tonight", then "meeting my friend tonight" | Soft "you already have … tonight". |
| C3 | Shopping this evening plus dinner at 8 | No warning. |
| C4 | Meeting 3–4 PM (end known), then a meeting at 4 PM | No warning (back-to-back). |
| C5 | Postpone a task into a clash | Warning. |
| C6 | Batch preview with a clashing item | The item is flagged. |
| C7 | A daily task at the same time; a done task | No warning. |

**B1–B3:**
- A v4 round trip keeps the details and history.
- A v3 archive restores with nulls.
- An invalid `party_size` is rejected.

**M1:** migration from v12 to v13 keeps all rows; the widget's three columns are unchanged.

**Existing tests to update:**
- `test/proactive_session_test.dart:82-117` expects "When does it end" for a timed meeting with follow-ups on. The new meeting question asks for the place first and the end time second, so update the expected text.
- Tests asserting the model's follow-up line (`model_line` diagnostics): re-check them against Q1.3.

**Gates:**
- `flutter analyze` with no new warnings (no more infos than today's 113).
- `flutter test` under both interpreters.
- For Q4, the training parity and evaluation tests as well.

---

## 12. Device checks

Phone `462a848c`; install with the profile-build workaround; never uninstall or clear app data.

1. Thread A exactly as in the screenshot:
   - The Tasks page shows two tasks with their details.
   - Diagnostics show `model_calls 0p0r` on the answer turns.
2. The Crescent message, then "undo".
3. The 10 PM / 11 PM pair and the "tonight" / "tonight" pair.
4. The meeting question: ignore it once and confirm it isn't asked again.
5. Kill and reopen the app between a question and its answer.
6. With the setting Off, no questions are asked.

---

## 13. Order, sizes and suggested models

Model tiers, as suggestions only:
- **High reasoning:** Claude Opus at high effort, or Codex at high effort.
- **Standard:** Claude Sonnet or Codex.
- **Long context:** Gemini Pro.
- **Fast:** Claude Haiku or Gemini Flash.

Review each change with a different model than the one that wrote it.

| Row | Work | Size | Needs | Retrain | Suggested |
|---|---|---|---|---|---|
| 1 | Q0.1–Q0.3 schema v13, repository API, backup v4 | M | — | no | Standard (Codex or Sonnet) |
| 2 | Q0.4 task kinds and the details to ask | S | — | no | Standard; fixture lists from Fast |
| 3 | Q0.5 detail readers | M | 2 | no | High reasoning (many edge cases against Temporal) |
| 4 | Q0.6 approximate times (`due_part`) | S | 1 | no | Standard |
| 5 | Q3 clash warnings | M | 1, 2, 4 | no | Standard |
| 6 | Q1 asking and answering | L | 1–4 | no | High reasoning (`session.dart` route order) |
| 7 | Q2 updates and undo | L | 6 | no | High reasoning |
| 8 | Q5.6 UI and setting | M | 1 | no | Codex (glass UI rule) |
| 9 | Q4 contract v3 and retrain | L | 6, 7; main plan 3.3/3.4 | **yes** | High reasoning for the contract; Long context for the dataset builder; you run Colab |
| 10 | Q5.1–Q5.5 | M each | 6 | no | Standard |

**Milestones**
- **QM1** = rows 1–6: the veggies and meeting threads, plus clash warnings.
- **QM2** = rows 7–8: Crescent, undo and the UI.
- **QM3** = row 9: the retrain.
- **QM4** = row 10: the extras.

**Fit with the main plan**
- This work is independent of the open review items (the missed-reminder summary key, bounded retrieval, the doc status, native preemption on the phone).
- Rows 6 and 7 change `session.dart` heavily, so don't run them alongside other `session.dart` work. Splitting `session.dart` first (main plan Phase 6) would help but isn't required.

**Not in this plan**
- The rules not reading statements that start with a time ("tonight at 10 I have to …") when the model is off (section 2). This is a small rules fix in its own right.

---

## 14. Decisions for you

1. **Save first, then ask** (recommended), or hold the task until the questions are answered.
2. **Question budget:** at most 3 details per question, at most 2 rounds, default "Helpful" (recommended). Or change these numbers.
3. **Updates with strong evidence** (an old value named, plus a replacement cue) apply immediately with undo (recommended), or always ask first.
4. **Clash windows:** meetings 1 h; social plans and bookings 2 h; the part-of-day ranges in Q3.1. Two guessed times warn softly (recommended).
5. **Titles:** replace the old value only where it appears in the title (recommended), or never touch titles.
6. **Retrain:** ship Q0–Q3 without retraining first (recommended), then Q4 together with the main plan's 3.3/3.4. Or retrain earlier.
7. **People and places as memory suggestions** (Q5.3): suggest only (recommended), or off.
8. **An answer plus a new command in one message** ("onions, and remind me to call mom at 5"): run the command and keep the question open for one more turn (recommended), or split the message and do both.
