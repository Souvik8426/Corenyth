import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/backup/backup_format.dart';
import 'package:assistant/services/backup/backup_gateway.dart';
import 'package:assistant/services/backup/backup_service.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'v2_db.dart';

/// A migrated app database in a temporary folder, closed on teardown.
/// Uses the v2-then-migrate path, because a fresh `onCreate` cannot run on
/// the host SQLite (no FTS4); see [openMigratedV2].
Future<Database> openTestDb() => openMigratedV2();

/// A scheduler that records what the backup asked it to arm or cancel.
class RecordingScheduler extends ReminderScheduler {
  final scheduled = <int>[];
  final cancelled = <int>[];

  @override
  Future<void> schedule(Reminder r) async => scheduled.add(r.id);

  @override
  Future<void> cancel(int id) async => cancelled.add(id);
}

/// A folder for backups, inside a temporary directory removed on teardown.
Future<Directory> tempFolder() async {
  final dir = await Directory.systemTemp.createTemp('corenyth-backup-folder');
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

/// A service wired to [db], writing into [folder], with fake file access.
class BackupHarness {
  final Database db;
  final Directory folder;
  final FakeBackupFileGateway gateway = FakeBackupFileGateway();
  final RecordingScheduler scheduler = RecordingScheduler();
  late final ReminderRepo reminders = ReminderRepo(db);
  late final BackupService service;

  BackupHarness(this.db, this.folder, {Future<String> Function()? folderResolver}) {
    service = BackupService(
      db: db,
      reminders: reminders,
      scheduler: scheduler,
      gateway: gateway,
      folderResolver: folderResolver ?? () async => folder.path,
    );
  }

  /// Exports the current data and returns the archive path.
  Future<String> export() async => (await service.exportBackup()).path;
}

/// A zip archive holding exactly [entries] (name to text), for crafted files.
List<int> zipEntries(Map<String, String> entries) {
  final archive = Archive();
  entries.forEach((name, text) => archive.add(ArchiveFile.string(name, text)));
  return ZipEncoder().encodeBytes(archive);
}

/// Builds a Corenyth-shaped archive from two JSON texts.
List<int> makeArchive({required String manifest, required String data}) {
  final archive = Archive()
    ..add(ArchiveFile.string(manifestEntryName, manifest))
    ..add(ArchiveFile.string(dataEntryName, data));
  return ZipEncoder().encodeBytes(archive);
}

/// The two JSON texts of an exported backup file, so a test can edit one.
Map<String, Object?> readEntries(String path) {
  final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  final out = <String, Object?>{};
  for (final f in archive.files) {
    if (f.isFile) out[f.name] = jsonDecode(utf8.decode(f.readBytes()!));
  }
  return out;
}

/// Writes [manifest] and [data] (already decoded JSON) as a backup file.
String writeArchive(Directory folder, Map<String, Object?> manifest,
    Map<String, Object?> data, {String name = 'edited.corenyth'}) {
  final path = '${folder.path}/$name';
  File(path).writeAsBytesSync(makeArchive(
    manifest: jsonEncode(manifest),
    data: jsonEncode(data),
  ));
  return path;
}

/// The rows of [table], in id order, for comparing before and after.
Future<List<Map<String, Object?>>> rowsOf(Database db, String table) =>
    db.query(table, orderBy: 'id');
