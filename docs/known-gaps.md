# Known gaps

## Not built yet

- **Speech input and output.** sherpa-onnx VAD and streaming ASR into `AssistantSession.handle`. The `speak` callback
  exists in the session, but nothing calls TTS. `RECORD_AUDIO` is declared but never requested.
- **Voice barge-in.** Typed chat has Stop (per-session cancel); nothing interrupts by voice yet.
- **In-app SHA-256 check.** Only the file size is checked.
- **Memory-pressure release on device.** Dart releases the model on `didHaveMemoryPressure` and reloads on the next
  inference; not yet verified on a phone. Native unload while a generation is running is the native worker's job.
- **Faster CPU kernels.** The default build uses baseline armv8-a. A dotprod build is faster but crashes on some
  Cortex-A53-only phones.
- **Telemetry and benchmarks** (load time, tokens/s, RAM) across devices.
- **32-bit phones.** No native library, so they use the rule engine only.

## Rough edges

- Grammar-constrained output, streaming, cancel, KV reuse and memory-pressure release are tested in Dart with
  mocks only; they still need on-phone verification.
- The memory dedupe scan is O(n). Fine for thousands of rows; not for more.
- Priority words (`low`, `normal`, `medium`, `high`) are accepted by the validator only. The grammar allows only the
  digits 0–2.
- `recurrence` column exists but nothing reads or writes it.
- `embedding` column in `memories` is reserved and unused.
- Desktop and web runs are not supported. `sqflite_common_ffi` is a dev dependency for tests only; the host SQLite
  has no FTS4, so tests cover the v2 -> v3 migration, not a fresh `onCreate`.
- A cancelled turn keeps its user message in history with no assistant reply.
- Title matching is exact after normalizing case, punctuation and spaces; no fuzzy matching. Reminder titles
  match only upcoming enabled reminders.
- Fast route rejects any negation/`or`/chained command and hands it to the model (or the rules' help reply).
- Nothing from this session is committed. The working tree holds all the changes.
