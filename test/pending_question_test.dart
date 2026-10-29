import 'dart:io';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/db.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// An engine that is not available, so the deterministic rules answer.
class _Offline extends LlmEngine {
  @override
  String get name => 'offline';
  @override
  Future<bool> load() async => false;
  @override
  Future<void> unload() async {}
  @override
  Future<String> complete(Prompt p) async => '';
  @override
  Future<String> completeStreaming(Prompt p,
          {void Function(String text)? onText,
          void Function(String raw)? onRaw}) async =>
      '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late TaskRepo tasks;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('pending-question-');
    db = await openAppDb(path: '${dir.path}/test.db');
    tasks = TaskRepo(db);
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
  });

  Future<AssistantSession> open(DateTime now) async {
    final memory = MemoryRepo(db);
    final s = AssistantSession(
      engine: _Offline(),
      tools: ToolExecutor(tasks, ReminderRepo(db), memory, NoopScheduler(),
          clock: () => now, preferences: ReminderPreferencesRepo(db)),
      memory: memory,
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      pending: PendingRepo(db),
      conversationId: 'chat',
      clock: () => now,
    );
    await s.start();
    return s;
  }

  test(
      'a question while a time is pending is answered, and the time still works',
      () async {
    final s = await open(DateTime(2026, 10, 19, 8));
    expect(await s.handle('Meeting in 10 minutes at 9'),
        contains('disagree'));
    final answer = await s.handle('do I have anything after lunch today?');
    expect(answer, isNot(contains('not sure')));
    expect(answer, contains('Nothing due in that window.'));
    expect(await tasks.list(), isEmpty);

    await s.handle('9am');
    final saved = await tasks.list();
    expect(saved.single.title, contains('Meeting'));
  });

  test('an empty overdue list says nothing is overdue', () async {
    final s = await open(DateTime(2026, 10, 19, 8));
    expect(await s.handle('what is overdue?'), contains('Nothing overdue.'));
  });

  test('an empty pending list says there are no pending tasks', () async {
    final s = await open(DateTime(2026, 10, 19, 8));
    expect(await s.handle('anything left?'), contains('No pending tasks.'));
  });
}
