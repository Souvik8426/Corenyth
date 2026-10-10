# Model install and loading

The app has no INTERNET permission, so the user downloads the model in a browser and places it on the device.

## Files involved

- `lib/services/model_status.dart`: `modelUrl` (pinned Hugging Face `resolve/` link), `modelBytes = 382156160`,
  `checkModel(path, granted, expectedBytes)` returns `noAccess`, `missing`, `incomplete` or `ready`. The check is by
  size only.
- `lib/services/app_services.dart`: `modelFileName = 'Qwen3-0.6B-Q4_0.gguf'`, `modelPath`, `modelLoad` notifier,
  `loadModel()`, `modelState()`, `_engine()`.
- `lib/main.dart`: `ModelSetupCard` (the 4-step guide on the Chat tab) and `ModelLoadDialog` (the popup).
- `lib/services/native_bridge.dart` and `MainActivity.kt`: `modelsDir`, `requestStorageAccess`, `openUrl`.

## Where the file goes

`Documents/localmodels/Qwen3-0.6B-Q4_0.gguf` on shared storage. `MainActivity.modelsDir()` creates the folder when
storage access is granted, on every launch. The folder is therefore also re-created if the user deletes it.

## Storage access

- Android 11+: `MANAGE_EXTERNAL_STORAGE` ("All files access"), opened from settings.
- Android 6–10: `WRITE_EXTERNAL_STORAGE`, requested at runtime.

Scoped storage would hide a file that another app placed in `Documents`. That is why this path is used.

## User steps (shown in the app)

1. Grant file access.
2. Download the file (about 365 MB). The button opens the Hugging Face link in the browser. Only `https://huggingface.co/`
   URLs are accepted.
3. Move it from Downloads to `Documents/localmodels` with the Files app. Keep the exact file name.
4. Come back. The card re-checks when the app resumes and loads the model.

From a PC: `adb push Qwen3-0.6B-Q4_0.gguf /sdcard/Documents/localmodels/` (open the app once first).

## Loading

- `_ModelSetupCardState._check()` runs on start and on resume. If the state is `ready` and nothing has loaded yet, it
  opens `ModelLoadDialog` and calls `loadModel()`.
- `loadModel()` sets `modelLoad` to loading, calls `LlamaChannelEngine.load()`, then sets loaded or failed. The
  dialog shows a spinner, then success or an error with Retry.
- After a successful load, an open chat that is still on rules closes its session and starts a new one on the model.
  This only happens while the chat is idle.

## Unloading

The model is freed when a session closes. Sessions close after 60 s without input, so the model is unloaded after
about a minute idle and reloads silently on the next session. Reloads do not show the popup.

## Verification and gaps

- Only the file size is checked. The README lists the SHA-256 (`24ccc1cc…2159b`), but the app does not verify it yet.
- A file of the right size that is corrupt will fail inside llama.cpp at load time. The app then falls back to rules.
