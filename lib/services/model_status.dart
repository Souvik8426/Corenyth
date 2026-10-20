import 'dart:io';

import 'package:path/path.dart' as p;

/// Allowlisted local GGUF model (Qwen3 ChatML only): Corenyth's fine-tuned 0.6B.
/// Size/SHA-256 are those of the exported file (training/README.md).
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

const defaultModelId = 'corenyth-0.6b-tuned';

/// The only allowlisted model: Qwen3-0.6B LoRA-fine-tuned on Corenyth's plan
/// prompts (training/), merged and quantized to Q4_0 by Unsloth. Published as a
/// GitHub release asset; the app only opens the link in the browser (no
/// INTERNET permission). A retrained file has a new size, hash and release URL.
const ModelSpec corenythModel = ModelSpec(
  id: defaultModelId,
  fileName: 'Corenyth-Qwen3-0.6B-tuned-Q4_0.gguf',
  url: 'https://github.com/Souvik8426/Corenyth/releases/download/v0.1.0-alpha.1/Corenyth-Qwen3-0.6B-tuned-Q4_0.gguf',
  expectedBytes: 381566560,
  label: 'Corenyth 0.6B (fine-tuned)',
  sha256: '77d3f6d469a6d5069a86980ec61f77bd0fb8b937b56d4fac0362659ca6c7b821',
);

const List<ModelSpec> modelCatalog = [corenythModel];

/// Back-compat aliases for the default model (literals; field access is not a const expr).
const modelFileName = 'Corenyth-Qwen3-0.6B-tuned-Q4_0.gguf';
const modelUrl =
    'https://github.com/Souvik8426/Corenyth/releases/download/v0.1.0-alpha.1/Corenyth-Qwen3-0.6B-tuned-Q4_0.gguf';
const modelBytes = 381566560;

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
