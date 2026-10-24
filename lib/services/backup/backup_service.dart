import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../../data/repos.dart';
import '../model_selection.dart';
import '../model_status.dart';
import '../native_bridge.dart';
import '../reminder_scheduler.dart';
import 'backup_format.dart';
import 'backup_gateway.dart';

/// Reads the user's saved context, writes it to a portable archive and reads
/// such an archive back.
///
/// It never touches the model: a backup is the app's own data, so it works
/// with or without a model installed.
class BackupService {
  final Database db;
  final ReminderRepo reminders;
  final ReminderScheduler scheduler;

  /// The persisted model choice, when there is one. Set after construction
  /// by [AppServices], which learns it while booting.
  ModelSelection? selection;

  final BackupFileGateway gateway;

  /// Where the folder that holds backups lives. Overridden in tests; the app
  /// uses an app-private `backups` folder.
  final Future<String> Function() folderResolver;

  /// True while a backup or an import runs. The UI disables its buttons and
  /// the service refuses a second operation.
  final busy = ValueNotifier<bool>(false);

  /// The last error, for the UI to show.
  final lastError = ValueNotifier<String?>(null);

  /// The last successful export, so the UI can offer to share it.
  final lastExport = ValueNotifier<BackupResult?>(null);

  /// Set by tests to make a step fail (the restore, the recovery backup).
  Future<void> Function(String step)? testHook;

  BackupService({
    required this.db,
    required this.reminders,
    required this.scheduler,
    ModelSelection? selection,
    BackupFileGateway? gateway,
    Future<String> Function()? folderResolver,
  })  : selection = selection,
        gateway = gateway ?? const NativeBackupFileGateway(),
        folderResolver = folderResolver ?? _defaultFolder;

  /// Backups live beside the private models directory and are exported by sharing.
  static Future<String> _defaultFolder() async {
    final dir = await NativeBridge.modelsDir();
    return p.join(p.dirname(dir.path), 'backups');
  }

  /// The app-private backup archive, offered to other apps via the share sheet.
  Future<String> backupPath() async =>
      p.join(await folderResolver(), backupFileName);

  // --- export -----------------------------------------------------------

