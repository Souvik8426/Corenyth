import 'dart:async';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/mascot/mascot_emotion.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/v2_db.dart';

final _now = DateTime(2099, 10, 14, 7);
const _timeout = Duration(seconds: 5);
const _mood = '{"emotion":{"mood":"happy","intensity":0.8,"confidence":0.9}}';
const _chat = '{"intent":"chat","reply":"Hello!"}';

class _HeldEngine extends LlmEngine {
  final optionalStarted = Completer<void>();
  final optionalGate = Completer<void>();
  final cancelStarted = Completer<void>();
  void Function(String)? optionalRaw;
  bool stopOptional = true;
  bool failCancel = false;
  int cancels = 0;

  @override
  String get name => 'held-lifecycle';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}
  @override
  Future<String> complete(Prompt p) async => p.user == 'add task buy milk'
      ? '{"intent":"create_task","title":"buy milk"}'
      : _chat;
  @override
  Future<String> completeOptional(Prompt p,
      {void Function(String raw)? onRaw}) async {
    optionalRaw = onRaw;
    optionalStarted.complete();
    await optionalGate.future;
    onRaw?.call(_mood); // Deliberately delivers even after cancellation.
    return _mood;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (!cancelStarted.isCompleted) cancelStarted.complete();
    optionalRaw?.call(_mood); // Also exercise callbacks inline with cancel.
    if (stopOptional && !optionalGate.isCompleted) optionalGate.complete();
    if (failCancel) throw StateError('cancel failed');
  }
}

class _HeldProfile extends ProfileRepo {
  _HeldProfile(super.db);
  Completer<UserProfile?>? hold;
  final preparationStarted = Completer<void>();

  @override
  Future<UserProfile?> get() {
    final gate = hold;
    if (gate == null) return super.get();
    hold = null;
    preparationStarted.complete();
    return gate.future;
  }
}

class _CountingMoods extends MoodRepo {
  _CountingMoods(super.db);
  int saves = 0;

  @override
  Future<void> save({
    required int messageId,
    required String chatId,
    required String source,
    String? mood,
    double intensity = 0.25,
    double? confidence,
  }) {
    saves++;
    return super.save(
        messageId: messageId,
        chatId: chatId,
        source: source,
        mood: mood,
        intensity: intensity,
        confidence: confidence);
  }
}

