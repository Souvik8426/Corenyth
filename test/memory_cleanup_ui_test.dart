import 'dart:async';
import 'dart:io';

import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/main.dart';
import 'package:assistant/services/app_services.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openDb() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = await Directory.systemTemp.createTemp('memory-cleanup-ui-');
  final db = await openAppDb(path: '${dir.path}/test.db');
  addTearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });
  return db;
}

/// Gates the actual repository operation before it acquires the DB queue.
/// Reads remain usable while we exercise timeout, refresh and page re-entry.
class _GatedMemories extends MemoryRepo {
  _GatedMemories(super.db);

  Completer<void>? gate;
  bool fail = false;
  int calls = 0;
  int active = 0;
  int maxActive = 0;

  @override
  Future<MemoryCleanupResult> cleanupDeleted({
    Duration olderThan = const Duration(days: 30),
  }) async {
    calls++;
    active++;
    if (active > maxActive) maxActive = active;
    try {
      await gate?.future;
      if (fail) throw StateError('PRIVATE_CLEANUP_ERROR');
      return await super.cleanupDeleted(olderThan: olderThan);
    } finally {
      active--;
    }
  }
}

Future<void> _settle(WidgetTester tester) async {
  // FFI replies run outside the widget test's fake clock.
  for (var i = 0; i < 15; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await _settle(tester);
}

Future<void> _openHome(WidgetTester tester, AppServices services) async {
  await tester.pumpWidget(MaterialApp(home: AssistantHome(services)));
  await _settle(tester);
  await _tap(
      tester,
      find.descendant(
          of: find.byType(NavigationRail), matching: find.text('Memories')));
}

String _warning(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('memory-cleanup-issue'))).data!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const native = MethodChannel('assistant/native');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            native,
            (call) async => call.method == 'modelsDir'
                ? {'path': '/nonexistent', 'granted': true}
                : null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(native, null);
  });

  void wide(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets(
      'real purge failure reaches UI through AppServices and main, '
      'with readable nonlegacy history and no private error text',
      (tester) async {
    wide(tester);
    late AppServices services;
    late int retained;
    late int expired;
    await tester.runAsync(() async {
      final db = await _openDb();
      services = AppServices(db, NoopScheduler(), '/nonexistent/model.gguf');
      expired = await services.memory.add('Recoverable expired fact');
      await db.update('memories', {'expires_at': 1},
          where: 'id = ?', whereArgs: [expired]);
      retained = await services.memory.add('PRIVATE_RETAINED_MEMORY');
      await services.memory.delete(retained);
      await db.update(
          'memories',
          {
            'deleted_at': DateTime.now()
                .subtract(const Duration(days: 31))
                .millisecondsSinceEpoch,
          },
          where: 'id = ?',
          whereArgs: [retained]);
      await db.execute('''
        CREATE TRIGGER fail_memory_purge BEFORE DELETE ON memories
        BEGIN SELECT RAISE(ABORT, 'PRIVATE_SQL_ERROR'); END
      ''');
      // The startup cleanup outcome must survive navigation into Memories.
      await services.cleanupMemories();
      expect(await services.memory.legacyErasureBlocked(), isFalse);
    });

    await _openHome(tester, services);
    expect(_warning(tester), contains('Memory cleanup did not finish'));
    expect(_warning(tester), contains('Erasure has not been confirmed'));
    expect(find.textContaining('PRIVATE_'), findsNothing);
    expect(services.lastMemoryCleanup, isNull);
    expect(find.byKey(const Key('memory-privacy-issue')), findsNothing);
    await tester.runAsync(() async {
      expect(
          await services.db
              .query('memories', where: 'id = ?', whereArgs: [retained]),
          hasLength(1));
      expect(await services.db.query('memory_history'), isNotEmpty);
      expect(
          (await services.memory.deleted()).map((m) => m.id), contains(expired),
          reason: 'retirement committed before the purge stage failed');
      await services.db.execute('DROP TRIGGER fail_memory_purge');
    });

    await _tap(tester, find.byTooltip('Refresh context'));
    expect(find.byKey(const Key('memory-cleanup-issue')), findsNothing);
    expect(services.lastMemoryCleanup?.purged, 1);
    await tester.runAsync(() async {
      expect(
          await services.db
              .query('memories', where: 'id = ?', whereArgs: [retained]),
          isEmpty);
    });
    await tester.pumpWidget(const SizedBox());
    services.memoryCleanupIssue.value = 'Cleanup after page disposal';
    services.memoryCleanupChanged.value++;
    expect(tester.takeException(), isNull);
  });

  for (final legacyBlocked in [false, true]) {
    for (final refresh in ['page refresh', 'app resume']) {
      testWidgets(
          'in-session expiry via $refresh becomes restorable '
          '(legacy blocked: $legacyBlocked)', (tester) async {
        wide(tester);
        var now = DateTime.utc(2026, 10, 31, 12);
        late AppServices services;
        late int id;
        late List<Map<String, Object?>> legacy;
        await tester.runAsync(() async {
          final db = await _openDb();
          final memory = MemoryRepo(db, clock: () => now);
          services = AppServices(db, NoopScheduler(), '/nonexistent/model.gguf',
              memoryRepo: memory);
          id = await memory.add('Recoverable temporary fact');
          await db.update(
              'memories',
              {
                'expires_at':
                    now.add(const Duration(minutes: 1)).millisecondsSinceEpoch,
              },
              where: 'id = ?',
              whereArgs: [id]);
          if (legacyBlocked) {
            final old = await memory.add('Retained old deletion');
            await memory.delete(old);
            await db.update(
                'memories',
                {
                  'deleted_at': now
                      .subtract(const Duration(days: 31))
                      .millisecondsSinceEpoch,
                },
                where: 'id = ?',
                whereArgs: [old]);
            await db.insert('memory_history', {
              'memory_id': 999,
              'event': 'supersede',
              'new_content': 'PRIVATE_LEGACY_COPY',
              'actor': 'user',
              'created_at': now.millisecondsSinceEpoch,
            });
          }
          legacy =
              await db.query('memory_history', where: "event = 'supersede'");
        });

        await _openHome(tester, services);
        expect(find.text('Recoverable temporary fact'), findsOneWidget);
        now = now.add(const Duration(minutes: 2));
        if (refresh == 'page refresh') {
          await _tap(tester, find.byTooltip('Refresh context'));
        } else {
          for (final state in [
            AppLifecycleState.inactive,
            AppLifecycleState.hidden,
            AppLifecycleState.paused,
            AppLifecycleState.hidden,
            AppLifecycleState.inactive,
            AppLifecycleState.resumed,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
          await _settle(tester);
        }
        expect(find.text('Recoverable temporary fact'), findsNothing);
        await tester.runAsync(() async {
          final row = (await services.db
                  .query('memories', where: 'id = ?', whereArgs: [id]))
              .single;
          expect(row['status'], 'deleted');
          expect(row['deleted_at'], now.millisecondsSinceEpoch);
          final history = await services.db.query('memory_history',
              where: "memory_id = ? AND event = 'delete'", whereArgs: [id]);
          expect(history, hasLength(1));
          expect(history.single['actor'], 'system');
        });
        if (legacyBlocked) {
          expect(_warning(tester), contains(MemoryPrivacyBlocked.explanation));
          expect(_warning(tester), isNot(contains('PRIVATE_LEGACY_COPY')));
          expect(services.lastMemoryCleanup?.purged, 0);
        }
        await _tap(tester, find.text('Recently deleted'));
        final row = find.ancestor(
            of: find.text('Recoverable temporary fact'),
            matching: find.byType(ListTile));
        expect(row, findsOneWidget);
        await _tap(
            tester, find.descendant(of: row, matching: find.text('Restore')));
        await tester.runAsync(() async {
          final restored = (await services.db
                  .query('memories', where: 'id = ?', whereArgs: [id]))
              .single;
          expect(restored['status'], 'active');
          expect(restored['expires_at'], isNull);
          expect((await services.memory.all()).map((m) => m.id), contains(id));
          expect((await services.memory.search('Recoverable')).map((m) => m.id),
              contains(id));
          expect(
              await services.db
                  .query('memory_history', where: "event = 'supersede'"),
              legacy);
        });
        expect(find.text('Recoverable temporary fact'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final lateFailure in [false, true]) {
    testWidgets(
        'timeout, refresh and page re-entry share actual cleanup; '
        'late failure: $lateFailure', (tester) async {
      wide(tester);
      late AppServices services;
      late _GatedMemories memory;
      late int id;
      final gate = Completer<void>();
      await tester.runAsync(() async {
        final db = await _openDb();
        memory = _GatedMemories(db)
          ..gate = gate
          ..fail = lateFailure;
        services = AppServices(db, NoopScheduler(), '/nonexistent/model.gguf',
            memoryRepo: memory,
            memoryCleanupTimeout: const Duration(seconds: 2));
        id = await memory.add('Fact expiring while cleanup waits');
        await db.update('memories', {'expires_at': 1},
            where: 'id = ?', whereArgs: [id]);
      });
      final first = services.cleanupMemories();
      expect(identical(first, services.cleanupMemories()), isTrue);
      await _openHome(tester, services);
      expect(find.byTooltip('Refresh context'), findsOneWidget);
      expect(find.text('No memories yet'), findsOneWidget,
          reason: 'a pending cleanup must not hold page loading');
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      await first;
      expect(_warning(tester), contains('taking longer than expected'));
      expect(services.lastMemoryCleanup, isNull);
      expect(identical(first, services.cleanupMemories()), isTrue);
      await _tap(tester, find.byTooltip('Refresh context'));
      expect(_warning(tester), contains('Erasure has not been confirmed'));
      expect(memory.calls, 1);

      await tester.pumpWidget(const SizedBox());
      await _openHome(tester, services);
      expect(_warning(tester), contains('taking longer than expected'));
      await _tap(tester, find.text('Recently deleted'));
      expect(find.text('No deleted memories'), findsOneWidget);
      expect(memory.calls, 1);
      await tester.runAsync(() async => gate.complete());
      await _settle(tester);
      expect(services.memoryCleanupChanged.value, 1);
      expect(memory.maxActive, 1);
      if (lateFailure) {
        expect(_warning(tester), contains('Memory cleanup did not finish'));
        expect(_warning(tester), isNot(contains('PRIVATE_CLEANUP_ERROR')));
        expect(services.lastMemoryCleanup, isNull);
        memory.fail = false;
        await _tap(tester, find.byTooltip('Refresh context'));
        expect(memory.calls, 2);
      }
      expect(find.byKey(const Key('memory-cleanup-issue')), findsNothing);
      expect(services.lastMemoryCleanup?.retired, 1);
      expect(services.lastMemoryCleanup?.purged, 0);
      expect(find.text('Fact expiring while cleanup waits'), findsOneWidget,
          reason: 'late settlement refreshes the already-open deleted list');
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  }
}
