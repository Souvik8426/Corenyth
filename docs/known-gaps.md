# Known gaps

## Not built yet

- **Speech input and output.** sherpa-onnx VAD and streaming ASR into `AssistantSession.handle`. The `speak` callback
  exists in the session, but nothing calls TTS. `RECORD_AUDIO` is declared but never requested.
- **Barge-in.** `LlamaBridge` has `cancel`, but Dart never calls it.
- **Token streaming.** `generate` returns the full reply only.
- **Edit by title.** Tools only accept numeric task and reminder ids. The prompt lists tasks with ids, so the model
  can refer to them.
- **In-app SHA-256 check.** Only the file size is checked.
- **Model kept resident.** The model is freed on session close (about 60 s idle).
- **Faster CPU kernels.** The default build uses baseline armv8-a. A dotprod build is faster but crashes on some
  Cortex-A53-only phones.
- **Telemetry and benchmarks** (load time, tokens/s, RAM) across devices.
- **32-bit phones.** No native library, so they use the rule engine only.

## Rough edges

- `llama_jni.cpp` logs the raw model output at info level. Remove after on-phone testing.
- `path_provider` is in `pubspec.yaml` but no longer used by Dart code.
- The grammar fix for tool output (see [tools-and-validation.md](tools-and-validation.md)) is not yet verified on a
  phone.
- The memory dedupe scan is O(n). Fine for thousands of rows; not for more.
- Priority words (`low`, `normal`, `medium`, `high`) are accepted by the validator only. The grammar allows only the
  digits 0–2.
- `recurrence` column exists but nothing reads or writes it.
- `embedding` column in `memories` is reserved and unused.
- Desktop and web runs are not supported. sqflite needs a desktop FFI package that is not in `pubspec.yaml`.
- Nothing from this session is committed. The working tree holds all the changes.
