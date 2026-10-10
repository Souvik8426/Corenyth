# LLM engine

The model is Qwen3-0.6B (Q4_0 GGUF), run on the phone's CPU by llama.cpp. The Dart side only knows
`LlmEngine.complete(Prompt)`. Everything native sits behind a MethodChannel.

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
| `load` | `path`, `contextSize` (default 2048) | `bool` | Same path twice is a no-op. Runs on the worker thread. |
| `generate` | `prompt` (UTF-8 bytes), `maxTokens`, `grammar` | `String` | Action prompts use 160 tokens, memory prompts 80. |
| `cancel` | none | none | Runs inline on the main thread, so it can interrupt a running `generate`. |
| `unload` | none | none | Frees model and context. |

Errors: `llama_unavailable` when the native library is missing. `llama_error` for failures inside the worker.
Dart treats `MissingPluginException`, `PlatformException` and `false` from `load` as "use rules".

## Threading

- `LlamaBridge` (`LlamaBridge.kt`) runs `load`, `generate` and `unload` on a single-thread executor. Results are
  posted back to the main looper.
- The model is process-wide, so `MainActivity` and `VoiceSessionActivity` share one instance.
- `cancel` sets an atomic flag. llama.cpp's abort callback checks it, so prompt processing can stop too.

## Native generation (`llama_jni.cpp`)

1. `nativeLoad`: loads the model file. Context size is `n_ctx = n_batch = contextSize`. Threads are
   `clamp(hardware_concurrency, 1, 4)`.
2. `nativeGenerate`:
   - Builds a sampler chain. If a grammar is given, it runs first, then greedy selection.
   - Tokenizes the prompt with `parse_special`, so ChatML tags are real tokens. Rejects prompts where
     `prompt + maxTokens > n_ctx`.
   - Clears the KV cache. Each prompt is self-contained.
   - Decodes the prompt, then samples one token at a time until end-of-generation, `maxTokens`, or cancel.
   - Returns the output as raw UTF-8 bytes. Java's modified UTF-8 would mangle emoji.
3. `nativeUnload` frees the context and model.

Logs go to logcat under `LlamaBridge` (load time, token counts, timings) and `llama.cpp` (warnings and errors).

## Prompt (`engine.dart`, `Prompt.render`)

- Qwen ChatML: `<|im_start|>system … <|im_end|>`, then few-shot turns, then history, then the user turn.
- The user turn ends with `/no_think`. The assistant turn starts with an empty `<think></think>` block, so the model
  writes JSON directly.
- System prompt: a short description of the tools and the reply format. It also says when not to use a tool.
- Three few-shot examples ("hello", "add task buy milk", "remind me tomorrow at 8 to call mom") show respond vs tool use.
  Their dates are built relative to `now`.
- Memory extraction uses its own short system prompt, with the memory grammar.

## Grammar

- `toolGrammar` (`tools.dart`) is generated from `toolSchemas`. It allows one JSON object: either
  `{"type":"respond","text":...}` or `{"type":"tool","tool":...,"arguments":{...}}`, with each tool's required
  arguments, correct types, and priority limited to 0..2.
- `Prompt.memoryGrammar` allows only `{"remember":false}` or `{"remember":true,"memory":...,"category":...}`.
- Grammar constrains the output so it parses. The validator still runs afterwards (see
  [tools-and-validation.md](tools-and-validation.md)).

## Fallback

`AssistantSession._plan` tries the LLM first and falls back to `RuleEngine` on any error. There is no retry: decoding is
greedy, so a retry would repeat the same output.

## Known limits

- `cancel` is not called from Dart yet (it waits for barge-in with speech).
- No token streaming. `generate` returns the full string.
- Every build logs the raw model output at info level (`LOGI("output: ...")` in `llama_jni.cpp`). Remove it once
  on-phone testing passes.
