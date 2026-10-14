import 'dart:io';

import 'package:path/path.dart' as p;

/// Allowlisted local GGUF models (Qwen3 ChatML only). Sizes/SHA-256 are the Hugging Face
/// LFS metadata of the pinned commits (`X-Linked-Size` / `X-Linked-ETag`, tree API `lfs.oid`).
/// [checkModel] is only a size check; [ModelSelection.verify] hashes the file before load.

enum ModelState { noAccess, missing, incomplete, ready }

/// Progress of the one-time native load that follows a successful install/boot.
enum ModelLoad { idle, loading, loaded, failed }

/// One pinned, ChatML-compatible Qwen3 GGUF the app may load.
class ModelSpec {
  final String id;
  final String fileName;
  final String url;
  final int expectedBytes;
  final String label;
  /// HF LFS OID = SHA-256 of the file bytes; checked before the first load.
  final String sha256;
  /// Only `chatml` is accepted; Dart [Prompt.render] owns the template.
  final String chatTemplate;

  const ModelSpec({
    required this.id,
    required this.fileName,
    required this.url,
    required this.expectedBytes,
    required this.label,
    required this.sha256,
    this.chatTemplate = 'chatml',
  });

  /// Rough download size for UI copy (MiB, rounded).
  int get approxMiB => (expectedBytes / (1024 * 1024)).round();
}

const defaultModelId = 'qwen3-0.6b';

/// Pinned commit `626eb583…` — unsloth/Qwen3-0.6B-GGUF Q4_0.
const ModelSpec model06b = ModelSpec(
  id: defaultModelId,
  fileName: 'Qwen3-0.6B-Q4_0.gguf',
  url: 'https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/'
      '626eb58354de1127ccd7a9dc213485a3b716534c/Qwen3-0.6B-Q4_0.gguf',
  expectedBytes: 382156160,
  label: 'Qwen3 0.6B (default)',
  sha256: '24ccc1cc08429fadd236268f920e965a376603479ca70f499be8930169c2159b',
);

/// Pinned commit `d7f544ee…` — unsloth/Qwen3-1.7B-GGUF Q4_0 (optional).
const ModelSpec model17b = ModelSpec(
  id: 'qwen3-1.7b',
  fileName: 'Qwen3-1.7B-Q4_0.gguf',
  url: 'https://huggingface.co/unsloth/Qwen3-1.7B-GGUF/resolve/'
      'd7f544eead698dbd1f15126ef60b45a1e1933222/Qwen3-1.7B-Q4_0.gguf',
  expectedBytes: 1056782912,
  label: 'Qwen3 1.7B (optional)',
  sha256: 'c876f159707a4e4f70e045106c69db15bfc935a4981706fd4f65c6e7ea1e81c5',
);

const List<ModelSpec> modelCatalog = [model06b, model17b];

/// Back-compat aliases for the default model (literals; field access is not a const expr).
const modelFileName = 'Qwen3-0.6B-Q4_0.gguf';
const modelUrl = 'https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/'
    '626eb58354de1127ccd7a9dc213485a3b716534c/Qwen3-0.6B-Q4_0.gguf';
const modelBytes = 382156160;

ModelSpec? modelById(String id) {
  for (final m in modelCatalog) {
    if (m.id == id) return m;
  }
  return null;
}

ModelSpec? modelByFileName(String name) {
  for (final m in modelCatalog) {
    if (m.fileName == name) return m;
  }
  return null;
}

/// Reject arbitrary GGUF names; only catalog ChatML Qwen3 files are loadable.
bool isAllowlistedModelFile(String fileName) =>
    modelByFileName(fileName)?.chatTemplate == 'chatml';

/// Size match only, not integrity: a same-size corrupt file passes here. The
/// SHA-256 check before loading ([ModelSelection.verify]) catches it.
ModelState checkModel(String path,
    {required bool granted, int expectedBytes = modelBytes}) {
  if (!granted) return ModelState.noAccess;
  final f = File(path);
  if (!f.existsSync()) return ModelState.missing;
  return f.lengthSync() == expectedBytes
      ? ModelState.ready
      : ModelState.incomplete;
}

ModelState checkModelSpec(String dir, ModelSpec spec, {required bool granted}) {
  if (!granted) return ModelState.noAccess;
  return checkModel(p.join(dir, spec.fileName),
      granted: true, expectedBytes: spec.expectedBytes);
}

/// [checkModel] with the catalog size for [path]'s file name (default size otherwise).
ModelState checkModelPath(String path, {bool granted = true}) => checkModel(path,
    granted: granted,
    expectedBytes: modelByFileName(p.basename(path))?.expectedBytes ?? modelBytes);
