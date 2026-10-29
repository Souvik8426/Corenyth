import 'dart:io';

import 'package:assistant/data/repos.dart';
import 'package:assistant/services/backup/backup_format.dart';
import 'package:assistant/services/backup/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/backup_fixture.dart';

/// A database with two tasks and one reminder linked to the first task,
/// exported to a backup file the tests can then edit.
Future<({BackupHarness harness, Map<String, Object?> entries, String path})>
    exportedBackup() async {
  final db = await openTestDb();
  final folder = await tempFolder();
  final harness = BackupHarness(db, folder);
  final first = await TaskRepo(db).create('Buy milk');
  await TaskRepo(db).create('Call the bank');
  await harness.reminders.create('Buy milk', DateTime(2030, 1, 2, 9),
      taskId: first.id);
  final path = await harness.export();
  return (harness: harness, entries: readEntries(path), path: path);
}

void main() {
  test('malformed archives are refused with a readable reason', () async {
    final folder = await tempFolder();
    final service = BackupHarness(await openTestDb(), folder).service;

    final garbage = '${folder.path}/garbage.corenyth';
    File(garbage).writeAsBytesSync([1, 2, 3, 4, 5]);
    await expectLater(service.readAndCheck(garbage),
        throwsA(isA<BackupException>()));

    final missing = '${folder.path}/missing-manifest.corenyth';
    File(missing).writeAsBytesSync(zipEntries({'data.json': '{}'}));
    await expectLater(service.readAndCheck(missing),
        throwsA(predicate((e) => e.toString().contains('exactly'))));

    final unsafe = '${folder.path}/unsafe.corenyth';
    File(unsafe).writeAsBytesSync(
        zipEntries({'manifest.json': '{}', '../escape.json': '{}'}));
    await expectLater(service.readAndCheck(unsafe),
        throwsA(predicate((e) => e.toString().contains('unsafe file name'))));
  });

  test('unsupported format versions are refused', () async {
    final exported = await exportedBackup();
    final manifest = Map<String, Object?>.from(
        exported.entries[manifestEntryName] as Map<String, Object?>);
    manifest['formatVersion'] = backupFormatVersion + 1;
    final path = writeArchive(exported.harness.folder, manifest,
        exported.entries[dataEntryName] as Map<String, Object?>,
        name: 'future.corenyth');

    await expectLater(
        exported.harness.service.readAndCheck(path),
        throwsA(predicate((e) =>
            e.toString().contains('format version ${backupFormatVersion + 1}'))));
  });

  test('duplicate and invalid ids are refused', () async {
    final exported = await exportedBackup();
    final data = Map<String, Object?>.from(
        exported.entries[dataEntryName] as Map<String, Object?>);
    final tasks = (data['tasks'] as List).cast<Map<String, Object?>>();

    tasks[1]['id'] = tasks[0]['id'];
    final duplicate = writeArchive(exported.harness.folder,
        exported.entries[manifestEntryName] as Map<String, Object?>, data,
        name: 'duplicate.corenyth');
    await expectLater(exported.harness.service.readAndCheck(duplicate),
        throwsA(isA<BackupException>()));

    final fresh = await exportedBackup();
    final freshData = Map<String, Object?>.from(
        fresh.entries[dataEntryName] as Map<String, Object?>);
    ((freshData['tasks'] as List).first as Map<String, Object?>)['id'] = 'x';
    final invalid = writeArchive(fresh.harness.folder,
        fresh.entries[manifestEntryName] as Map<String, Object?>, freshData,
        name: 'invalid.corenyth');
    await expectLater(fresh.harness.service.readAndCheck(invalid),
        throwsA(isA<BackupException>()));
  });

  test('broken links between rows are refused', () async {
    final exported = await exportedBackup();
    final data = Map<String, Object?>.from(
        exported.entries[dataEntryName] as Map<String, Object?>);
    final reminders = (data['reminders'] as List).cast<Map<String, Object?>>();
    reminders.first['taskId'] = 999; // no such task in the backup

    final path = writeArchive(exported.harness.folder,
        exported.entries[manifestEntryName] as Map<String, Object?>, data,
        name: 'broken-link.corenyth');
    await expectLater(
        exported.harness.service.readAndCheck(path),
        throwsA(predicate(
            (e) => e.toString().contains('points at a task that is not'))));
  });
}
