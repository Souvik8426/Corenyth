import 'dart:io';

/// The one model file the app is built around (unsloth/Qwen3-0.6B-GGUF, pinned commit).
/// `resolve/` serves the file itself; the `blob/` link is the HTML page.
const modelUrl = 'https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/'
    '626eb58354de1127ccd7a9dc213485a3b716534c/Qwen3-0.6B-Q4_0.gguf';

/// Exact size of that file; a smaller one is an unfinished download/copy.
const modelBytes = 382156160;

enum ModelState { noAccess, missing, incomplete, ready }

/// Progress of the one-time native load that follows a successful install/boot.
enum ModelLoad { idle, loading, loaded, failed }

/// ponytail: size match only, no SHA256 (needs a hashing dep; sha256 is in the README).
ModelState checkModel(String path, {required bool granted, int expectedBytes = modelBytes}) {
  if (!granted) return ModelState.noAccess;
  final f = File(path);
  if (!f.existsSync()) return ModelState.missing;
  return f.lengthSync() == expectedBytes ? ModelState.ready : ModelState.incomplete;
}
