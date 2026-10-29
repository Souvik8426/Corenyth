// Desired-behavior regression probes. Intentionally red before repairs.
import 'dart:async';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/mascot/mascot_emotion.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../test/support/v2_db.dart';

import 'package:assistant/services/backup/backup_format.dart';
import 'package:assistant/ui/chat_view.dart';
import 'package:assistant/ui/mascot_emotion_scope.dart';
import 'package:flutter/material.dart';
final _now = DateTime(2099, 10, 14, 7);

/// Stand-in for the on-device model: answers plan/reply prompts with canned
/// JSON, streaming the raw output in chunks while the completion future is
/// still unresolved — the same protocol as LlamaBridge's text{id,text} events.
class _StreamingPlanner extends LlmEngine {
  /// Raw output per `${p.kind.name}:${p.user}`.
  final outputs = <String, String>{};

  /// Cumulative raw prefixes to deliver before completing, in order.
  final streamPlan = <String, List<String>>{};

  /// When set, the completion future stays unresolved until released.
  Completer<void>? gate;

  final rawEvents = <String>[];
  final prompts = <Prompt>[];

  @override
  String get name => 'qwen-standin';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}
  @override
  Future<void> cancel() async {
    gate?.complete();
  }

  @override
  Future<String> complete(Prompt p) => completeStreaming(p);

  @override
  Future<String> completeStreaming(Prompt p,
      {void Function(String text)? onText,
      void Function(String raw)? onRaw}) async {
    prompts.add(p);
    final key = '${p.kind.name}:${p.user}';
    final raw = outputs[key] ?? '{"emotion":{"mood":"calm","intensity":0.25,'
        '"confidence":0.9},"intent":"chat","reply":"Okay!"}';
    for (final part in streamPlan[key] ?? [raw]) {
      onRaw?.call(part);
      rawEvents.add(part);
    }
    await gate?.future;
    return raw;
  }
}

class _Memory extends MemoryRepo {
  _Memory(super.db);
  @override
  Future<int> add(String content,
          {String category = 'fact',
          double importance = 0.5,
          String? opId,
          String? source}) async =>
      1;
  @override
  Future<List<Memory>> search(String query, {int limit = 3}) async => [];
  @override
  Future<List<Memory>> important({int limit = 3}) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late _StreamingPlanner model;
  late AssistantSession session;

  setUp(() async {
    db = await openMigratedV2();
    model = _StreamingPlanner();
    final tasks = TaskRepo(db);
    session = AssistantSession(
      engine: model,
      tools: ToolExecutor(tasks, ReminderRepo(db), _Memory(db), NoopScheduler(),
          clock: () => _now, preferences: ReminderPreferencesRepo(db)),
      memory: _Memory(db),
      profile: ProfileRepo(db),
      taskRepo: tasks,
      conversations: ConversationRepo(db),
      pending: PendingRepo(db),
      moods: MoodRepo(db),
      conversationId: 'chat',
      clock: () => _now,
    );
    await session.start();
  });


  test('AUDIT tone survives native prompt candidate construction', () {
    final p = Prompt(PromptKind.plan, 'Hello', tone: 'professional');
    expect(p.render(), contains('Reply tone: professional'));
    expect(p.candidates().first, contains('Reply tone: professional'));
  });

  test('AUDIT version 1 backup manifest remains readable', () {
    final raw = BackupManifest(formatVersion: 1,
      createdAt: DateTime.utc(2025), counts: {}).toJson();
    final errors = <String>[];
    expect(BackupManifest.parse(raw, errors), isNotNull, reason: '$errors');
  });

  test('AUDIT split grounded number does not permanently suppress streaming', () async {
    const user = 'I feel overwhelmed by these 12 ideas';
    const prefix = '{"emotion":{"mood":"concerned","intensity":0.7,"confidence":0.9},"intent":"chat","reply":"';
    const reply = 'Those 12 ideas can wait. What feels heaviest?';
    model.outputs['plan:$user'] = '$prefix$reply"}';
    model.streamPlan['plan:$user'] = [
      '${prefix}Those 1', '$prefix$reply"}',
    ];
    final streams = <String>[];
    final answer = await session.handle(user, onStream: streams.add);
    expect(answer, contains('12'));
    expect(streams, contains(reply), reason: 'A partial numeric token must not poison the entire stream.');
  });

  for (final check in ['completion', 'before_text', 'callback']) {
    testWidgets('AUDIT mood $check follows live turn', (t) async {
      final input = TextEditingController();
      final scroll = ScrollController();
      addTearDown(input.dispose);
      addTearDown(scroll.dispose);
      final messages = [Message('user', 'I finally succeeded!')];
      const happy = MascotEmotion(MascotMood.happy, 0.8);
      final callbacks = <MascotEmotion>[];
      Widget scene(String? stream, MascotEmotion? pending) => MaterialApp(
        home: Scaffold(body: ChatView(name: 'Test', messages: List.of(messages),
          input: input, scroll: scroll, busy: stream != null, ready: true,
          onSend: () {}, streamingText: stream, pendingEmotion: pending,
          moods: const {42: happy}, onEmotionChanged: callbacks.add)));
      await t.pumpWidget(scene(null, null));
      if (check == 'before_text') {
        await t.pumpWidget(scene(null, happy));
      } else {
        await t.pumpWidget(scene('Wonderful', happy));
        expect(t.widget<MascotEmotionScope>(find.byType(MascotEmotionScope)).emotion.mood,
          MascotMood.happy);
        if (check == 'completion') {
          messages.add(Message('assistant', 'Wonderful!'));
          await t.pumpWidget(scene(null, null));
        }
      }
      if (check == 'callback') {
        await t.pump();
        expect(callbacks.map((e) => e.mood), contains(MascotMood.happy));
      } else {
        expect(t.widget<MascotEmotionScope>(find.byType(MascotEmotionScope)).emotion.mood,
          MascotMood.happy);
      }
      await t.pumpWidget(const SizedBox());
    });
  }
}
