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
4. **Model-first semantic plan** (`_semantic`), whenever the model is installed and loaded:
   - `ensureModel()` again (the model may have been released on memory pressure).
   - One compact `PromptKind.plan` prompt: fixed system text, `Now`, the open clarification (`Pending:`), the
     current pending tasks fresh from SQLite as `#id title` (max 10), and the message. **No chat history**: old
     assistant replies (e.g. task lists from earlier builds) can never be copied back as facts.
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
5. **Rules fallback** (`_rules`, also the whole path with no model): open clarification, "postpone X by 2h",
   "done with X", missing/unsupported dates, then `RuleEngine.fastRoute`/`plan`.
6. If cancelled before the action, nothing runs and `handle` returns `''` (the UI drops the streamed draft).
7. `ToolExecutor.execute(call)` against SQLite; a `ToolError` becomes the reply. Persist the reply, `-> speaking -> listening`.
8. `lastTiming` (`route`, `context`, `execution`, `total` ms) and `lastDiagnostics` (`model`:
   called/invalid/failed/unavailable, `intent`, `tool`, `db`: ok/error/none) hold no message text and are printed
   with `debugPrint` for local debugging only.

Open clarifications are one JSON row per chat in `pending_clarifications` (v5), not re-read from assistant text. They
stay open through unrelated requests and restarts, and close only when answered, cancelled, or replaced by another
item that also needs a time (disclosed).

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
