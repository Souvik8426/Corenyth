# Model install and loading

The app has no INTERNET permission, so the user downloads a model in a browser and places it on the device.

## Allowlisted models

Only two Qwen3 ChatML GGUF files are accepted (arbitrary GGUFs are rejected):

| Id | File | Bytes (HF `X-Linked-Size`) | SHA-256 (HF LFS / `X-Linked-ETag`) | Role |
|---|---|---|---|---|
| `qwen3-0.6b` | `Qwen3-0.6B-Q4_0.gguf` | 382,156,160 | `24ccc1cc…2159b` | **Default** |
| `qwen3-1.7b` | `Qwen3-1.7B-Q4_0.gguf` | 1,056,782,912 | `c876f159…81c5` | Optional |

Pinned resolve URLs live in `lib/services/model_status.dart` (`modelCatalog`). Both share the Dart-owned ChatML template in `Prompt.render`; no native template change.

Sizes and hashes were checked against the Hugging Face tree API (`lfs.oid`, `lfs.size`) and resolve headers for the pinned commits.

**Integrity in the app:** `checkModel` is a size check only (it decides "installed"). Before a native load, `ModelSelection.verify` streams the file through SHA-256 (`crypto`, already in the lock file at 3.0.7, now declared directly) in a background isolate and compares it with the pinned hash. The digest is cached in the app DB directory keyed by file size + modified time, so only a new or changed file is hashed again. A mismatch never reaches native `load`.

**Device RAM / latency** for 1.7B (or 0.6B) are **not measured** in this build. Do not assume 1.7B fits or is fast enough on a given phone.

## Files involved

- `lib/services/model_status.dart`: catalog, `checkModel` / `checkModelSpec`, back-compat `modelUrl` / `modelBytes` / `modelFileName` for the default.
- `lib/services/model_selection.dart`: persists chosen id in the app DB directory as `.selected_model` (not in public `Documents/localmodels`).
- `lib/services/app_services.dart`: `ensureModel` verifies and loads `modelPath`; on failure falls back to 0.6B (and re-selects it) if installed, else rules. `selectModel` switches between loads. A fresh `LlamaChannelEngine` per load, so no stale path.
- `lib/main.dart`: `ModelSetupCard` / `ModelLoadDialog` (install + optional model pick).
- `lib/ui/model_status_view.dart`: status chip shows selected vs active and fallback, plus the unmeasured disclaimer.
- `lib/services/native_bridge.dart` and `MainActivity.kt`: `modelsDir`, `requestStorageAccess`, `openUrl`.

## Where the file goes

`Documents/localmodels/<exact file name>` on shared storage. Selection preference is private (DB path). `MainActivity.modelsDir()` creates the folder when storage access is granted.

## Storage access

- Android 11+: `MANAGE_EXTERNAL_STORAGE` ("All files access"), opened from settings.
- Android 6–10: `WRITE_EXTERNAL_STORAGE`, requested at runtime.

## User steps

1. Grant file access.
2. Download the chosen allowlisted file (0.6B ≈ 365 MiB, 1.7B ≈ 1008 MiB). Only `https://huggingface.co/` URLs are accepted.
3. Move it from Downloads to `Documents/localmodels` with the Files app. Keep the exact file name.
4. In the setup UI, select which installed model to use (default remains 0.6B). The app reloads when inference is idle.

From a PC: `adb push <file>.gguf /sdcard/Documents/localmodels/` (open the app once first).

## Loading, switching, fallback

- `ensureModel` is the single load owner. Concurrent callers share one load; it waits for `releaseModel`.
- Switching (`selectModel`): saves the choice, waits for any running load, and serializes with other switches. Native requests run on one worker thread, so a reply in progress finishes before the new model loads (native `load` frees the old model). The picker is disabled while a model loads or a chat reply is being generated. A choice whose file is not installed is saved; the active model stays until the file is there.
- If the selected model fails the SHA-256 check or native load, the app loads 0.6B when that file is installed and re-selects it; otherwise `ModelLoad.failed` / rule engine. The note shown in the setup card and status chip says why.
- A marker file is written around each native load. If the app dies mid-load (likely out of memory), the next start re-selects 0.6B and says so.
- No cloud fallback.

## Verification and gaps

- Same-size corrupt files look "installed" (size check) but fail the SHA-256 check before loading.
- Switching and fallback are tested with a mocked method channel, not on a phone.
- On-device memory/latency for optional 1.7B: **not verified** here.
