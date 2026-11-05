import 'dart:async';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/v2_db.dart';

final _now = DateTime(2099, 10, 14, 7);
const _reply = '{"intent":"chat","reply":"Hello!"}';
const _rawMood = '{"emotion":{"mood":"calm","intensity":0.3,'
    '"confidence":0.9},"type":"respond","text":"Hello!"}';
const _timeout = Duration(seconds: 5);

class _DefaultEngine extends LlmEngine {
  final calls = <String>[];

  @override
  String get name => 'preemption-test';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}
  @override
  Future<String> complete(Prompt p) async => _reply;
  @override
  Future<String> completeStreaming(Prompt p,
      {void Function(String text)? onText,
      void Function(String raw)? onRaw}) async {
    calls.add('foreground');
    onRaw?.call(_rawMood);
    return _reply;
  }
}

class _PreemptionEngine extends _DefaultEngine {
  final cancelStarted = Completer<void>();
  final optionalStarted = Completer<void>();
  Completer<void>? cancelGate;
  Completer<String>? optional;
  var optionalCancelled = false;

  @override
  Future<void> cancelOptional() async {
    calls.add('cancelOptional');
    if (!cancelStarted.isCompleted) cancelStarted.complete();
    await cancelGate?.future;
    final job = optional;
    if (job != null && !job.isCompleted) {
      optionalCancelled = true;
      job.completeError(PlatformException(code: 'llama_cancelled'));
    }
    calls.add('cancelled');
  }

  @override
  Future<String> completeOptional(Prompt p,
      {void Function(String raw)? onRaw}) {
    calls.add('optional');
    optional = Completer<String>();
    if (!optionalStarted.isCompleted) optionalStarted.complete();
    return optional!.future;
  }
}

class _Memory extends MemoryRepo {
  _Memory(super.db);
  @override
  Future<List<Memory>> search(String query, {int limit = 3}) async => [];
  @override
  Future<List<Memory>> important({int limit = 3}) async => [];
}

class _Profile extends ProfileRepo {
  _Profile(super.db);
  Completer<UserProfile?>? nextGet;

  @override
  Future<UserProfile?> get() {
    final gate = nextGet;
    nextGet = null;
    return gate?.future ?? super.get();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('optional defaults preserve streaming and require no fake overrides',
      () async {
    final engine = _DefaultEngine();
    final raw = <String>[];
    expect(
        await engine.completeOptional(Prompt(PromptKind.reply, 'hi'),
            onRaw: raw.add),
        _reply);
    expect(raw, [_rawMood]);
    await engine.cancelOptional();
    expect(engine.calls, ['foreground']);
  });

  group('foreground session preemption', () {
    late _PreemptionEngine engine;
    late AssistantSession session;
    late _Profile profile;
    late TaskRepo tasks;

    setUp(() async {
      final db = await openMigratedV2();
      engine = _PreemptionEngine();
      tasks = TaskRepo(db);
      final memory = _Memory(db);
      profile = _Profile(db);
      session = AssistantSession(
        engine: engine,
        tools: ToolExecutor(tasks, ReminderRepo(db), memory, NoopScheduler(),
            clock: () => _now),
        memory: memory,
        profile: profile,
        taskRepo: tasks,
        conversations: ConversationRepo(db),
        pending: PendingRepo(db),
        conversationId: 'preemption',
        clock: () => _now,
      );
      await session.start();
      addTearDown(session.close);
    });

    // The session's ModelScheduler cancels optional work only when some is
    // queued or running; an idle engine is never asked to cancel.
    test('handle awaits optional cancellation before foreground generation',
        () async {
      await tasks.create('buy milk');
      await session.handle('did I add buy milk?');
      await engine.optionalStarted.future.timeout(_timeout);
      engine.cancelGate = Completer<void>();
      final turn = session.handle('hi');
      await engine.cancelStarted.future.timeout(_timeout);
      expect(engine.calls, ['optional', 'cancelOptional']);
      engine.cancelGate!.complete();
      expect(await turn.timeout(_timeout), 'Hello!');
      expect(engine.calls,
          ['optional', 'cancelOptional', 'cancelled', 'foreground']);
    });

    test('a new turn cancels optional mood left running by the previous turn',
        () async {
      await tasks.create('buy milk');
      expect(await session.handle('did I add buy milk?'), contains('buy milk'));
      await engine.optionalStarted.future.timeout(_timeout);
      final previousJob = session.lastOptionalMoodJob!;
      expect(engine.optional!.isCompleted, isFalse);
      expect(engine.calls, ['optional']);

      expect(await session.handle('hi').timeout(_timeout), 'Hello!');
      await previousJob.timeout(_timeout);
      expect(engine.optionalCancelled, isTrue);
      expect(engine.calls, [
        'optional',
        'cancelOptional',
        'cancelled',
        'foreground',
      ]);
      expect((await tasks.list()).single.title, 'buy milk');
    });

    test('a rule-only new turn also preempts optional work', () async {
      await tasks.create('buy milk');
      await session.handle('did I add buy milk?');
      await engine.optionalStarted.future.timeout(_timeout);
      final previousJob = session.lastOptionalMoodJob!;
      expect(await session.handle('2+2').timeout(_timeout), contains('4'));
      await previousJob.timeout(_timeout);
      expect(engine.optionalCancelled, isTrue);
      expect(engine.calls.where((c) => c == 'foreground'), isEmpty);
    });

    test('preempted mood preparation cannot enqueue stale optional generation',
        () async {
      final preparation = Completer<UserProfile?>();
      await tasks.create('buy milk');
      await session.handle('did I add buy milk?', onText: (_) {
        profile.nextGet = preparation;
      });
      final previousJob = session.lastOptionalMoodJob!;
      expect(engine.calls, isEmpty);
      expect(await session.handle('hi').timeout(_timeout), 'Hello!');
      preparation.complete(null);
      await previousJob.timeout(_timeout);
      // The stale mood job never reached the engine, so nothing to cancel.
      expect(engine.calls, ['foreground']);
    });
  });

  group('native channel optional cancellation', () {
    const channel = MethodChannel('assistant/llm');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late Map<int, Completer<String>> pending;
    late List<int> cancelled;
    late List<MethodCall> generated;

    Future<void> emit(int id, String raw) => messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec()
            .encodeMethodCall(MethodCall('text', {'id': id, 'text': raw})),
        (_) {});

    Future<void> rejectsCancellation(Future<String> job) => expectLater(
        job,
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'llama_cancelled')));

