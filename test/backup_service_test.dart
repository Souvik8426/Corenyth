import 'dart:io';

import 'package:assistant/data/repos.dart';
import 'package:assistant/services/backup/backup_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/backup_fixture.dart';

void main() {
  test('round trip restores every saved row with its original ids', () async {
    final db = await openTestDb();
    final harness = BackupHarness(db, await tempFolder());
    final task = await TaskRepo(db).create('Buy milk',
        due: DateTime(2030, 1, 1, 8));
    await TaskRepo(db).create('Call the bank');
    await harness.reminders.create('Buy milk', DateTime(2030, 1, 1, 7),
        taskId: task.id);
    await MemoryRepo(db).add('Prefers mornings', category: 'preference');

    final tasksBefore = await rowsOf(db, 'tasks');
    final memoriesBefore = await rowsOf(db, 'memories');
    final remindersBefore = await rowsOf(db, 'reminders');

    final path = await harness.export();
    final preview = await harness.service.readAndCheck(path);
    final result = await harness.service.importBackup(preview);

    expect(await rowsOf(db, 'tasks'), tasksBefore);
    expect(await rowsOf(db, 'memories'), memoriesBefore);
    final remindersAfter = await rowsOf(db, 'reminders');
    expect([for (final r in remindersAfter) r['title']],
        [for (final r in remindersBefore) r['title']]);
    expect([for (final r in remindersAfter) r['task_id']],
        [for (final r in remindersBefore) r['task_id']]);
    expect(result.counts['tasks'], 2);
    expect(result.counts['reminders'], 1);
  });

  test('an empty backup exports, reads back and imports', () async {
    final db = await openTestDb();
    final harness = BackupHarness(db, await tempFolder());

    final exported = await harness.service.exportBackup();
    expect(exported.counts['tasks'], 0);
    expect(exported.counts['reminders'], 0);

    final preview = await harness.service.readAndCheck(exported.path);
    expect(preview.data.tasks, isEmpty);
    await harness.service.importBackup(preview);
    expect(await rowsOf(db, 'tasks'), isEmpty);
  });

  test('import replaces the current data rather than merging into it',
      () async {
    final db = await openTestDb();
    final harness = BackupHarness(db, await tempFolder());
    await TaskRepo(db).create('Saved task');
    final path = await harness.export();

    await TaskRepo(db).create('Added after the backup');
    final preview = await harness.service.readAndCheck(path);
    await harness.service.importBackup(preview);

    final titles = [for (final r in await rowsOf(db, 'tasks')) r['title']];
    expect(titles, ['Saved task']);
  });

  test('a failure during the restore rolls back to the original data',
      () async {
    final db = await openTestDb();
    final harness = BackupHarness(db, await tempFolder());
    await TaskRepo(db).create('Saved task');
    final path = await harness.export();

    await TaskRepo(db).create('Current task');
    final before = await rowsOf(db, 'tasks');
    harness.service.testHook = (step) async {
      if (step == 'restore') throw Exception('disk full');
    };

    final preview = await harness.service.readAndCheck(path);
    await expectLater(harness.service.importBackup(preview),
        throwsA(isA<BackupException>()));
    expect(await rowsOf(db, 'tasks'), before);
    expect(harness.service.lastError.value, isNotNull);
  });

  test('a failed recovery copy stops the import before anything changes',
      () async {
    final db = await openTestDb();
    final folder = await tempFolder();
    var folderPath = folder.path;
    final harness = BackupHarness(db, folder,
        folderResolver: () async => folderPath);
    await TaskRepo(db).create('Saved task');
    final path = await harness.export();

    await TaskRepo(db).create('Current task');
    final before = await rowsOf(db, 'tasks');

    // A regular file where the backup folder should be: no recovery copy
    // can be written there.
    File('${folder.path}/blocked').writeAsStringSync('not a folder');
    folderPath = '${folder.path}/blocked/inner';

    final preview = await harness.service.readAndCheck(path);
    await expectLater(
        harness.service.importBackup(preview),
        throwsA(predicate((e) =>
            e.toString().contains('nothing was imported'))));
    expect(await rowsOf(db, 'tasks'), before);
  });

  test('reminders are reconciled with the platform alarms after import',
      () async {
    final db = await openTestDb();
    final harness = BackupHarness(db, await tempFolder());
    final reminders = ReminderRepo(db);
    final future = await reminders.create('Future', DateTime(2030, 1, 2));
    final past = await reminders.create('Past', DateTime(2000, 1, 2));
    final path = await harness.export();

    // Added after the backup: the import must remove its alarm.
    final later = await reminders.create('Added later', DateTime(2031, 1, 2));

    harness.scheduler.scheduled.clear();
    harness.scheduler.cancelled.clear();
    final preview = await harness.service.readAndCheck(path);
    await harness.service.importBackup(preview);

    expect(harness.scheduler.cancelled, contains(later.id));
    expect(harness.scheduler.scheduled, contains(future.id));
    expect(harness.scheduler.scheduled, isNot(contains(past.id)));

    final pastRow = (await db.query('reminders',
            where: 'id = ?', whereArgs: [past.id]))
        .single;
    expect(pastRow['enabled'], 0, reason: 'past reminders are never replayed');
    expect(await db.query('reminders',
            where: 'id = ?', whereArgs: [later.id]),
        isEmpty);
  });
}
