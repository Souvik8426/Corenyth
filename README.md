# Offline Assistant

An Android-first Flutter assistant that runs **entirely on the phone**: tasks, reminders, conversation
sessions and long-term memory, driven by a local LLM ([Qwen3-0.6B](https://huggingface.co/unsloth/Qwen3-0.6B-GGUF)
via [llama.cpp](https://github.com/ggml-org/llama.cpp)). The app declares **no INTERNET permission**.

> Status: early prototype. Text chat, tasks, reminders, memory, the home-screen widget and on-device LLM
> inference work. Voice (ASR/TTS) is not integrated yet.

## Features
- **Local LLM**: llama.cpp built from source via the NDK and called over JNI. Output is grammar-constrained, so the
  model can only emit a valid tool call.
- **Safe tool layer**: every model action is validated against a strict schema before anything touches the database.
  Invalid output is never executed.
- **Rule-engine fallback**: a deterministic planner handles requests when no model is installed or the model output
  is unusable.
- **Tasks and reminders**: SQLite storage. Reminders are scheduled with AlarmManager and fire even when the app is closed.
- **Chat history**: saved chats in a sidebar (drawer on phones), streamed replies with Stop.
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
The app has no network access, so you download the model yourself. On first launch the app creates
`Documents/localmodels` and shows a step-by-step guide on the Chat tab:

1. **Grant file access.** On Android 11+ this is *All files access* in Settings; on Android 6–10 it is the storage
   permission.
2. **Download** `Qwen3-0.6B-Q4_0.gguf` (about 365 MB) in your browser. The guide's button opens this link:
   `https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/626eb58354de1127ccd7a9dc213485a3b716534c/Qwen3-0.6B-Q4_0.gguf`
3. **Move** the file from Downloads to `Documents/localmodels` with the Files app. Keep the exact file name.
4. **Return to the app.** It loads the model straight away and shows a progress popup, then a success message.

From a PC instead (open the app once first so the folder exists):
```sh
adb push Qwen3-0.6B-Q4_0.gguf /sdcard/Documents/localmodels/
```
The app checks the exact size (382,156,160 bytes). The expected SHA-256 is
`24ccc1cc08429fadd236268f920e965a376603479ca70f499be8930169c2159b`.

## Project layout
| Path | Purpose |
|---|---|
| `lib/assistant/engine.dart` | `LlmEngine` interface, Qwen ChatML prompt (KV-cache friendly layout), `LlamaChannelEngine` |
| `lib/assistant/tools.dart` | Tool schemas, the generated GBNF grammar, JSON extraction and validation, `ToolExecutor` (the only code that mutates state) |
| `lib/assistant/session.dart` | Session state machine, fast route, context router, cancel, fallback reason, timing |
| `lib/assistant/rule_engine.dart` | Deterministic fallback planner (emits the same JSON as the LLM) |
| `lib/data/` | SQLite schema v3 (tasks, reminders with pending-sync intent, chats, conversations, profile, memories + FTS4) and repositories |
| `lib/ui/` | App shell, chat view, chat history sidebar, Tasks and Memories pages, model status |
| `lib/services/` | Composition root, model status and install checks, reminder scheduler, native bridge |
| `android/app/src/main/cpp/` | CMake build of llama.cpp and the JNI bridge (`llama_jni.cpp`) |
| `android/.../LlamaBridge.kt` | `assistant/llm` channel: `load`, `generate`, `cancel`, `unload` on a worker thread |
| `android/.../MainActivity.kt` | Model folder, storage permission, browser hand-off |
| `android/.../WidgetProvider.kt` | Home-screen widget (reads the same SQLite file, no Flutter or model needed) |

## How a request flows
1. The user's text goes to `AssistantSession.handle`. A router adds only the relevant memories and tasks to the prompt.
2. `LlamaChannelEngine` sends the prompt together with a GBNF grammar to llama.cpp. Decoding is greedy and constrained
   by the grammar, so the result is always one JSON object such as
   `{"type":"tool","tool":"create_task","arguments":{...}}` or `{"type":"respond","text":"..."}`.
3. `parseToolCall` validates it. `ToolExecutor` runs it. If anything fails, the rule engine answers instead.

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
- Speech: sherpa-onnx VAD + streaming ASR into `AssistantSession.handle`, TTS through the `speak` callback,
  runtime microphone permission
- Wiring `cancel` to voice barge-in (typed chat already streams and has Stop)
- Faster CPU kernels (`GGML_CPU_ARM_ARCH=armv8.2-a+dotprod` or `GGML_CPU_ALL_VARIANTS`); the default build targets
  baseline armv8-a so it runs on every arm64 phone
- On-device validation of streaming, cancel, KV reuse and memory-pressure release
- In-app SHA-256 verification of the model file

## Design notes
- SQLite is owned by Flutter (`sqflite`). The widget reads the same file, so the schema in `lib/data/db.dart` is
  the contract with `WidgetProvider.kt`.
- Memory uses FTS4 (FTS5 is missing on older Android builds), re-ranked by importance and recency. The memory store
  never holds task or reminder data; those questions are answered from the database.
- The package name must stay `com.corenyth.assistant` because the JNI symbols and Kotlin sources depend on it.

## Acknowledgements
- [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT)
- [Qwen3](https://huggingface.co/Qwen) by the Qwen team; GGUF conversion by [Unsloth](https://huggingface.co/unsloth)
