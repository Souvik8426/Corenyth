import 'package:assistant/data/repos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/backup_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;

  setUp(() async {
    db = await openTestDb();
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  for (final kind in ['task', 'reminder']) {
    test('concurrent recovery retries create one $kind row', () async {
      final id = 'retry-$kind';
      final journal = OperationJournal(db);
      await journal.begin(id, 'main', 'hash:$id');
      await journal.mark(id, OperationJournal.executing,
          action: '{"tool":"create_$kind"}');

      Future<void> recover() async {
        await OperationJournal(db).recoverStale(olderThan: Duration.zero);
        if (kind == 'task') {
          await TaskRepo(db).create('Retry task', opId: id);
        } else {
          await ReminderRepo(db).create('Retry reminder', DateTime(2030), opId: id);
        }
      }

      await Future.wait([recover(), recover()]);
      final table = kind == 'task' ? 'tasks' : 'reminders';
      expect(await db.query(table, where: 'op_id = ?', whereArgs: [id]),
          hasLength(1));
    });
  }
}
