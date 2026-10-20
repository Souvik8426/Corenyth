# Architecture

Corenyth is an Android-first Flutter app. Everything runs on the phone. The release APK declares no INTERNET permission; debug/profile overlays retain Flutter development networking.

## Layers

```
 Flutter UI (lib/main.dart)
        │  text (speech later)
        ▼
 AssistantSession (lib/assistant/session.dart)   ← state machine, semantic planner
        │                    │
        ▼                    ▼
 LlmEngine                 RuleEngine (fallback)   lib/assistant/rule_engine.dart
 (lib/assistant/engine.dart)  semantic plan / deterministic rules
        │
        ▼ MethodChannel "assistant/llm"
 LlamaBridge.kt → JNI → llama_jni.cpp → llama.cpp (libllama_jni.so)

 parseSemantic / session validation   ← intent and user-word checks
        │
        ▼
 ToolExecutor (lib/assistant/tools.dart)   ← validated actions mutate state
        │
        ▼
 Repos (lib/data/repos.dart) → SQLite (lib/data/db.dart, file "assistant.db")
 ReminderScheduler → Android AlarmManager (flutter_local_notifications)
```

## Key rule: the model interprets, code acts

The model proposes intent and extracts words from the request. Application code validates the plan, resolves dates
and database references, then builds and executes a tool call. Invalid output is never executed. See
[tools-and-validation.md](tools-and-validation.md) and [llm-engine.md](llm-engine.md).

Follow-through adds validated app-side interpretation in `follow_through.dart`: meeting detail/outcome replies,
progress updates, daily schedules and briefings. The session persists optional details and outcomes through the
repositories; ordinary task actions still use `ToolExecutor`. The plan itself carries a toned `reply`: the chat
answer, or a follow-up line appended after the app's exact confirmation. A separate `PromptKind.reply` is used only
for outcome/hypothetical wording or when the plan's reply is unusable. Neither can return an executable action;
invalid/action-claiming prose uses a deterministic fallback. Actual host Qwen evaluation now exists but fails held-out acceptance; phone behavior still requires the checklist.

Display chats share relevant user context and one new missing-time question. Task-bound event questions survive
chat switches and restart. Old assistant task lists are not treated as current database facts.

## Components

| Component | Location | Role |
|---|---|---|
| Composition root | `lib/services/app_services.dart` | Opens the DB, repos, scheduler; startup reminder reconciliation. A per-session engine (model or rules). Single owner of native model load/release. |
| UI | `lib/main.dart`, `lib/ui/` | Chat with history sidebar (`chat_sidebar.dart`), Tasks, Memories tabs, profile, model settings and load popup. Voice route `/voice`. |
| Session | `lib/assistant/session.dart` | One chat. Semantic planning, validation, rules fallback, cancel, clarification persistence, diagnostics. Memory is saved per turn. |
| Engine interface | `lib/assistant/engine.dart` | `LlmEngine`, `Prompt` (ChatML), `LlamaChannelEngine` |
| Rule engine | `lib/assistant/rule_engine.dart` | Regex planner that returns the same JSON shape |
| Tools | `lib/assistant/tools.dart` | Schemas, GBNF grammar, JSON extraction, validation, `ToolExecutor` |
| Data | `lib/data/db.dart`, `repos.dart` | SQLite schema, repositories |
| Model status / selection | `lib/services/model_status.dart`, `model_selection.dart` | The single allowlisted fine-tuned model, size check, SHA-256 verify (cached), persisted id, rules fallback |
| Native bridge | `lib/services/native_bridge.dart` | Dart side of `assistant/native` (folder, storage, browser, widget refresh) |
| Reminders | `lib/services/reminder_scheduler.dart` | Schedules and cancels exact alarms; checks runtime notification/exact-alarm state |
| Reminder plans | `lib/data/repos.dart` (`reminderPlan`, `AlertIntent`, `TaskRepo.update`) | Stored per-task plan request, regenerated on due change; durable schedule/cancel intents |
| Android | `android/app/src/main/kotlin/.../` | `MainActivity`, `LlamaBridge`, `WidgetProvider`, `CompactWidgetProvider`, `WidgetTaskService`, `WidgetAddActivity`, `VoiceSessionActivity` |
| Native LLM | `android/app/src/main/cpp/` | CMake build of llama.cpp and `llama_jni.cpp` |

## Two channels to native

- `assistant/native` (`MainActivity.kt`): model folder, storage access, opening the download page, widget refresh.
- `assistant/llm` (`LlamaBridge.kt`): `load`, `generate`, `cancel`, `unload`.

## Where to read next

- [request-flow.md](request-flow.md): how one message moves through these parts.
- [llm-engine.md](llm-engine.md): the native side in detail.


## Reliability contracts and rollout

Both interpreters produce a `CandidatePlan`, use the common validator and execute through typed receipts. `authorization.dart` owns request authorization; `temporal.dart` owns time resolution. The v7 operation journal and row stamps support retry/restart recovery. SQLite v8 tracks memory provenance and supersession. Relevant tasks are selected before caps, and active memories reach both planning and prose prompts.

Legacy remains the default. `CORENYTH_INTERPRETER=unified` opts into the coordinator and plan-v2 contract for comparison; passing its unit suite is not rollout approval. The model banner distinguishes resident model from last-answer source. The loader uses a constant rotating arc and honors reduced motion.

See [reliability status](../development/reliability-status.md) for measured results and remaining gates.
