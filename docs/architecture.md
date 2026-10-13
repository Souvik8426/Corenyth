# Architecture

Corenyth is an Android-first Flutter app. Everything runs on the phone. The app declares no INTERNET permission.

## Layers

```
 Flutter UI (lib/main.dart)
        │  text (speech later)
        ▼
 AssistantSession (lib/assistant/session.dart)   ← state machine, context router
        │                    │
        ▼                    ▼
 LlmEngine                 RuleEngine (fallback)   lib/assistant/rule_engine.dart
 (lib/assistant/engine.dart)  same JSON out
        │
        ▼ MethodChannel "assistant/llm"
 LlamaBridge.kt → JNI → llama_jni.cpp → llama.cpp (libllama_jni.so)

 parseToolCall / _validate (lib/assistant/tools.dart)   ← the only gate
        │
        ▼
 ToolExecutor (lib/assistant/tools.dart)   ← the only code that mutates state
        │
        ▼
 Repos (lib/data/repos.dart) → SQLite (lib/data/db.dart, file "assistant.db")
 ReminderScheduler → Android AlarmManager (flutter_local_notifications)
```

## Key rule: the model interprets, code acts

The model (or the rule engine) only proposes a JSON tool call. Application code validates it against a strict schema
and executes it. Invalid output is never executed. See [tools-and-validation.md](tools-and-validation.md).

## Components

| Component | Location | Role |
|---|---|---|
| Composition root | `lib/services/app_services.dart` | Opens the DB, repos, scheduler; startup reminder reconciliation. A per-session engine (model or rules). Single owner of native model load/release. |
| UI | `lib/main.dart`, `lib/ui/` | Chat with history sidebar (`chat_sidebar.dart`), Tasks, Memories tabs, profile, model settings and load popup. Voice route `/voice`. |
| Session | `lib/assistant/session.dart` | One chat. States, fast route, context routing, cancel, fallback reason, turn timing. Memory is saved per turn. |
| Engine interface | `lib/assistant/engine.dart` | `LlmEngine`, `Prompt` (ChatML), `LlamaChannelEngine` |
| Rule engine | `lib/assistant/rule_engine.dart` | Regex planner that returns the same JSON shape |
| Tools | `lib/assistant/tools.dart` | Schemas, GBNF grammar, JSON extraction, validation, `ToolExecutor` |
| Data | `lib/data/db.dart`, `repos.dart` | SQLite schema, repositories |
| Model status | `lib/services/model_status.dart` | Download URL, expected size, `checkModel` |
| Native bridge | `lib/services/native_bridge.dart` | Dart side of `assistant/native` (folder, storage, browser, widget refresh) |
| Reminders | `lib/services/reminder_scheduler.dart` | Schedules and cancels exact alarms |
| Android | `android/app/src/main/kotlin/.../` | `MainActivity`, `LlamaBridge`, `WidgetProvider`, `VoiceSessionActivity` |
| Native LLM | `android/app/src/main/cpp/` | CMake build of llama.cpp and `llama_jni.cpp` |

## Two channels to native

- `assistant/native` (`MainActivity.kt`): model folder, storage access, opening the download page, widget refresh.
- `assistant/llm` (`LlamaBridge.kt`): `load`, `generate`, `cancel`, `unload`.

## Where to read next

- [request-flow.md](request-flow.md): how one message moves through these parts.
- [llm-engine.md](llm-engine.md): the native side in detail.
