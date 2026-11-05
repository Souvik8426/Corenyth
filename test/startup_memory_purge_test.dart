import 'dart:io';

import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/app_services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

// Plan 1.2: the guarded startup step `purge expired memories` in
// AppServices.open. Exercised through the real open() with a temp database.

const _nativeChannel = MethodChannel('assistant/native');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late String dbPath;
  final logs = <String>[];
  final originalDebugPrint = debugPrint;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dir = await Directory.systemTemp.createTemp('startup-purge-');
    dbPath = '${dir.path}/$dbFileName';
    // Keep the FFI database path inside the temp dir, not the repo's .dart_tool.
    (databaseFactory as dynamic).setDatabasesPathOrNull(dir.path);
    final models = Directory('${dir.path}/models')..createSync();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeChannel, (call) async {
      if (call.method == 'modelsDir') {
        return {'path': models.path, 'granted': true};
      }
      return null;
    });
    logs.clear();
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
  });

  tearDown(() async {
    debugPrint = originalDebugPrint;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_nativeChannel, null);
    await dir.delete(recursive: true);
  });

  Future<int> insertMemory(Database db, String content,
      {required String status,
      int? expiresAt,
      int? deletedAt,
      required int now}) {
    return db.insert('memories', {
      'content': content,
      'category': 'fact',
      'importance': 0.5,
      'created_at': now,
      'updated_at': now,
      'status': status,
      'expires_at': expiresAt,
      'deleted_at': deletedAt,
    });
  }

  Future<Map<String, Object?>?> memoryRow(Database db, int id) async {
    final rows = await db.query('memories',
        columns: ['status', 'deleted_at', 'expires_at'],
        where: 'id = ?',
        whereArgs: [id]);
    return rows.isEmpty ? null : rows.single;
  }

  const day = Duration(days: 1);

  test('startup runs the purge step: expired is retired, 30-day deletes purged',
      () async {
    final seed = await openAppDb(path: dbPath);
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = await insertMemory(seed, 'Expired parking pass',
        status: 'active', expiresAt: now - day.inMilliseconds, now: now);
    final oldDeleted = await insertMemory(seed, 'Long forgotten address',
        status: 'deleted',
        deletedAt: now - const Duration(days: 31).inMilliseconds,
        now: now);
    final recentDeleted = await insertMemory(seed, 'Recently deleted order',
        status: 'deleted', deletedAt: now - day.inMilliseconds, now: now);
    final live = await insertMemory(seed, 'I work as a designer',
        status: 'active', now: now);
    await seed.close();

    final s = await AppServices.open();
    addTearDown(() => s.db.close());

    expect(logs.any((l) => l.startsWith('startup: purge expired memories ')),
        isTrue,
        reason: 'the purge step must be attempted during startup');

    // Expired active row is soft-deleted by the system, not purged yet.
    final retired = await memoryRow(s.db, expired);
    expect(retired?['status'], 'deleted');
    expect(retired?['deleted_at'], isNotNull);
    final history = await s.db.query('memory_history',
        where: 'memory_id = ? AND event = ?', whereArgs: [expired, 'delete']);
    expect(history.single['actor'], 'system');

    // 31-day-old deletion is purged; recent deletion and live fact stay.
    expect(await memoryRow(s.db, oldDeleted), isNull);
    expect((await memoryRow(s.db, recentDeleted))?['status'], 'deleted');
    expect((await memoryRow(s.db, live))?['status'], 'active');

    // Later startup steps still ran.
    expect(await s.db.query('chats', where: "id = 'main'"), isNotEmpty);
  });

  test('a failing purge does not block later startup recovery', () async {
    final seed = await openAppDb(path: dbPath);
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = await insertMemory(seed, 'Expired gym pass',
        status: 'active', expiresAt: now - day.inMilliseconds, now: now);
    // The purge retires the expired row and writes its history; with the
    // history table gone that transaction must fail.
    await seed.execute('DROP TABLE memory_history');
    await seed.close();

    final s = await AppServices.open();
    addTearDown(() => s.db.close());

    expect(logs.any((l) => l.startsWith('startup: purge expired memories ')),
        isTrue,
        reason: 'the purge step must be attempted during startup');
    // Rolled back: the failed purge left the row untouched.
    expect((await memoryRow(s.db, expired))?['status'], 'active');
    expect(s.memoryCleanupIssue.value, contains('Erasure has not been confirmed'));
    // Startup continued past the failed step.
    expect(await s.db.query('chats', where: "id = 'main'"), isNotEmpty);
  });

  test('startup exposes legacy cleanup block, retires expiry and recomputes status after restart', () async {
    final seed = await openAppDb(path: dbPath);
    final now = DateTime.now().millisecondsSinceEpoch;
    final expired = await insertMemory(seed, 'Expired gym pass',
        status: 'active', expiresAt: now - day.inMilliseconds, now: now);
    final oldDeleted = await insertMemory(seed, 'Old private address',
        status: 'deleted', deletedAt: now - const Duration(days: 31).inMilliseconds, now: now);
    await seed.insert('memory_history', {
      'memory_id': 99, 'event': 'supersede',
      'old_content': 'Legacy owner text', 'new_content': 'Unattributed private copy',
      'actor': 'user', 'created_at': now,
    });
    final legacy = await seed.query('memory_history');
    await seed.close();

    var s = await AppServices.open();
    try {
      expect(s.lastMemoryCleanup?.retired, 1);
      expect(s.lastMemoryCleanup?.purged, 0);
      expect(s.lastMemoryCleanup?.blocked, isA<MemoryPrivacyBlocked>());
      expect(s.memoryCleanupIssue.value, contains(MemoryPrivacyBlocked.explanation));
      expect(s.memoryCleanupIssue.value, contains('1 expired memory moved to Recently deleted'));
      expect((await memoryRow(s.db, expired))?['status'], 'deleted');
      expect((await memoryRow(s.db, oldDeleted))?['status'], 'deleted');
      expect(await s.db.query('memory_history', where: "event = 'supersede'"), legacy);
      expect(await s.db.query('chats', where: "id = 'main'"), isNotEmpty);
    } finally {
      await s.db.close();
    }

    s = await AppServices.open();
    try {
      expect(s.memoryCleanupIssue.value, contains(MemoryPrivacyBlocked.explanation));
      expect(s.lastMemoryCleanup?.retired, 0, reason: 'previous retirement is committed');
      expect(s.lastMemoryCleanup?.purged, 0);
      expect((await s.memory.deleted()).map((m) => m.id), containsAll([expired, oldDeleted]));
      expect((await s.memory.restore(expired)).status, RestoreStatus.restored);
      expect((await memoryRow(s.db, expired))?['expires_at'], isNull);
      expect(await s.memory.legacyErasureBlocked(), isTrue);
      expect(await s.db.query('memory_history', where: "event = 'supersede'"), legacy);
    } finally {
      await s.db.close();
    }
  });

  test('startup reports retained legacy copies even with no purge targets', () async {
    final seed = await openAppDb(path: dbPath);
    await seed.insert('memory_history', {
      'memory_id': 99, 'event': 'supersede', 'new_content': 'Retained copy',
      'actor': 'user', 'created_at': 1,
    });
    await seed.close();
    final s = await AppServices.open();
    addTearDown(s.db.close);
    expect(s.lastMemoryCleanup?.purged, 0);
    expect(s.memoryCleanupIssue.value, contains(MemoryPrivacyBlocked.explanation));
  });

}
