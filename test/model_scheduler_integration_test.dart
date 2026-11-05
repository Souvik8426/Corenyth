import 'dart:async';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/model_scheduler.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/app_services.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'support/v2_db.dart';

/// Plan 3.1 integration: sessions with their own engines share AppServices'
/// one ModelScheduler. Host-only fakes: no native channel, model or device,
/// so these prove Dart-side ordering only, never native cancel latency.

final _now = DateTime(2099, 10, 14, 7);
const _timeout = Duration(seconds: 5);
const _chat = '{"intent":"chat","reply":"Hello!"}';
const _mood = '{"emotion":{"mood":"calm","intensity":0.3,"confidence":0.9}}';

/// Records every engine entry into one shared, ordered log. Foreground calls
/// are held until released; optional calls are held until cancelled or
/// released. `inFlight` counts generations running on ANY engine at once.
class _Engine extends LlmEngine {
  _Engine(this.name, this.log, this.inFlight);
  @override
  final String name;
  final List<String> log;
  final List<int> inFlight; // [current, max]
  bool holdForeground = false;
  final foreground = <Completer<String>>[];
  Completer<String>? optional;
  final optionalStarted = Completer<void>();

  void _enter(String what) {
    log.add('$name:$what');
    inFlight[0]++;
    if (inFlight[0] > inFlight[1]) inFlight[1] = inFlight[0];
  }

  Future<String> _leave(Future<String> f) =>
      f.whenComplete(() => inFlight[0]--);

  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}
  @override
  Future<String> complete(Prompt p) => completeStreaming(p);

  @override
  Future<String> completeStreaming(Prompt p,
      {void Function(String text)? onText,
      void Function(String raw)? onRaw}) {
    _enter('foreground');
    final c = Completer<String>();
    foreground.add(c);
    if (!holdForeground) c.complete(_chat);
    return _leave(c.future);
  }

  @override
  Future<String> completeOptional(Prompt p,
      {void Function(String raw)? onRaw}) {
    _enter('optional');
    final c = optional = Completer<String>();
    if (!optionalStarted.isCompleted) optionalStarted.complete();
    return _leave(c.future);
  }

  void _fail(Completer<String> c) {
    if (!c.isCompleted) {
      c.completeError(PlatformException(code: 'llama_cancelled'));
    }
  }

  @override
  Future<void> cancelOptional() async {
    log.add('$name:cancelOptional');
    final c = optional;
    if (c != null) _fail(c);
  }

  @override
  Future<void> cancel() async {
    log.add('$name:cancel');
    for (final c in foreground) {
      _fail(c);
    }
    final c = optional;
    if (c != null) _fail(c);
  }
}

