import 'dart:async';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/mascot/mascot_emotion.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/v2_db.dart';

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

  test('chat reply streams into the live draft before completion', () async {
    const envelope = '{"emotion":{"mood":"concerned","intensity":0.7,'
        '"confidence":0.9}';
    model.outputs['plan:I feel swamped today, everything piled up'] =
        '$envelope,"intent":"chat","reply":"I hear you. What is heaviest right now?"}';
    model.streamPlan['plan:I feel swamped today, everything piled up'] = [
      envelope,
      '$envelope,"intent":"chat","reply":"I hear',
      '$envelope,"intent":"chat","reply":"I hear you. What is heaviest right now?"}',
    ];
    model.gate = Completer<void>();
    final streams = <String>[];
    final moods = <TurnMood>[];
    final done = session.handle('I feel swamped today, everything piled up',
        onStream: streams.add, onMood: moods.add);
    // The model is still generating: wait (bounded) for the turn's async
    // chain to reach it, then assert live chunks are already visible.
    for (var i = 0;
        i < 200 && (streams.length < 2 || moods.isEmpty);
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(streams.length, greaterThanOrEqualTo(2),
        reason: 'live chunks appear before the completion future resolves');
    expect(streams.last, contains('I hear you'));
    expect(moods, hasLength(1));
    expect(moods.single.emotion!.mood, MascotMood.concerned);
    expect(moods.single.turnId, session.lastOperationId);
    expect(moods.single.conversationId, 'chat');

    model.gate!.complete();
    final reply = await done;
    expect(reply, 'I hear you. What is heaviest right now?');
    expect(moods, hasLength(1),
        reason: 'exactly one mood event per turn');
    expect(session.lastTiming.containsKey('first_text'),
        isTrue, reason: 'first-visible-text latency is measured');
    expect(session.lastTiming.containsKey('mood'), isTrue);
  });

  test('a write plan never streams its follow-up; mood still arrives', () async {
    const envelope = '{"emotion":{"mood":"calm","intensity":0.3,"confidence":0.8}';
    model.outputs['plan:remind me to stretch at 9'] =
        '$envelope,"intent":"create_reminder","title":"stretch","when":"at 9",'
        '"reply":"Want a follow-up?"}';
    model.streamPlan['plan:remind me to stretch at 9'] = [
      envelope,
      '$envelope,"intent":"create_reminder","title":"stretch","when":"at 9",'
          '"reply":"Want a follow-up?"}',
    ];
    final streams = <String>[];
    final moods = <TurnMood>[];
    final reply = await session.handle('remind me to stretch at 9',
        onStream: streams.add, onMood: moods.add);
    expect(moods.single.emotion!.mood, MascotMood.calm);
    expect(
        streams.where((s) => s.isNotEmpty),
        isEmpty,
        reason: 'the follow-up of a write is appended after the app\'s own '
            'exact confirmation; it is never streamed as the answer');
    expect(reply, contains('9:00 AM'));
  });

  test('an unverified action claim is never shown, streamed or final',
      () async {
    const envelope = '{"emotion":{"mood":"happy","intensity":0.6,"confidence":0.7}';
    model.outputs['plan:hi'] =
        '$envelope,"intent":"chat","reply":"I have created that task for you!"}';
    model.streamPlan['plan:hi'] = [
      '$envelope,"intent":"chat","reply":"I have created that task for you!"}',
    ];
    // The plan's reply fails safeReply, so the session falls back to a
    // grounded converse call; give it a safe answer.
    model.outputs['reply:hi'] = '{"emotion":{"mood":"calm","intensity":0.3,'
        '"confidence":0.8},"type":"respond","text":"Hi! What can I do for you?"}';
    model.streamPlan['reply:hi'] = [
      '{"emotion":{"mood":"calm","intensity":0.3,"confidence":0.8},'
          '"type":"respond","text":"Hi! What can I do for you?"}',
    ];
    final streams = <String>[];
    final reply = await session.handle('hi', onStream: streams.add);
    expect(reply, 'Hi! What can I do for you?');
    expect(
        streams.any((s) => s.contains('created')),
        isFalse,
        reason: 'the claim never reaches the live draft');
    expect(reply.contains('created'), isFalse);
  });

  test('the turn\'s mood is persisted against its user message row',
      () async {
    model.outputs['plan:I passed!'] =
        '{"emotion":{"mood":"excited","intensity":0.9,"confidence":0.85},'
        '"intent":"chat","reply":"Congratulations! What was it?"}';
    final moods = <TurnMood>[];
    await session.handle('I passed!', onMood: moods.add);
    final rows = await MoodRepo(db).rowsForChat('chat');
    expect(rows, hasLength(1));
    final row = rows.values.single;
    expect(row['mood'], 'excited');
    expect(row['intensity'], 0.9);
    expect(row['message_id'], moods.single.messageRowId);
    expect(moods.single.messageRowId, isNotNull);
    final stored = TurnMood.fromDbRow(row, conversationId: 'chat')!;
    expect(stored.emotion!.mood, MascotMood.excited);
  });

  test('no model / no envelope leaves unknown provenance, never a guess',
      () async {
    final bare = AssistantSession(
      engine: RuleEngine(),
      tools: session.tools,
      memory: _Memory(db),
      profile: ProfileRepo(db),
      taskRepo: TaskRepo(db),
      conversations: ConversationRepo(db),
      conversationId: 'chat2',
    );
    await bare.start();
    final moods = <TurnMood>[];
    await bare.handle('I feel happy', onMood: moods.add);
    expect(moods, isEmpty);
    expect(bare.lastDiagnostics['mood'], isNull,
        reason: 'no model ran, so no mood diagnostic is claimed either');
  });

  test('RuleEngine fallback never streams (buffered rules reply)', () async {
    final bare = AssistantSession(
      engine: RuleEngine(),
      tools: session.tools,
      memory: _Memory(db),
      profile: ProfileRepo(db),
      taskRepo: TaskRepo(db),
      conversations: ConversationRepo(db),
      conversationId: 'chat2',
    );
    await bare.start();
    final streams = <String>[];
    await bare.handle('remind me to stretch at 9', onStream: streams.add);
    expect(streams, isEmpty,
        reason: 'without the model there is no stream; the reply is final');
  });
}
