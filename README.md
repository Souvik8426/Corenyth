# Offline Assistant

An Android-first Flutter assistant that runs **entirely on the phone**: tasks, reminders, conversation
sessions and long-term memory, driven by a local LLM (default
[Qwen3-0.6B](https://huggingface.co/unsloth/Qwen3-0.6B-GGUF), optional
[Qwen3-1.7B](https://huggingface.co/unsloth/Qwen3-1.7B-GGUF) Q4_0 GGUF)
via [llama.cpp](https://github.com/ggml-org/llama.cpp)). The app declares **no INTERNET permission**.

> Status: early prototype. Text chat, tasks, reminders, memory, the home-screen widget and on-device LLM
> inference work. Voice (ASR/TTS) is not integrated yet.

## Features
- **Local LLM**: llama.cpp built from source via the NDK and called over JNI. Output is grammar-constrained to a
  semantic plan; the app validates it and computes dates and database actions itself.
- **Safe action layer**: model plans are checked against the user's words and current database state before anything
  changes. Invalid or unsupported plans fall back to the deterministic rules.
- **Rule-engine fallback**: a deterministic planner handles requests when no model is installed or the model output
  is unusable.
- **Tasks and reminders**: SQLite storage. Reminders are scheduled with AlarmManager and fire even when the app is closed.
- **Chat history**: saved chats in a sidebar (drawer on phones), streamed replies with Stop.
- **Follow-through**: shared task context across chats, optional preparation nudges, meeting outcome conversations, daily schedules and one evening review before DND. Proactive messages are saved in the main chat with notification actions. Background messages use factual templates; local Qwen handles interactive context and wording.
- **Memory**: explicit "remember ..." and clear personal facts are saved per turn, searched with SQLite FTS4.
- **Home-screen widget**: shows pending tasks and opens a translucent assistant window.

## Requirements
- Flutter (Dart SDK 3.3+)
- Android SDK with `compileSdk` 34+, the NDK (`flutter.ndkVersion`) and CMake 3.22.1 (install from the SDK Manager)
- A 64-bit Android device (arm64-v8a) or an x86_64 emulator. On 32-bit devices the app falls back to the rule engine.

## Build
```sh
# 1. llama.cpp sources (not committed; pinned tag)
git clone --depth 1 --branch b11541 https://github.com/ggml-org/llama.cpp android/app/src/main/cpp/llama.cpp

# 2. Dart dependencies, checks, build
flutter pub get
flutter analyze
flutter test
flutter build apk --debug      # or: flutter run
```
The native code is always compiled as Release (`-O3`) even in debug APKs. An unoptimized llama.cpp is about 50x
slower.

## Installing the model
The app has no network access, so you download an allowlisted model yourself. On first launch the app creates
`Documents/localmodels` and shows a step-by-step guide on the Chat tab. **Default is Qwen3-0.6B**; optional
**Qwen3-1.7B** may be installed and selected in the setup UI. Only catalog filenames are accepted (ChatML Qwen3);
RAM/latency are not measured on-device in this build — see [docs/model-install.md](docs/model-install.md).

1. **Grant file access.** On Android 11+ this is *All files access* in Settings; on Android 6–10 it is the storage
   permission.
2. **Download** one of the pinned files (keep the exact name):
   - Default `Qwen3-0.6B-Q4_0.gguf` (382,156,160 bytes ≈ 365 MiB):
     `https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/626eb58354de1127ccd7a9dc213485a3b716534c/Qwen3-0.6B-Q4_0.gguf`
     SHA-256 `24ccc1cc08429fadd236268f920e965a376603479ca70f499be8930169c2159b`
   - Optional `Qwen3-1.7B-Q4_0.gguf` (1,056,782,912 bytes ≈ 1008 MiB):
     `https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/d7f544eead698dbd1f15126ef60b45a1e1933222/Qwen3-1.7B-Q4_0.gguf`
     SHA-256 `c876f159707a4e4f70e045106c69db15bfc935a4981706fd4f65c6e7ea1e81c5`
3. **Move** the file from Downloads to `Documents/localmodels` with the Files app.
4. **Return to the app.** It checks the file's SHA-256 (first load only; can take a while for 1.7B), then loads
   the selected model. If that fails it switches the selection back to 0.6B, or uses built-in rules, and says so.

From a PC instead (open the app once first so the folder exists):
```sh
adb push Qwen3-0.6B-Q4_0.gguf /sdcard/Documents/localmodels/
# optional:
adb push Qwen3-1.7B-Q4_0.gguf /sdcard/Documents/localmodels/
```
The app checks the exact size, then the pinned SHA-256 (streamed in a background isolate, cached by file size and
modified time) before the native load. The selection is stored privately under the app DB path.

## Project layout
| Path | Purpose |
|---|---|
| `lib/assistant/engine.dart` | `LlmEngine` interface, Qwen ChatML prompt (KV-cache friendly layout), `LlamaChannelEngine` |
| `lib/assistant/tools.dart` | Tool schemas, the generated GBNF grammar, JSON extraction and validation, `ToolExecutor` for validated task actions |
| `lib/assistant/session.dart` | Session state machine, semantic planning, clarification handling, rules fallback, diagnostics |
| `lib/assistant/rule_engine.dart` | Deterministic fallback planner (emits the same JSON as the LLM) |
| `lib/data/` | SQLite schema v6 (tasks, reminder plans, event details, daily schedules, chats, global context, proactive records, profile, memories + FTS4) and repositories |
| `lib/ui/` | App shell, chat view, chat history sidebar, Tasks and Memories pages, model status |
| `lib/services/` | Composition root, model catalog/selection, install checks, reminder scheduler, native bridge |
| `android/app/src/main/cpp/` | CMake build of llama.cpp and the JNI bridge (`llama_jni.cpp`) |
| `android/.../LlamaBridge.kt` | `assistant/llm` channel: `load`, `generate`, `cancel`, `unload` on a worker thread |
| `android/.../MainActivity.kt` | Model folder, storage permission, browser hand-off |
| `android/.../WidgetProvider.kt` | Home-screen widget (reads the same SQLite file, no Flutter or model needed) |

## How a request flows
1. `AssistantSession.handle` handles app-only requests such as arithmetic and pending clarification answers first.
2. Otherwise, `LlamaChannelEngine` asks llama.cpp for a grammar-constrained semantic plan, such as a task intent and
   title. It does not choose database ids or resolve dates.
3. The app validates the plan against the user's words, resolves dates and task references, then runs the SQLite
   action. Invalid plans use the rules fallback.

Before the model, the app answers on its own: arithmetic (`calculator.dart`, never a task), an open "what time?"
question, "which one?" picks, postpone/done phrases, catch-up and reminder lists, and anchored commands. Dates,
storage, scheduling and arithmetic are always computed by the app, not the model.

## Permissions
| Permission | Why |
|---|---|
| `MANAGE_EXTERNAL_STORAGE` (Android 11+), `WRITE_EXTERNAL_STORAGE` (≤ Android 10) | Read the model from `Documents/localmodels`. A file placed there by another app is invisible to a scoped-storage app. |
| `POST_NOTIFICATIONS`, `SCHEDULE_EXACT_ALARM`, `RECEIVE_BOOT_COMPLETED` | Reminders |
| `RECORD_AUDIO` | Reserved for the upcoming speech input (not requested at runtime yet) |

`MANAGE_EXTERNAL_STORAGE` is fine for side-loading. Google Play only allows it with an approved declaration.
Debug builds get INTERNET through Flutter's generated debug manifest (needed for hot reload); the release manifest has
none.

## Debugging
```sh
adb logcat -s LlamaBridge llama.cpp   # model load time, prompt/generation timing, llama.cpp warnings
```
An earlier build was measured once on a Snapdragon 7+ Gen 2 phone (model load under 1 s, ~200-token prompt in about
2.8 s, about 26 tokens/s). The current build (KV prefix reuse, streaming) has not been re-measured; see
[docs/performance-validation.md](docs/performance-validation.md).

## Roadmap

See the [expectation report](docs/expectation-gap-report.md), [implementation result](docs/follow-through-implementation.md) and [six-step execution plan](corenyth-follow-through-plan.md) for this follow-through update.

- Speech: sherpa-onnx VAD + streaming ASR into `AssistantSession.handle`, TTS through the `speak` callback,
  runtime microphone permission
- Wiring `cancel` to voice barge-in (typed chat already streams and has Stop)
- Faster CPU kernels (`GGML_CPU_ARM_ARCH=armv8.2-a+dotprod` or `GGML_CPU_ALL_VARIANTS`); the default build targets
  baseline armv8-a so it runs on every arm64 phone
- On-device validation of streaming, cancel, KV reuse and memory-pressure release
- On-device measurement of 1.7B RAM/latency before promoting it as default

## Design notes
- SQLite is owned by Flutter (`sqflite`). The widget reads the same file, so the schema in `lib/data/db.dart` is
  the contract with `WidgetProvider.kt`.
- Memory uses FTS4 (FTS5 is missing on older Android builds), re-ranked by importance and recency. The memory store
  never holds task or reminder data; those questions are answered from the database.
- The package name must stay `com.corenyth.assistant` because the JNI symbols and Kotlin sources depend on it.

## Acknowledgements
- [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT)
- [Qwen3](https://huggingface.co/Qwen) by the Qwen team; GGUF conversion by [Unsloth](https://huggingface.co/unsloth)