class _Memory extends MemoryRepo {
  _Memory(super.db);
  @override
  Future<List<Memory>> search(String query, {int limit = 3}) async => [];
  @override
  Future<List<Memory>> important({int limit = 3}) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AppServices owns one model scheduler shared by every session',
      () async {
    final db = await openMigratedV2();
    addTearDown(db.close);
    final services = AppServices(db, NoopScheduler(), '/missing/model.gguf');
    final a = services.newSession(conversationId: 'a');
    final b = services.newSession(conversationId: 'b');
    expect(a.engine, isNot(same(b.engine)));
    expect(a.models, same(services.modelScheduler));
    expect(b.models, same(services.modelScheduler));
    // Background admission is off until the lifecycle owner says the app is
    // open, and pausing turns it off again.
    expect(services.modelScheduler.backgroundEnabled, isFalse);
    services.modelLifecycleChanged(open: true);
    expect(services.modelScheduler.backgroundEnabled, isTrue);
    services.modelLifecycleChanged(open: false);
    expect(services.modelScheduler.backgroundEnabled, isFalse);
    await a.close();
    await b.close();
  });

  group('two sessions on one scheduler', () {
    late Database db;
    late ModelScheduler models;
    late List<String> log;
    late List<int> inFlight;
    late _Engine chatEngine, voiceEngine;
    late AssistantSession chat, voice;
    late TaskRepo tasks;

    AssistantSession session(String id, _Engine engine) {
      final memory = _Memory(db);
      return AssistantSession(
        engine: engine,
        tools: ToolExecutor(tasks, ReminderRepo(db), memory, NoopScheduler(),
            clock: () => _now),
        memory: memory,
        profile: ProfileRepo(db),
        taskRepo: tasks,
        conversations: ConversationRepo(db),
        pending: PendingRepo(db),
        conversationId: id,
        clock: () => _now,
        modelScheduler: models,
      );
    }

    setUp(() async {
      db = await openMigratedV2();
      tasks = TaskRepo(db);
      models = ModelScheduler(allowBackground: false);
      log = [];
      inFlight = [0, 0];
      chatEngine = _Engine('chat', log, inFlight);
      voiceEngine = _Engine('voice', log, inFlight);
      chat = session('chat', chatEngine);
      voice = session('voice', voiceEngine);
      await chat.start();
      await voice.start();
      addTearDown(() async {
        for (final e in [chatEngine, voiceEngine]) {
          e.holdForeground = false;
          for (final c in e.foreground) {
            if (!c.isCompleted) c.complete(_chat);
          }
          final o = e.optional;
          if (o != null && !o.isCompleted) o.complete(_mood);
        }
        await chat.close();
        await voice.close();
        await chat.lastOptionalMoodJob;
        await voice.lastOptionalMoodJob;
        await models.dispose();
        await db.close();
      });
    });

    /// A rule-answered turn dispatches the optional mood job.
    Future<void> startMood(AssistantSession s, _Engine e) async {
      await tasks.create('buy milk');
      expect(await s.handle('did I add buy milk?'), contains('buy milk'));
      await e.optionalStarted.future.timeout(_timeout);
    }

    test('a chat turn cancels the voice session\'s optional mood first',
        () async {
      await startMood(voice, voiceEngine);
      final moodJob = voice.lastOptionalMoodJob!;
      expect(await chat.handle('hi').timeout(_timeout), 'Hello!');
      await moodJob.timeout(_timeout);
      expect(log, [
        'voice:optional',
        'voice:cancelOptional', // on the engine that owns the job
        'chat:foreground',
      ]);
      expect(inFlight[1], 1, reason: 'no two generations at once');
      expect(voice.lastDiagnostics['mood'], isNot(contains('model:mood')));
    });

    test('foreground turns of two sessions never overlap', () async {
      chatEngine.holdForeground = true;
      final first = chat.handle('hi');
      await pumpUntil(() => chatEngine.foreground.isNotEmpty);
      final second = voice.handle('hello there');
      // The voice turn reaches the scheduler but waits for the chat call.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(log, ['chat:foreground']);
      chatEngine.foreground.single.complete(_chat);
      expect(await first.timeout(_timeout), 'Hello!');
      expect(await second.timeout(_timeout), 'Hello!');
      expect(log, ['chat:foreground', 'voice:foreground']);
      expect(inFlight[1], 1);
    });

    test('cancel drops only its own queued foreground call', () async {
      chatEngine.holdForeground = true;
      final running = chat.handle('hi');
      await pumpUntil(() => chatEngine.foreground.isNotEmpty);
      voiceEngine.holdForeground = true;
      final queuedVoice = voice.handle('hello there');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(log, ['chat:foreground']);
      await voice.cancel().timeout(_timeout);
      // The voice turn never reached its engine and ended as cancelled.
      expect(await queuedVoice.timeout(_timeout), '');
      expect(log, ['chat:foreground', 'voice:cancel']);
      // The chat call keeps running and finishes normally.
      chatEngine.foreground.single.complete(_chat);
      expect(await running.timeout(_timeout), 'Hello!');
      expect(log.where((e) => e == 'voice:foreground'), isEmpty);
    });
  });
}

Future<void> pumpUntil(bool Function() done) async {
  final deadline = DateTime.now().add(_timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