    setUp(() {
      pending = {};
      cancelled = [];
      generated = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        final id = call.arguments['id'] as int;
        if (call.method == 'cancel') {
          cancelled.add(id);
          // Even a chunk delivered inline by native cancel must be suppressed.
          await emit(id, _rawMood);
          pending[id]!
              .completeError(PlatformException(code: 'llama_cancelled'));
          return null;
        }
        generated.add(call);
        return (pending[id] = Completer<String>()).future;
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test(
        'cancels all optional ids while preserving foreground and other engines',
        () async {
      final engine = LlamaChannelEngine('model');
      final other = LlamaChannelEngine('other');
      final optionalRaw = <String>[];
      final foregroundRaw = <String>[];
      final prompt = Prompt(PromptKind.reply, 'hi', now: _now);
      final first = engine.completeOptional(prompt, onRaw: optionalRaw.add);
      final second = engine.completeOptional(prompt); // queued, non-streaming
      final foreground =
          engine.completeStreaming(prompt, onRaw: foregroundRaw.add);
      final foreign = other.completeOptional(prompt);
      final firstFails = rejectsCancellation(first);
      final secondFails = rejectsCancellation(second);
      await Future<void>.delayed(Duration.zero);
      final ids = generated.map((c) => c.arguments['id'] as int).toList();
      await emit(ids.first, 'before cancel');
      await engine.cancelOptional();
      await Future.wait([firstFails, secondFails]);
      expect(cancelled, ids.take(2).toList());
      expect(optionalRaw, ['before cancel']);
      await emit(ids.first, 'late');
      await emit(ids[2], _rawMood);
      expect(optionalRaw, ['before cancel']);
      expect(foregroundRaw, [_rawMood]);
      pending[ids[2]]!.complete('foreground');
      pending[ids[3]]!.complete('foreign');
      expect(await foreground, 'foreground');
      expect(await foreign, 'foreign');
      await engine.cancelOptional();
      await other.cancelOptional();
      expect(cancelled, ids.take(2).toList());
    });

    test('full cancel still stops foreground and optional requests', () async {
      final engine = LlamaChannelEngine('model');
      final prompt = Prompt(PromptKind.reply, 'hi', now: _now);
      final foreground = engine.complete(prompt);
      final optional = engine.completeOptional(prompt);
      final foregroundFails = rejectsCancellation(foreground);
      final optionalFails = rejectsCancellation(optional);
      await Future<void>.delayed(Duration.zero);
      await engine.cancel();
      await Future.wait([foregroundFails, optionalFails]);
      expect(cancelled, pending.keys.toList());
      await engine.cancelOptional();
      await engine.cancel();
      expect(cancelled, hasLength(2));
    });

    test('finished optional requests are removed on success and error',
        () async {
      final engine = LlamaChannelEngine('model');
      final prompt = Prompt(PromptKind.reply, 'hi', now: _now);
      final success = engine.completeOptional(prompt);
      await Future<void>.delayed(Duration.zero);
      pending.values.single.complete('done');
      expect(await success, 'done');
      final failed = engine.completeOptional(prompt);
      final failure = expectLater(failed, throwsA(isA<PlatformException>()));
      await Future<void>.delayed(Duration.zero);
      pending.values.last.completeError(PlatformException(code: 'llama_error'));
      await failure;
      await engine.cancelOptional();
      expect(cancelled, isEmpty);
    });

    test('optional generation keeps foreground prompt bytes and parameters',
        () async {
      final engine = LlamaChannelEngine('model');
      final prompt = Prompt(PromptKind.reply, 'hi', now: _now);
      final foreground = engine.completeStreaming(prompt, onRaw: (_) {});
      final optional = engine.completeOptional(prompt, onRaw: (_) {});
      await Future<void>.delayed(Duration.zero);
      final foregroundArgs =
          Map<Object?, Object?>.from(generated[0].arguments as Map)
            ..remove('id');
      final optionalArgs =
          Map<Object?, Object?>.from(generated[1].arguments as Map)
            ..remove('id');
      expect(optionalArgs, foregroundArgs);
      for (final job in pending.values) {
        job.complete(_rawMood);
      }
      await Future.wait([foreground, optional]);
    });

    test('optional cancellation tolerates native errors and missing plugin',
        () async {
      final engine = LlamaChannelEngine('model');
      final prompt = Prompt(PromptKind.reply, 'hi', now: _now);
      final first = engine.completeOptional(prompt);
      final second = engine.completeOptional(prompt);
      await Future<void>.delayed(Duration.zero);
      final ids = pending.keys.toList();
      messenger.setMockMethodCallHandler(channel, (call) async {
        cancelled.add(call.arguments['id'] as int);
        if (cancelled.length == 1) throw MissingPluginException();
        throw PlatformException(code: 'llama_error');
      });
      await engine.cancelOptional();
      expect(cancelled, ids);
      for (final job in pending.values) {
        job.complete('done');
      }
      await Future.wait([first, second]);
    });
  });
}
