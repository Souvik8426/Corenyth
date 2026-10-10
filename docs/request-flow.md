# Request flow

What happens when the user sends a message (typed today; speech later).

## 1. Session start

`AppServices.newSession()` picks the engine:
- `LlamaChannelEngine` if `Documents/localmodels/Qwen3-0.6B-Q4_0.gguf` passes `checkModel` (exact size), else `RuleEngine`.

`AssistantSession.start()`:
1. State `idle → initializing`.
2. `engine.load()`. On success `engineInUse = "llama.cpp"`, otherwise `"rules"`.
3. State `→ listening`, idle timer armed (60 s).

## 2. Handling a message: `AssistantSession.handle(text)`

1. Trim. Empty input is ignored. The idle timer is cancelled.
2. State `→ processing`.
3. Persist the user turn to `conversations`.
4. **Plan** (`_plan`):
   - Build a `Prompt` through the **context router** (`_prompt`):
     - Memories: `MemoryRepo.search(text)`, always.
     - Tasks: only if the text matches `task|tasks|todo|to-do|today|tomorrow|due|task #N`. Up to 10 are included.
     - History: last 9 turns, minus the current turn.
   - If the LLM is in use, call `engine.complete(prompt)` and then `parseToolCall`.
   - On any failure (malformed or invalid JSON, native error), fall back to `RuleEngine.complete` and `parseToolCall`.
5. If the tool is not `respond`, state `→ executing`.
6. `ToolExecutor.execute(call)` returns a reply string. A `ToolError` becomes the reply text.
7. Persist the assistant reply. State `→ speaking`. Call `speak` (not wired yet).
8. In `finally`, unless shutting down: state `→ listening` and re-arm the idle timer.

## 3. Ending a session: `close()`

1. State `→ shuttingDown`.
2. For up to 10 of the user's last 30 turns, `_extract` asks the engine (or rules) whether a durable fact or
   preference is worth remembering. Accepted facts go into `memories` (max 300 chars).
3. `engine.unload()`. State `→ idle`.

`close()` runs on idle timeout (60 s with no input), on the close button of the voice activity, and on dispose.

## 4. Model load after launch

`ModelSetupCard` checks the file on start and each time the app resumes. If the model is ready, `AppServices.loadModel()`
loads it and the popup shows progress. When loading finishes, an open chat on the rule engine restarts onto the model.
See [model-install.md](model-install.md).

## Diagram

```
user text
  → handle()
     → save user turn
     → router: memories, [tasks], history
     → llm.complete(prompt + grammar) ──fail──┐
     → parseToolCall (validate)     ──fail──┤
                                              ▼
                                  rules.complete → parseToolCall
     → ToolExecutor.execute  (DB / alarms / widget)
     → save reply → speak (TBD) → listening
```
