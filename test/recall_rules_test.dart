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
  late ConversationRepo conversations;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('recall-rules-');
    db = await openAppDb(path: '${dir.path}/test.db');
    conversations = ConversationRepo(db);
    addTearDown(() async {
      await db.close();
      await dir.delete(recursive: true);
    });
  });

  Future<AssistantSession> open() async {
    final tasks = TaskRepo(db);
    final memory = MemoryRepo(db);
    final now = DateTime(2026, 10, 19, 10);
    final s = AssistantSession(
      engine: _Offline(),
      tools: ToolExecutor(tasks, ReminderRepo(db), memory, NoopScheduler(),
          clock: () => now, preferences: ReminderPreferencesRepo(db)),
      memory: memory,
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: conversations,
      pending: PendingRepo(db),
      conversationId: 'chat-b',
      clock: () => now,
    );
    await s.start();
    return s;
  }

  test('"do you remember where I said" answers from an earlier chat', () async {
    await conversations.add(
        'chat-a', 'user', 'parked on level 3, spot B12 at the mall');
    final s = await open();
    expect(
        await s.handle('do you remember where I said I parked?'), contains('B12'));
  });

  test('the same question with nothing said earlier does not invent an answer',
      () async {
    final s = await open();
    expect(await s.handle('do you remember where I said I parked?'),
        contains('nothing stored'));
  });
}
