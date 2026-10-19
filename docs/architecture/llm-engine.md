# LLM engine

The default model is Qwen3-0.6B (Q4_0 GGUF); an optional allowlisted Qwen3-1.7B Q4_0 may be selected.
Both use Dart-owned ChatML (`Prompt.render`). Models run on the phone's CPU via llama.cpp. The Dart side
only knows `LlmEngine.complete(Prompt)`. Everything native sits behind a MethodChannel.

## Build

- `android/app/build.gradle.kts` runs CMake on `android/app/src/main/cpp/CMakeLists.txt`.
- `CMakeLists.txt` forces `CMAKE_BUILD_TYPE=Release`. Debug builds otherwise compile ggml without `-O` and run about
  50x slower.
- llama.cpp is cloned at tag `b11541` into `android/app/src/main/cpp/llama.cpp`. It is gitignored. Without the clone,
  CMake stops with the exact clone command.
- Output: one static llama plus `libllama_jni.so`, linked with `log`. OpenMP is off.
- CPU kernels use the baseline `armv8-a` (no dotprod or i8mm), so every arm64 phone can run the library.
- ABIs: arm64-v8a and x86_64. 32-bit devices get no native library and use the rule engine.

## Channel protocol (`assistant/llm`)

| Method | Args | Returns | Notes |
|---|---|---|---|
| `load` | `path`, `contextSize` (default 2048) | `bool` | Idempotent: same `path:contextSize` already resident returns `true` at once. Worker thread. |
| `generate` | `id`, `prompts` (candidate renders, fullest first), `maxTokens`, `grammar`, `stream` | `String` | Uses the first candidate that fits `n_ctx` with `maxTokens`. Action 160 tokens, memory 80. |
| `cancel` | `id` | none | Cancels only that request (queued or running). Runs inline, not on the worker. |
| `unload` | none | none | Frees model and context. |
| `text` (native -> Dart) | `id`, `text` | | While `stream` is true: cumulative raw output, posted to the requesting isolate's channel. |

Error codes: `llama_cancelled`, `prompt_too_long` (no candidate fits), `llama_error` (anything else in the worker),
`llama_unavailable` (no native library). Dart: `load` failures mean "use rules"; in a turn, `prompt_too_long` asks
for a shorter message, `llama_cancelled` ends the turn silently, other errors fall back to rules with
`lastFallbackReason` set.

## Ownership (Dart)

- `AppServices.ensureModel` is the single load owner. It always calls native `load` (cheap when resident), because
  residency is process-wide and another activity or memory pressure may have freed it. The status only shows
  "loading" when it was not believed loaded. It is called at session start and before each inference.
- Selected model comes from `ModelSelection` (private `.selected_model`). Each load first checks the pinned SHA-256
  (cached), then loads with a fresh `LlamaChannelEngine` for the current path. On failure it falls back to the
  default 0.6B file if installed (and re-selects it), else rules. See [model-install.md](../guides/model-install.md).
- Each session gets its own `LlamaChannelEngine`, so `cancel` stops only that session's requests.
- `releaseModel` (memory pressure) is serialized with loads and sets the status to idle before unloading.

## Threading

- `LlamaBridge` (`LlamaBridge.kt`) runs `load`, `generate` and `unload` on a single-thread executor and posts results
  to the main looper. Request keys are `channel identity : id`, so ids from different isolates do not collide.
- The model is process-wide, so `MainActivity` and `VoiceSessionActivity` share one instance.
- Cancel sets an atomic id; llama.cpp's abort callback compares it with the running request, so prompt processing
  stops too.

## Native generation (`llama_jni.cpp`)

1. `nativeLoad`: loads the model. `n_ctx = n_batch = contextSize`; threads `clamp(hardware_concurrency, 1, 4)`.
2. `nativeGenerate`:
   - Tokenizes candidates (with `parse_special`) until one fits; none -> `prompt_too_long`.
   - Sampler chain: optional grammar, then greedy.
   - KV cache reuse: keeps the longest common token prefix with the previous request (`llama_memory_seq_rm` on the
     rest) and decodes only the new tokens. A cancelled or failed request clears the cache.
   - Streams cumulative complete-UTF-8 output via `onNativeText` when asked.
   - Returns raw UTF-8 bytes (Java's modified UTF-8 would mangle emoji).
3. `nativeUnload` frees the context and model.

Logs (`adb logcat -s LlamaBridge llama.cpp`): load time, prompt tokens (and how many were reused), time to first
token, generated tokens and timings. Model output text is not logged.

## Prompt (`engine.dart`, `Prompt.render`)

The assistant uses `PromptKind.plan` (see [request-flow.md](request-flow.md)): system text, `Now`, `Pending:`, fresh `#id title` task
lines, bounded earlier user context, active personal memories and the current message, with `maxTokens` 120. Task selection ranks relevance before applying its cap. Native tokenization chooses a fitting prompt candidate; byte length is not a measured token count. The older `action` kind below is
kept for the grammar contract and tests.

- Qwen ChatML, most stable first for KV reuse: system (fixed instructions + personal context), chat history, then the
  user turn with the variable parts (`Now`, relevant memories, tasks / reminders when the router included them,
  marked `(partial: ...)` when capped at 10).
- `/no_think` plus a pre-filled empty `<think></think>`, so the model writes JSON directly.
- The system prompt lists the tools, including selection by `#id` or exact title (`target_title` for edits), and
  says to ask when unclear. Two inline examples show respond vs tool use.
- ChatML markers in user-provided text are neutralized (`neutralizeChatMl`).
- `candidates()` drops oldest history first, then memories/personal context; the user text is never cut.

## Grammar

- `semanticGrammar` / `semanticGrammarV2` (`semantic.dart`): intent-specific branches permit only the fields accepted by that intent's parser. The selected contract's grammar is sent for `plan` prompts (`LlamaChannelEngine.completeStreaming`).

- `toolGrammar` (`tools.dart`) is generated from `toolSchemas`: one JSON object, `respond` or a known tool with typed
  arguments (priority 0..2). The validator still runs afterwards and also enforces exactly one selector
  (`id` or title) for complete/delete/cancel/edit.
- `Prompt.memoryGrammar` allows only `{"remember":false}` or `{"remember":true,"memory":...,"category":...}`.

## Fallback

`RuleEngine` is used when no model is installed or loaded, or when the model fails, returns an invalid plan, or the
app rejects the plan. No retry: decoding is greedy. Arithmetic and pure time answers to a pending question never
need the model. Ordinary tests use stand-in engines; the opt-in host reference evaluates the actual Qwen file. See [reliability status](../development/reliability-status.md) for results and [device-evaluation.md](../development/device-evaluation.md) for phone checks.

## Not measured

Thread count, context size and baseline `armv8-a` kernels are defaults, not tuned. No load-time, tokens/s or RAM
numbers have been recorded yet; see [performance-validation.md](../development/performance-validation.md).


## Current evaluation limits

The host reference uses the actual catalog Qwen3-0.6B file and matching tokenizer/GBNF/greedy sampling, but a **4096-token** context; `LlamaChannelEngine` defaults to **2048**. It also reloads a fresh context per invocation rather than measuring warm Android KV reuse. Host results therefore do not qualify production phone performance or context-budget parity. Development state checks passed 97 cases with five incomplete; held-out checks failed acceptance (12 pass, 18 fail, four incomplete). See [reliability status](../development/reliability-status.md).
