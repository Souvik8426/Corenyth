# Request flow

What happens when the user sends a message (typed today; speech later).

## 1. Session start

One chat = one `AssistantSession` (`conversations.session_id` = `chats.id`). The sidebar (`lib/ui/chat_sidebar.dart`;
drawer on phones, persistent panel at >= 840 px) lists saved chats; selecting, creating or deleting (confirmed) a
chat closes the current session first and gives the new chat a fresh `ChatPage` state, which loads that chat's
messages. Unsent drafts are kept per chat while the app runs.

`AppServices.newSession()` picks the engine:
- a new `LlamaChannelEngine` per session if `Documents/localmodels/Qwen3-0.6B-Q4_0.gguf` passes `checkModel`, else
  `RuleEngine`. Request ids, and so Stop/cancel, belong to that session only; the native model is shared.
- `loadEngine` is `AppServices.ensureModel`, the single load owner (concurrent loads share one native load).

`AssistantSession.start()`: `idle -> initializing`, `ensureModel()`, `engineInUse` = `llama.cpp` or `rules`,
`-> listening`, idle timer (60 s).

## 2. Handling a message: `AssistantSession.handle(text)`

1. Trim; empty is ignored. `lastFallbackReason` and `lastTiming` are reset.
2. `-> processing`. Persist the user turn. Explicit "remember ..." and clear personal facts are saved to memory.
3. **Fast route** (`RuleEngine.fastRoute`): greetings, task lists, and anchored add/complete/delete/remind/cancel
   commands run without the model. Titles keep their casing. Negations, `or`, `;`/`?` and chained commands are not
   fast-routed.
4. **Plan** (`_plan`), when the model is in use:
   - `ensureModel()` again (the model may have been released on memory pressure; it reloads here).
   - Context router (`_prompt`): memories, tasks only when the text needs them, last turns of this chat.
   - `completeStreaming`; visible `respond` text streams to the UI.
   - `PlatformException` `prompt_too_long` -> a reply asking for a shorter message (no fallback).
     `llama_cancelled` -> the turn ends with `''`, no action, no reply.
     Any other failure or invalid output -> rules, with `lastFallbackReason` set (shown under the chat).
5. If cancelled before the action, nothing runs and `handle` returns `''` (the UI drops the streamed draft).
6. `ToolExecutor.execute(call)`; a `ToolError` becomes the reply. Persist the reply, `-> speaking -> listening`.
7. `lastTiming` holds `route`, `context`, `execution`, `total` milliseconds (no text) and is printed with `debugPrint`.

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
     → router: memories, [tasks], history
     → fastRoute? ── yes ──> execute
     → llm.complete(prompt + grammar) ──fail──┐
     → parseToolCall (validate)     ──fail──┤
                                              ▼
                                  rules.complete → parseToolCall
     → ToolExecutor.execute  (DB / alarms / widget)
     → save reply → speak (TBD) → listening
```
