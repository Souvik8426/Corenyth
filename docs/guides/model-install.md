# Model install and loading

The app has no INTERNET permission, so the model file is copied onto the device by the user.

## The allowlisted model

Exactly one GGUF file is accepted. The stock Qwen3 0.6B/1.7B files and any other GGUF are rejected:

| Id | File | Bytes | SHA-256 | Role |
|---|---|---|---|---|
| `corenyth-0.6b-tuned` | `Corenyth-Qwen3-0.6B-tuned-Q4_0.gguf` | 381,566,560 | `77d3f6d4…b821` | Default and only model |

It is Qwen3-0.6B with a LoRA trained on Corenyth's plan prompts, merged and quantized to Q4_0 by Unsloth (see [training/README.md](../../training/README.md)). Its `url` is the GitHub release asset; the setup card's **Download in browser** button hands it to the browser (`openUrl` only accepts `huggingface.co` and this repo's `releases/` links), since the app itself has no INTERNET permission. Each retrained file has a new size and SHA-256: update `corenythModel` in `lib/services/model_status.dart` with every export.

The spec lives in `lib/services/model_status.dart` (`corenythModel`, `modelCatalog`). It uses the Dart-owned ChatML template in `Prompt.render`; no native template change.

**Integrity in the app:** `checkModel` is a size check only (it decides "installed"). Before a native load, `ModelSelection.verify` streams the file through SHA-256 in a background isolate and compares it with the pinned hash. The digest is cached in the app DB directory keyed by file size + modified time, so only a new or changed file is hashed again. A mismatch never reaches native `load`.

**Device RAM / latency** are not formally measured. On the test phone a warm turn took about 3–4 s (see [reliability status](../development/reliability-status.md)).

## Files involved

- `lib/services/model_status.dart`: the model spec, `checkModel` / `checkModelSpec`, back-compat `modelUrl` / `modelBytes` / `modelFileName`.
- `lib/services/model_selection.dart`: persists the chosen id in the app DB directory as `.selected_model`. An id that is no longer allowlisted (e.g. a stock model saved by an older build) reads as the default.
- `lib/services/app_services.dart`: `ensureModel` verifies and loads `modelPath`; on failure the rule engine answers. A fresh `LlamaChannelEngine` per load, so no stale path.
- `lib/main.dart`: `ModelSetupCard` (install steps, then a read-only row for the model) and `ModelLoadDialog`.
- `lib/ui/model_status_view.dart`: status chip.
- `lib/services/native_bridge.dart` and `MainActivity.kt`: `modelsDir`, `requestStorageAccess`.

## Where the file goes

`Documents/localmodels/Corenyth-Qwen3-0.6B-tuned-Q4_0.gguf` on shared storage. `MainActivity.modelsDir()` creates the folder when storage access is granted.

## Storage access

- Android 11+: `MANAGE_EXTERNAL_STORAGE` ("All files access"), opened from settings.
- Android 6–10: `WRITE_EXTERNAL_STORAGE`, requested at runtime.

## User steps

1. Open the app once and grant file access.
2. Tap **Download in browser** in the setup card, then move the file from `Download` to `Documents/localmodels` with the Files app. Or from a computer: `adb push Qwen3-0.6B.Q4_0.gguf /sdcard/Documents/localmodels/Corenyth-Qwen3-0.6B-tuned-Q4_0.gguf` (the Colab export is named `Qwen3-0.6B.Q4_0.gguf`; the target name must be exact).
3. Or copy it to the phone another way and move it into `Documents/localmodels` with the Files app, keeping the exact name.
4. Return to the app: it re-checks, verifies the hash and loads.

## Loading and fallback

- `ensureModel` is the single load owner. Concurrent callers share one load; it waits for `releaseModel`.
- If the file fails the SHA-256 check or native load, `ModelLoad.failed` and the rule engine answers. The note in the setup card and status chip says why.
- A marker file is written around each native load; if the app dies mid-load (likely out of memory), the next start reports it.
- No cloud fallback.

## Verification and gaps

- Same-size corrupt files look "installed" (size check) but fail the SHA-256 check before loading.
- Loading and fallback are unit-tested with a mocked method channel; the model has also been loaded and used on one phone (20 October 2026).
