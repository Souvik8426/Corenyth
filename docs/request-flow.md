# Request flow

What happens when the user sends a message (typed today; speech later).

## 1. Session start

One chat = one `AssistantSession` (`conversations.session_id` = `chats.id`). The sidebar (`lib/ui/chat_sidebar.dart`;
drawer on phones, persistent panel at >= 840 px) lists saved chats; selecting, creating or deleting (confirmed) a
chat closes the current session first and gives the new chat a fresh `ChatPage` state, which loads that chat's
messages. Unsent drafts are kept per chat while the app runs.

`AppServices.newSession()` picks the engine:
- a new `LlamaChannelEngine` per session if the active model file (selected or fallback, see model-install.md)
  passes the size check, else `RuleEngine`. Request ids, and so Stop/cancel, belong to that session only; the native model is shared.
- `loadEngine` is `AppServices.ensureModel`, the single load owner (concurrent loads share one native load).

`AssistantSession.start()`: `idle -> initializing`, `ensureModel()`, `engineInUse` = `llama.cpp` or `rules`,
`-> listening`, idle timer (60 s).

## 2. Handling a message: `AssistantSession.handle(text)`

1. Trim; empty is ignored. `lastFallbackReason` and `lastTiming` are reset.
2. `-> processing`. Persist the user turn. Explicit "remember ..." and clear personal facts are saved to memory.
3. **App-only first** (`_early`): a bare id answering this session's "Which one?", arithmetic (`calculator.dart`),
   or a reply that only gives the time (or "cancel") for this chat's open clarification.
4. **Follow-through before planning**: daily schedules, optional meeting details/outcomes, event completion,
   progress updates and briefings are checked against current task data. Ambiguous people/tasks ask which one;
   a full name or task number can answer. Timed errands use configured nudges when enabled; ordinary errand
   follow-through belongs to the evening review unless explicitly requested otherwise. Questions about an end
   time do not change it. Contextual discussion can use the local model's prose-only reply prompt.
5. **Model-first semantic plan** (`_semantic`), whenever the model is installed and loaded:
   - `ensureModel()` again (the model may have been released on memory pressure).
   - One compact `PromptKind.plan` prompt: fixed system text, `Now`, the open clarification (`Pending:`), the
     current pending tasks fresh from SQLite as `#id title` (max 10), related earlier user messages across chats,
     and the message. Old assistant replies (e.g. task lists from earlier builds) are excluded as database facts.
   - Output is constrained by `semanticGrammar` to `{"intent", title?, ref?, when?, range?, multiple?, follow_up?,
     negated?, reply?}` (`semantic.dart`). The model extracts meaning only: no dates, ids or database facts.
   - The app validates (`_act`): titles/refs must come from the message (half of the stemmed words), `when` must be
     words the user said and is resolved by the app's own parser (`RuleEngine.resolveWhen`, incl. "tomo"); an
     unreadable `when` asks and stores a draft; numbers must be typed by the user; ids resolve against pending tasks
     (exact title, or every ref word in a title; several = "Which one?"); negations/questions never write;
     `list` runs `list_tasks` for `today|tomorrow|overdue|all` (`rangeArgs`; tomorrow excludes undated); `chat`
     prose is dropped if it mentions tasks, ids, dates or claims an action. A plan of the wrong kind for a clear
     command (list/chat for "remind me…") falls to the rules.
   - `prompt_too_long` -> a reply asking for a shorter message. `llama_cancelled` -> the turn ends with `''`.
     Other failures, an invalid plan, or a plan the app rejects -> rules, with `lastFallbackReason` set.
6. **Rules fallback** (`_rules`, also the whole path with no model): open clarification, "postpone X by 2h",
   "done with X", missing/unsupported dates, then `RuleEngine.fastRoute`/`plan`.
7. If cancelled before the action, nothing runs and `handle` returns `''` (the UI drops the streamed draft).
8. `ToolExecutor.execute(call)` against SQLite; a `ToolError` becomes the reply. After a new meeting, ask for optional
   end/subject. After event completion, cancel its scheduled follow-up and discuss the outcome immediately if enabled.
   Persist the reply, `-> speaking -> listening`.
9. `lastTiming` (`route`, `context`, `execution`, `total` ms) and `lastDiagnostics` (`model`:
   called/invalid/failed/unavailable, `intent`, `tool`, `db`: ok/error/none) hold no message text and are printed
   with `debugPrint` for local debugging only.

New missing-time clarifications use the reserved `main` row in `pending_clarifications` (v5), so another display chat
can answer them. Legacy per-chat rows are still readable in their original chat. They stay open through detours and
restarts, and close when answered, cancelled, or replaced (disclosed). Optional meeting details/outcomes are stored
on the task itself. Follow-up conversation uses current task state and the user's words, not old assistant lists.

## 3. Ending a session: `close()`

Cancels an in-flight turn, `-> shuttingDown -> idle`. The shared model stays loaded. Runs on idle timeout, chat
switch/delete, the voice activity's close button and dispose.

## 4. Model load and release

`ModelSetupCard` checks the file on start and on resume and loads the model when ready (popup shows progress).
`AppServices.releaseModel()` (called on `didHaveMemoryPressure`) sets the status to idle before unloading and is
serialized with loads, so the next inference reloads safely.

## 5. Reminders at startup

`AppServices.open()` runs `rescheduleAll`: re-arms enabled upcoming reminders, retries pending cancels, clears
succeeded intents. Failures appear as `schedulingIssue` above the chat.

Startup and resume also reconcile recent missed occurrences silently, advance daily schedules, and arm the evening review. Native alarm jobs use the `proactiveMain` entrypoint in the dedicated `:proactive` Android process, with a separate SQLite worker pool and WAL. They re-read current state, save a unique main-chat message, then notify and refresh an open UI through a private receiver. Preparation and outcome checks never reuse completed task schedules. Reviews group unfinished work, relevant events and tomorrow into one message; ignored tasks retain their dates and return in later reviews. Background jobs do not load Qwen.

## Diagram

```
user text
  → handle()
     → save user turn
     → pick / arithmetic / pending time answer ── yes ──> execute
     → llm.complete(plan prompt + semanticGrammar) ──fail──┐
     → parseSemantic → app validation (_act)   ──reject──┤
                                                          ▼
                                  rules (_rules / fastRoute / plan)
     → ToolExecutor.execute  (DB / alarms / widget)
     → save reply → speak (TBD) → listening
```
