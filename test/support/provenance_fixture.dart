import 'package:sqflite/sqflite.dart';

/// Strip the new schema only when building an older-schema migration fixture.
Future<void> removeV13(Database db) async {
  for (final trigger in [
    'operation_source_insert',
    'operation_source_update',
    'operation_source_identity',
    'conversation_source_identity',
    'memory_write_source_verified'
  ]) {
    await db.execute('DROP TRIGGER $trigger');
  }
  await db.execute('DROP TABLE memory_write_sources');
  await db.execute('DROP INDEX operations_source');
  await db.execute('ALTER TABLE operations DROP COLUMN source_message_id');
}