class _HeldTools extends ToolExecutor {
  _HeldTools(super.tasks, super.reminders, super.memory, super.scheduler)
      : super(clock: () => _now);
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<ExecutionReceipt> run(ToolCall c,
      {String? operationId, bool recovering = false, MemoryWriteSource? memorySource}) async {
    if (c.tool == 'create_task') {
      started.complete();
      await release.future;
    }
    return super.run(c, operationId: operationId, recovering: recovering, memorySource: memorySource);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _HeldEngine engine;
  late AssistantSession session;
  late _HeldProfile profile;
  late _CountingMoods moods;
  late TaskRepo tasks;
  late ConversationRepo conversations;
  late _HeldTools tools;
  final events = <TurnMood>[];

  setUp(() async {
    final db = await openMigratedV2();
    engine = _HeldEngine();
    tasks = TaskRepo(db);
    conversations = ConversationRepo(db);
    profile = _HeldProfile(db);
    moods = _CountingMoods(db);
    final memory = MemoryRepo(db);
    tools = _HeldTools(tasks, ReminderRepo(db), memory, NoopScheduler());
    session = AssistantSession(
      engine: engine,
      tools: tools,
      memory: memory,
      profile: profile,
      taskRepo: tasks,
      conversations: conversations,
      pending: PendingRepo(db),
      moods: moods,
      conversationId: 'lifecycle',
      clock: () => _now,
    );
    events.clear();
    await session.start();
    addTearDown(() async {
      if (!engine.optionalGate.isCompleted) engine.optionalGate.complete();
      if (!tools.release.isCompleted) tools.release.complete();
      await session.close();
      await session.lastOptionalMoodJob;
    });
  });

  Future<void> startOptional() async {
    await tasks.create('buy milk');
    final reply =
        await session.handle('did I add buy milk?', onMood: events.add);
    expect(reply, contains('buy milk'));
    await engine.optionalStarted.future.timeout(_timeout);
    expect(session.current, SessionState.listening);
    expect(engine.optionalGate.isCompleted, isFalse);
  }

  Future<void> expectNoMood(Map<String, String> diagnostics) async {
    expect(events, isEmpty);
    expect(moods.saves, 0);
    expect(await moods.rowsForChat(session.id), isEmpty);
    expect(session.lastDiagnostics, diagnostics);
  }

  test('cancel after foreground settlement stops held optional mood', () async {
    await startOptional();
    final diagnostics = session.lastDiagnostics;
    final transcript = await conversations.recent(session.id);
    await session.cancel().timeout(_timeout);
    expect(engine.cancels, 1);
    expect(engine.optionalGate.isCompleted, isTrue);
    await session.lastOptionalMoodJob!.timeout(_timeout);
    await expectNoMood(diagnostics);
    expect((await tasks.list()).single.title, 'buy milk');
    expect((await conversations.recent(session.id)).map((m) => m.content),
        transcript.map((m) => m.content));
  });

  test('late optional output stays stale after cancel and a new turn',
      () async {
    engine.stopOptional = false;
    await startOptional();
    final job = session.lastOptionalMoodJob!;
    await session.cancel().timeout(_timeout);
    expect(engine.cancels, 1);
    expect(engine.optionalGate.isCompleted, isFalse,
        reason: 'cancel must not wait for uncooperative optional work');
    // The optional generation is still running and never confirms its
    // cancellation: the scheduler refuses to overlap it with a foreground
    // generation, so after its bounded wait this turn falls back to rules.
    expect(await session.handle('hi').timeout(_timeout), isNot('Hello!'));
    expect(session.lastDiagnostics['fallback'], 'model_cancel_timedOut');
    final diagnostics = session.lastDiagnostics;
    engine.optionalGate.complete();
    await job.timeout(_timeout);
    await expectNoMood(diagnostics);
    // Once that generation has really ended, the model is used again.
    expect(await session.handle('hi').timeout(_timeout), 'Hello!');
  });

  test('cancel invalidates optional preparation before it can enqueue',
      () async {
    final preparation = Completer<UserProfile?>();
    addTearDown(() {
      if (!preparation.isCompleted) preparation.complete(null);
    });
    await tasks.create('buy milk');
    await session.handle('did I add buy milk?', onMood: events.add,
        onText: (_) {
      profile.hold = preparation;
    });
    await profile.preparationStarted.future.timeout(_timeout);
    final job = session.lastOptionalMoodJob!;
    await session.cancel().timeout(_timeout);
    expect(await session.handle('hi').timeout(_timeout), 'Hello!');
    final diagnostics = session.lastDiagnostics;
    preparation.complete(null);
    await job.timeout(_timeout);
    expect(engine.optionalStarted.isCompleted, isFalse);
    await expectNoMood(diagnostics);
  });

  test('close stops held optional work and remains idempotent', () async {
    await startOptional();
    final diagnostics = session.lastDiagnostics;
    final closing = session.close();
    expect(await closing.timeout(_timeout), isEmpty);
    expect(await session.close(), isEmpty);
    expect(engine.cancels, 1);
    expect(engine.optionalGate.isCompleted, isTrue);
    expect(session.current, SessionState.idle);
    await session.lastOptionalMoodJob!.timeout(_timeout);
    await expectNoMood(diagnostics);
  });

  test('engine cancellation errors still suppress late optional output',
      () async {
    engine
      ..stopOptional = false
      ..failCancel = true;
    await startOptional();
    final diagnostics = session.lastDiagnostics;
    await session.cancel().timeout(_timeout);
    expect(engine.cancels, 1);
    engine.optionalGate.complete();
    await session.lastOptionalMoodJob!.timeout(_timeout);
    await expectNoMood(diagnostics);
  });

  test('cancel before commit still waits for settlement and writes nothing',
      () async {
    final beforeCommit = Completer<void>();
    final release = Completer<void>();
    addTearDown(() {
      if (!release.isCompleted) release.complete();
    });
    session.onBeforeCommit = () {
      beforeCommit.complete();
      return release.future;
    };
    final turn = session.handle('add task buy milk', onMood: events.add);
    await beforeCommit.future.timeout(_timeout);
    var settled = false;
    final cancelling = session.cancel().then((_) => settled = true);
    await engine.cancelStarted.future.timeout(_timeout);
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    release.complete();
    await cancelling.timeout(_timeout);
    expect(await turn.timeout(_timeout), isEmpty);
    expect(await tasks.list(), isEmpty);
    expect(events, isEmpty);
    expect(session.current, SessionState.listening);
    expect(engine.optionalStarted.isCompleted, isFalse);
  });

  test('cancel lets an action already running finish and reports its receipt',
      () async {
    final turn = session.handle('add task buy milk');
    await tools.started.future.timeout(_timeout);
    var settled = false;
    final cancelling = session.cancel().then((_) => settled = true);
    await engine.cancelStarted.future.timeout(_timeout);
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    tools.release.complete();
    await cancelling.timeout(_timeout);
    expect(await turn.timeout(_timeout), contains('buy milk'));
    expect((await tasks.list()).single.title, 'buy milk');
    expect(session.current, SessionState.listening);
    expect(engine.optionalStarted.isCompleted, isFalse);
  });

  test('close sends native optional cancellation before switching sessions',
      () async {
    await session.close();
    const channel = MethodChannel('assistant/llm');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final optionalStarted = Completer<void>();
    final pending = Completer<String>();
    final calls = <String>[];
    int? optionalId;

    Future<void> emit(int id) => messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('text', {'id': id, 'text': _mood})),
        (_) {});

    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'load') return true;
      if (call.method == 'generate') {
        final args = call.arguments as Map;
        if (args['maxTokens'] == 32) {
          calls.add('optional');
          optionalId = args['id'] as int;
          optionalStarted.complete();
          return pending.future;
        }
        calls.add('foreground');
        expect(pending.isCompleted, isTrue,
            reason: 'the previous session must stop its native job first');
        return _chat;
      }
      if (call.method == 'cancel') {
        expect(call.arguments['id'], optionalId);
        calls.add('cancel');
        await emit(optionalId!);
        pending.completeError(PlatformException(code: 'llama_cancelled'));
      } else {
        fail('unexpected native call: ${call.method}');
      }
      return null;
    });
    addTearDown(() async {
      if (!pending.isCompleted) pending.complete(_mood);
      await session.close();
      messenger.setMockMethodCallHandler(channel, null);
    });

    AssistantSession newSession(String id) => AssistantSession(
          engine: LlamaChannelEngine('model'),
          tools: tools,
          memory: tools.memory,
          profile: profile,
          taskRepo: tasks,
          conversations: conversations,
          moods: moods,
          conversationId: id,
          clock: () => _now,
        );

    session = newSession('old-chat');
    await session.start();
    await tasks.create('buy milk');
    await session.handle('did I add buy milk?', onMood: events.add);
    await optionalStarted.future.timeout(_timeout);
    final job = session.lastOptionalMoodJob!;
    final diagnostics = session.lastDiagnostics;
    await session.close().timeout(_timeout);
    expect(calls, ['optional', 'cancel']);
    await job.timeout(_timeout);
    await emit(optionalId!); // Late native output must not reach the old chat.
    await expectNoMood(diagnostics);

    session = newSession('new-chat');
    await session.start();
    expect(await session.handle('hi').timeout(_timeout), 'Hello!');
    expect(calls, ['optional', 'cancel', 'foreground']);
  });
}