  /// Writes every saved row into `backup.corenyth` in the private backups folder.
  ///
  /// The archive is built in memory and written through a temporary file, so
  /// a failed export never leaves a half-written backup behind.
  Future<BackupResult> exportBackup() async {
    if (busy.value) {
      throw const BackupException('A backup or import is already running.');
    }
    busy.value = true;
    lastError.value = null;
    try {
      final folder = await folderResolver();
      if (!await _ensureFolder(folder)) {
        throw const BackupException(
            'Corenyth could not create its backups folder. Check available '
            'storage space, then try again.');
      }
      final data = await _snapshot();
      final manifest = BackupManifest(
          createdAt: DateTime.now().toUtc(), counts: data.counts());
      final bytes = _encode(manifest, data);
      final target = p.join(folder, backupFileName);
      final temp = '$target.tmp';
      final file = File(temp);
      try {
        await file.writeAsBytes(bytes, flush: true);
        // Rename over the old backup: an existing one stays valid until the
        // new one is complete.
        await file.rename(target);
      } catch (_) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        rethrow;
      }
      final result =
          BackupResult(target, data.counts(), manifest.createdAt);
      lastExport.value = result;
      return result;
    } on BackupException catch (e) {
      lastError.value = e.message;
      rethrow;
    } catch (e) {
      final message = 'The backup could not be written: $e';
      lastError.value = message;
      throw BackupException(message);
    } finally {
      busy.value = false;
    }
  }

  /// Writes a recovery copy of the current data, with a UTC timestamp in the
  /// name, next to the main backup. Throws when it cannot be written, so the
  /// caller can abort before touching anything.
  Future<BackupResult> writeRecoveryBackup() async {
    final folder = await folderResolver();
    if (!await _ensureFolder(folder)) {
      throw const BackupException(
          'A recovery copy of your data could not be saved, so nothing was '
          'imported. Check available storage space and try again.');
    }
    final stamp = _timestamp(DateTime.now().toUtc());
    final target = p.join(folder, 'corenyth-recovery-$stamp.corenyth');
    final data = await _snapshot();
    final manifest = BackupManifest(
        createdAt: DateTime.now().toUtc(), counts: data.counts());
    final bytes = _encode(manifest, data);
    try {
      await File(target).writeAsBytes(bytes, flush: true);
    } catch (e) {
      throw BackupException('The recovery copy could not be saved: $e');
    }
    return BackupResult(target, data.counts(), manifest.createdAt,
        isRecovery: true);
  }

  /// `yyyyMMdd-HHmmss` in UTC.
  static String _timestamp(DateTime at) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${at.year.toString().padLeft(4, '0')}${two(at.month)}'
        '${two(at.day)}-${two(at.hour)}${two(at.minute)}${two(at.second)}';
  }

  /// Creates the folder when it is missing. False when the app may not write
  /// there (for example, when storage is full).
  Future<bool> _ensureFolder(String folder) async {
    try {
      final dir = Directory(folder);
      if (await dir.exists()) return true;
      await dir.create(recursive: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Every user row, read in one transaction so the backup is a single
  /// consistent view of the database.
  Future<BackupData> _snapshot() async => db.transaction((tx) async {
        Future<List<Map<String, Object?>>> rows(String table) => tx.query(table);
        final profileRows = await tx.query('assistant_profile',
            where: 'id = 1');
        final prefRows =
            await tx.query('assistant_preferences', where: 'id = 1');
        return buildBackupData(
          tasks: await rows('tasks'),
          reminders: await rows('reminders'),
          chats: await rows('chats'),
          conversations: await rows('conversations'),
          memories: await rows('memories'),
          pendingClarifications: await rows('pending_clarifications'),
          proactiveEvents: await rows('proactive_events'),
          reviewItems: await rows('review_items'),
          operations: await rows('operations'),
          profile:
              profileRows.isEmpty ? null : profileRows.first.cast<String, Object?>(),
          preferences: prefRows.isEmpty
              ? null
              : prefRows.first.cast<String, Object?>(),
          selectedModelId: selection?.readId(),
        );
      });

  /// The archive bytes: exactly the two entries, no directory entries.
  List<int> _encode(BackupManifest manifest, BackupData data) {
    final archive = Archive()
      ..add(ArchiveFile.string(
          manifestEntryName, encodeManifest(manifest)))
      ..add(ArchiveFile.string(dataEntryName, encodeData(data)));
    return ZipEncoder().encodeBytes(archive);
  }

  // --- import -----------------------------------------------------------

  /// Reads a backup file and checks it, without changing anything.
  ///
  /// Returns null when the user cancelled the picker. Throws
  /// [BackupException] with a readable reason when the file cannot be used.
  Future<BackupPreview?> pickAndCheck() async {
    final path = await gateway.pickBackupFile();
    if (path == null) return null;
    return readAndCheck(path);
  }

  /// Reads the archive at [path] and checks its structure, its version and
  /// every row it holds.
  Future<BackupPreview> readAndCheck(String path) async {
    final file = File(path);
    final int size;
    try {
      size = await file.length();
    } catch (e) {
      throw BackupException('That backup file could not be read: $e');
    }
    if (size > maxBackupBytes) {
      throw BackupException(
          'That file is too large to be a Corenyth backup (${size ~/ (1024 * 1024)} MB).');
    }
    final List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (e) {
      throw BackupException('That backup file could not be read: $e');
    }
    return decodeBackup(bytes, path);
  }

  /// Checks the archive bytes and returns what they hold.
  ///
  /// Nothing is ever written to disk while reading: only the two named
  /// entries are pulled into memory, so a crafted archive cannot write
  /// anywhere.
  static BackupPreview decodeBackup(List<int> bytes, String sourcePath) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw BackupException('That file is not a readable Corenyth backup: $e');
    }
    final names = <String>[];
    for (final file in archive.files) {
      final name = file.name;
      if (name.endsWith('/')) continue; // a directory entry
      if (name.startsWith('/') ||
          name.contains('..') ||
          name.contains('\\') ||
          name.contains(':')) {
        throw BackupException(
            'That backup contains an unsafe file name ("$name") and was not '
            'read.');
      }
      names.add(name);
    }
    if (!names.contains(manifestEntryName) || !names.contains(dataEntryName)) {
      throw BackupException(
          'That file is not a Corenyth backup: it needs exactly '
          '"$manifestEntryName" and "$dataEntryName".');
    }
    if (names.length != 2) {
      throw BackupException(
          'That backup contains ${names.length} files; a Corenyth backup has '
          'exactly two.');
    }
    final errors = <String>[];
    final manifestRaw = _readJson(archive, manifestEntryName, errors);
    if (manifestRaw == null) {
      throw BackupException(errors.join('\n'));
    }
    final manifest = BackupManifest.parse(manifestRaw, errors);
    if (manifest == null) {
      throw BackupException(errors.join('\n'));
    }
    final dataRaw = _readJson(archive, dataEntryName, errors);
    if (dataRaw == null) {
      throw BackupException(errors.join('\n'));
    }
    final data = parseBackupData(dataRaw, errors);
    if (data == null) {
      throw BackupException(errors.join('\n'));
    }
    return BackupPreview(manifest, data, sourcePath);
  }

  /// The parsed JSON of one entry, or null with the reason in [errors].
  static Object? _readJson(Archive archive, String name, List<String> errors) {
    final file = archive.files.firstWhere((f) => f.name == name);
    final int size = file.size;
    if (size > maxBackupEntryBytes) {
      errors.add('The "$name" entry is too large to be a Corenyth backup.');
      return null;
    }
    final content = file.readBytes();
    if (content == null) {
      errors.add('The "$name" entry could not be read.');
      return null;
    }
    if (content.length > maxBackupEntryBytes) {
      errors.add('The "$name" entry is too large to be a Corenyth backup.');
      return null;
    }
    try {
      return jsonDecode(utf8.decode(content));
    } catch (e) {
      errors.add('The "$name" entry is not valid JSON.');
      return null;
    }
  }

  /// Replaces the user's data with the backup's, after taking a recovery copy.
  ///
  /// The restore runs in one transaction: if any part of it fails, the
  /// original data is still there. Returns what was restored.
  Future<BackupResult> importBackup(BackupPreview preview) async {
    if (busy.value) {
      throw const BackupException('A backup or import is already running.');
    }
    busy.value = true;
    lastError.value = null;
    var modelChanged = false;
    String? previousModelId;
    try {
      // The recovery copy comes first: without it, nothing is touched.
      final recovery = await writeRecoveryBackup();
      await testHook?.call('recovery');

      final before = await _reminderIds();
      final previous = selection?.readId();

      await db.transaction((tx) async {
        await _clear(tx);
        await _insert(tx, preview.data);
        // The hook runs inside the transaction, so a failure here proves the
        // rollback: the original rows are still there afterwards.
        await testHook?.call('restore');
      });

      // The model choice is portable, but only when it is still allowed.
      final wanted = preview.data.selectedModelId;
      if (wanted != null && modelById(wanted) != null && selection != null) {
        previousModelId = previous;
        await selection!.writeId(wanted);
        modelChanged = true;
      }

      await _reconcileReminders(before, preview.data);
      return BackupResult(recovery.path, preview.manifest.counts,
          preview.manifest.createdAt);
    } on BackupException catch (e) {
      lastError.value = e.message;
      rethrow;
    } catch (e) {
      final message = 'The backup could not be imported: $e';
      lastError.value = message;
      throw BackupException(message);
    } finally {
      // A model choice written before a later failure is undone, so the
      // device keeps the model the user had.
      if (modelChanged && previousModelId != null) {
        try {
          await selection?.writeId(previousModelId);
        } catch (_) {}
      }
      busy.value = false;
    }
  }

  /// The ids of the reminders that exist now, so the import knows which
  /// platform alarms to remove.
  Future<Set<int>> _reminderIds() async => {
        for (final r in await db.query('reminders', columns: ['id']))
          r['id'] as int
      };

  /// Empties every user table, in an order the foreign keys allow.
  Future<void> _clear(Transaction tx) async {
    for (final table in [
      'review_items',
      'proactive_events',
      'pending_clarifications',
      'operations',
      'conversations',
      'reminders',
      'chats',
      'memories',
      'tasks',
    ]) {
      await tx.delete(table);
    }
    await tx.delete('assistant_profile');
    await tx.delete('assistant_preferences');
  }

  /// Writes the backup's rows back, with their original ids and links.
  Future<void> _insert(Transaction tx, BackupData data) async {
    for (final spec in backupTables) {
      final rows = data.rowsOf(spec.key);
      if (rows.isEmpty) continue;
      for (final row in rows) {
        await tx.insert(spec.table, row,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    if (data.profile != null) {
      await tx.insert('assistant_profile', data.profile!,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (data.preferences != null) {
      await tx.insert('assistant_preferences', data.preferences!,
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  /// Brings the platform alarms in line with the imported reminders.
  ///
  /// Reminders in the past are disabled and never replayed, future ones are
  /// armed, and the alarms of reminders that no longer exist are removed.
  Future<List<int>> _reconcileReminders(
      Set<int> before, BackupData data) async {
    final now = DateTime.now();
    await db.transaction((tx) async {
      for (final r in data.reminders) {
        final trigger = r['trigger_at'] as int;
        final enabled = r['enabled'] == 1;
        final past = trigger <= now.millisecondsSinceEpoch;
        await tx.update(
          'reminders',
          {
            // The stored intent is a device detail: it is recomputed here.
            'sync': enabled && !past ? 'schedule' : 'cancel',
            if (enabled && past) 'enabled': 0,
          },
          where: 'id = ?',
          whereArgs: [r['id']],
        );
      }
    });
    // Alarms of reminders the import removed.
    final after = await _reminderIds();
    for (final id in before.difference(after)) {
      try {
        await scheduler.cancel(id);
      } catch (_) {} // a stale alarm is re-checked at the next startup
    }
    // Arms the future ones and clears the intents that worked.
    return scheduler.rescheduleAll(reminders);
  }
}

/// Something went wrong that the user should be told about.
class BackupException implements Exception {
  final String message;
  const BackupException(this.message);

  @override
  String toString() => message;
}
