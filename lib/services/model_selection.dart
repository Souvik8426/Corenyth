import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'model_status.dart';

/// Persists the chosen catalog model id under the app DB directory (private),
/// not in public `Documents/localmodels`.
class ModelSelection {
  final String dir;

  ModelSelection(this.dir);

  static Future<ModelSelection> open() async =>
      ModelSelection(await getDatabasesPath());

  String get _path => p.join(dir, '.selected_model');
  String get _attemptPath => p.join(dir, '.model_load_attempt');

  /// Catalog id currently chosen; missing/unknown → default 0.6B.
  String readId() {
    final f = File(_path);
    if (!f.existsSync()) return defaultModelId;
    final raw = f.readAsStringSync().trim();
    return modelById(raw)?.id ?? defaultModelId;
  }

  ModelSpec get selected => modelById(readId())!;

  /// Writes [id] only if it is in the allowlist.
  Future<void> writeId(String id) async {
    final spec = modelById(id);
    if (spec == null) {
      throw ArgumentError.value(id, 'id', 'not an allowlisted model');
    }
    await File(_path).writeAsString(spec.id);
  }

  /// Absolute path for [spec] under the public models folder.
  String pathIn(String modelsDir, [ModelSpec? spec]) =>
      p.join(modelsDir, (spec ?? selected).fileName);

  /// Prefer [preferredId]/selected if its file is ready; else default 0.6B if ready;
  /// else null (caller uses rules). [isReady] is for tests; production uses size check.
  ModelSpec? resolveLoadable(String modelsDir,
      {String? preferredId, bool Function(ModelSpec)? isReady}) {
    final ready = isReady ??
        ((s) =>
            checkModelSpec(modelsDir, s, granted: true) == ModelState.ready);
    final want = modelById(preferredId ?? readId()) ?? model06b;
    if (ready(want)) return want;
    if (want.id != model06b.id && ready(model06b)) return model06b;
    return null;
  }

  /// Marks a native load of [id] as in progress. A native out-of-memory kill
  /// never returns, so a marker still present at the next boot means the load
  /// crashed the app ([crashedAttempt]).
  Future<void> markAttempt(String id) => File(_attemptPath).writeAsString(id);

  Future<void> clearAttempt() async {
    final f = File(_attemptPath);
    if (await f.exists()) await f.delete();
  }

  /// Model whose load was interrupted last run, or null. Clears the marker.
  Future<ModelSpec?> crashedAttempt() async {
    final f = File(_attemptPath);
    if (!await f.exists()) return null;
    final id = (await f.readAsString()).trim();
    await f.delete();
    return modelById(id);
  }

  /// True when [path]'s SHA-256 equals [spec]'s pinned hash. Hashes in a
  /// background isolate (streamed, never the whole file in memory) and caches
  /// the digest by file size + modified time, so only a new/changed file is
  /// re-hashed. Missing/unreadable → false.
  Future<bool> verify(ModelSpec spec, String path) async {
    final f = File(path);
    final FileStat st;
    try {
      st = await f.stat();
    } catch (_) {
      return false;
    }
    if (st.type != FileSystemEntityType.file) return false;
    final key = '${st.size}:${st.modified.millisecondsSinceEpoch}';
    final cache = File(p.join(dir, '.sha256_${spec.id}'));
    String? digest;
    try {
      final c = (await cache.readAsString()).split(' ');
      if (c.length == 2 && c[0] == key) digest = c[1];
    } catch (_) {}
    if (digest == null) {
      try {
        digest = await Isolate.run(() async =>
            (await sha256.bind(File(path).openRead()).first).toString());
      } catch (_) {
        return false;
      }
      try {
        await cache.writeAsString('$key $digest');
      } catch (_) {} // cache only; the check itself succeeded
    }
    return digest == spec.sha256;
  }
}
