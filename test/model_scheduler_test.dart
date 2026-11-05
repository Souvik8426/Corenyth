import 'dart:async';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/model_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';

class _Call {
  _Call(this.prompt, this.onRaw, this.onText);
  final Prompt prompt;
  final void Function(String)? onRaw;
  final void Function(String)? onText;
  final result = Completer<String>();
  void finish([String value = 'done']) {
    if (!result.isCompleted) result.complete(value);
  }
}

class _Engine extends LlmEngine {
  _Engine(this.name, this.events);
  @override
  final String name;
  final List<String> events;
  final calls = <_Call>[];
  _Call? optional;
  Completer<void>? cancelGate;
  bool finishOnCancel = true;
  bool throwOnCancel = false;
  bool throwOnGenerate = false;

  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}
  @override
  Future<String> complete(Prompt p) => completeStreaming(p);

  Future<String> _start(Prompt p, String kind, void Function(String)? onRaw,
      void Function(String)? onText) {
    events.add('$name:$kind:${p.user}');
    if (throwOnGenerate) throw StateError('generate failed');
    final call = _Call(p, onRaw, onText);
    calls.add(call);
    if (kind == 'optional') optional = call;
    return call.result.future;
  }

  @override
  Future<String> completeStreaming(Prompt p,
          {void Function(String)? onRaw, void Function(String)? onText}) =>
      _start(p, 'foreground', onRaw, onText);

  @override
  Future<String> completeOptional(Prompt p, {void Function(String)? onRaw}) =>
      _start(p, 'optional', onRaw, null);

  @override
  Future<void> cancel() async {
    events.add('$name:cancelAll');
    for (final call in calls) {
      if (!call.result.isCompleted) {
        call.result.completeError(PlatformException(code: 'llama_cancelled'));
      }
    }
  }

  @override
  Future<void> cancelOptional() async {
    events.add('$name:cancel');
    await cancelGate?.future;
    if (throwOnCancel) throw StateError('cancel failed');
    if (finishOnCancel && optional != null && !optional!.result.isCompleted) {
      optional!.result
          .completeError(PlatformException(code: 'llama_cancelled'));
    }
    events.add('$name:cancelAck');
  }
}

/// Timers run on WidgetTester's fake clock; elapsed time is advanced alongside
/// it. No wall-clock waits, native channels, model assets, or device are used.
class _Harness {
  _Harness({bool allowBackground = true}) {
    scheduler = ModelScheduler(
      clock: () => elapsed,
      log: logs.add,
      allowBackground: allowBackground,
    );
  }
  Duration elapsed = Duration.zero;
  final events = <String>[];
  final logs = <String>[];
  late final ModelScheduler scheduler;
  late final a = _Engine('a', events);
  late final b = _Engine('b', events);

  Future<String?> run(String text, ModelPriority priority,
          {_Engine? engine,
          int? turn,
          String? key,
          void Function(String)? onRaw,
          void Function(String)? onText}) =>
      scheduler.run(Prompt(PromptKind.reply, text), priority,
          engine: engine ?? a,
          turn: turn,
          jobKey: key,
          onRaw: onRaw,
          onText: onText);

  Future<ModelRunOutcome> outcome(String text, ModelPriority priority,
          {_Engine? engine, int? turn, String? key}) =>
      scheduler.runWithOutcome(Prompt(PromptKind.reply, text), priority,
          engine: engine ?? a, turn: turn, jobKey: key);

  Future<void> advance(WidgetTester tester, Duration duration) async {
    elapsed += duration;
    await tester.pump(duration);
  }

  Future<void> close(WidgetTester tester) async {
    for (final engine in [a, b]) {
      final gate = engine.cancelGate;
      if (gate != null && !gate.isCompleted) gate.complete();
      for (final call in engine.calls) {
        call.finish();
      }
    }
    await tester.pump();
    await scheduler.dispose();
    await tester.pump();
  }
}

const _fg = ModelPriority.foreground;
const _optional = ModelPriority.optional;
const _background = ModelPriority.background;
const _second = Duration(seconds: 1);
const _minute = Duration(seconds: 60);

void main() {
  testWidgets('foreground drops queued lower work before any engine is called',
      (tester) async {
    final h = _Harness();
    final optional = h.run('mood', _optional);
    final background = h.run('extract', _background);
    final foreground = h.run('chat', _fg, engine: h.b);
    await tester.pump();
    expect(await optional, isNull);
    expect(await background, isNull);
    expect(h.events, ['b:foreground:chat']);
    h.b.calls.single.finish('hello');
    await tester.pump();
    expect(await foreground, 'hello');
    await h.close(tester);
  });

  testWidgets('cross-engine foreground cancels running optional on its owner',
      (tester) async {
    final h = _Harness();
    final old = h.run('mood', _optional, key: 'mood:1');
    await tester.pump();
    final foreground = h.run('voice', _fg, engine: h.b);
    await tester.pump();
    expect(await old, isNull);
    expect(h.events,
        ['a:optional:mood', 'a:cancel', 'a:cancelAck', 'b:foreground:voice']);
    expect(h.scheduler.isBlocked('mood:1'), isFalse);
    h.b.calls.single.finish();
    await tester.pump();
    expect(await foreground, 'done');
    await h.close(tester);
  });

  testWidgets('background needs 60 seconds idle and yields to queued optional',
      (tester) async {
    final h = _Harness();
    final background = h.run('extract', _background);
    await tester.pump();
    await h.advance(tester, const Duration(seconds: 59));
    expect(h.events, isEmpty);
    final optional = h.run('mood', _optional, engine: h.b);
    await tester.pump();
    await h.advance(tester, _second);
    expect(h.events, ['b:optional:mood']);
    h.b.calls.single.finish();
    await tester.pump();
    expect(await optional, 'done');
    await h.advance(tester, const Duration(seconds: 59));
    expect(h.events, ['b:optional:mood']);
    await h.advance(tester, _second);
    expect(h.events.last, 'a:optional:extract');
    h.a.calls.single.finish('suggestion');
    await tester.pump();
    expect(await background, 'suggestion');
    await h.close(tester);
  });

  testWidgets('rule-only turn drops background and resets the idle timer',
      (tester) async {
    final h = _Harness();
    final old = h.run('old', _background);
    await tester.pump();
    await h.advance(tester, const Duration(seconds: 59));
    expect(h.scheduler.noteTurn(), 1);
    expect(await old, isNull);
    final next = h.run('next', _background);
    await tester.pump();
    await h.advance(tester, const Duration(seconds: 59));
    expect(h.events, isEmpty);
    await h.advance(tester, _second);
    expect(h.events, ['a:optional:next']);
    h.a.calls.single.finish();
    await tester.pump();
    expect(await next, 'done');
    await h.close(tester);
  });

  testWidgets('foreground preempts running background across engines',
      (tester) async {
    final h = _Harness();
    final background = h.run('extract', _background);
    await tester.pump();
    await h.advance(tester, _minute);
    final foreground = h.run('chat', _fg, engine: h.b);
    await tester.pump();
    expect(await background, isNull);
    expect(h.events.last, 'b:foreground:chat');
    expect(h.events, containsAllInOrder(['a:cancel', 'a:cancelAck']));
    h.b.calls.single.finish();
    await tester.pump();
    expect(await foreground, 'done');
    await h.close(tester);
  });

  testWidgets('stale queued and late-prepared optional jobs are dropped',
      (tester) async {
    final h = _Harness();
    final turn = h.scheduler.noteTurn();
    final foreground = h.run('chat', _fg);
    await tester.pump();
    final queued = h.run('queued mood', _optional, turn: turn);
    h.scheduler.noteTurn();
    final late = h.run('late mood', _optional, turn: turn);
    expect(await queued, isNull);
    expect(await late, isNull);
    h.a.calls.single.finish();
    await tester.pump();
    expect(await foreground, 'done');
    expect(h.events, ['a:foreground:chat']);
    final fresh = h.run('fresh', _optional, turn: h.scheduler.currentTurn);
    await tester.pump();
    h.a.calls.last.finish();
    await tester.pump();
    expect(await fresh, 'done');
    await h.close(tester);
  });

  testWidgets('foreground calls are FIFO and never preempt each other',
      (tester) async {
    final h = _Harness();
    final one = h.run('one', _fg);
    await tester.pump();
    final optional = h.run('mood', _optional);
    final two = h.run('two', _fg, engine: h.b);
    final three = h.run('three', _fg);
    await tester.pump();
    expect(await optional, isNull);
    expect(h.events, ['a:foreground:one']);
    h.a.calls.single.finish('1');
    await tester.pump();
    expect(h.events.last, 'b:foreground:two');
    h.b.calls.single.finish('2');
    await tester.pump();
    expect(h.events.last, 'a:foreground:three');
    h.a.calls.last.finish('3');
    await tester.pump();
    expect(await Future.wait([one, two, three]), ['1', '2', '3']);
    await h.close(tester);
  });

  testWidgets('two failures block a key across engines and queued duplicates',
      (tester) async {
    final h = _Harness();
    Future<void> fail(_Engine engine) async {
      final job = h.run('try', _optional, engine: engine, key: 'extract:42');
      final check = expectLater(job, throwsStateError);
      await tester.pump();
      engine.calls.last.result.completeError(StateError('bad input'));
      await tester.pump();
      await check;
    }

    await fail(h.a);
    expect(h.scheduler.isBlocked('extract:42'), isFalse);
    final second = h.run('second', _optional, engine: h.b, key: 'extract:42');
    final check = expectLater(second, throwsStateError);
    await tester.pump();
    final duplicate = h.run('duplicate', _optional, key: 'extract:42');
    h.b.calls.single.result.completeError(StateError('bad input'));
    await tester.pump();
    await check;
    expect(await duplicate, isNull);
    expect(await h.run('retry', _optional, key: 'extract:42'), isNull);
    expect(h.scheduler.isBlocked('extract:42'), isTrue);
    expect(h.logs, hasLength(1));
    expect(h.logs.single, contains('extract:42'));
    expect(h.logs.single, contains('2 failures'));
    final different = h.run('different', _optional, key: 'extract:43');
    await tester.pump();
    h.a.calls.last.finish();
    await tester.pump();
    expect(await different, 'done');
    await h.close(tester);
  });

  testWidgets('preemption and late cancelled errors do not count as failures',
      (tester) async {
    final h = _Harness();
    for (var i = 0; i < 3; i++) {
      final optional = h.run('mood', _optional, key: 'mood');
      await tester.pump();
      h.scheduler.noteTurn();
      await tester.pump();
      expect(await optional, isNull);
    }
    expect(h.scheduler.isBlocked('mood'), isFalse);
    expect(h.logs, isEmpty);
    await h.close(tester);
  });

  testWidgets('cancellation awaits generation after acknowledgement',
      (tester) async {
    final h = _Harness();
    h.a.finishOnCancel = false;
    final optional = h.run('mood', _optional);
    await tester.pump();
    final foreground = h.run('chat', _fg, engine: h.b);
    var confirmed = false;
    final cancellation = h.scheduler.cancelOptional().then((result) {
      confirmed = true;
      return result;
    });
    await tester.pump();
    expect(await optional, isNull);
    expect(confirmed, isFalse);
    expect(h.b.calls, isEmpty);
    h.a.calls.single.finish();
    await tester.pump();
    expect(await cancellation, ModelCancellationResult.confirmed);
    expect(h.b.calls, hasLength(1));
    h.b.calls.single.finish();
    await tester.pump();
    expect(await foreground, 'done');
    await h.close(tester);
  });

  testWidgets('late cancellation acknowledgement cannot hit a subsequent job',
      (tester) async {
    final h = _Harness();
    h.a.cancelGate = Completer<void>();
    final optional = h.run('mood', _optional);
    await tester.pump();
    final foreground = h.run('chat', _fg);
    await tester.pump();
    h.a.calls.single.finish();
    await tester.pump();
    expect(await optional, isNull);
    expect(h.a.calls, hasLength(1));
    h.a.cancelGate!.complete();
    await tester.pump();
    expect(h.a.calls, hasLength(2));
    h.a.calls.last.finish();
    await tester.pump();
    expect(await foreground, 'done');
    await h.close(tester);
  });

  for (final stalledAck in [true, false]) {
    testWidgets(
        'bounded cancellation quarantines stalled '
        '${stalledAck ? 'acknowledgement' : 'generation'} and recovers',
        (tester) async {
      final h = _Harness();
      if (stalledAck) h.a.cancelGate = Completer<void>();
      h.a.finishOnCancel = false;
      final optional = h.run('mood', _optional);
      await tester.pump();
      final foreground = h.run('chat', _fg, engine: h.b);
      final check = expectLater(
          foreground,
          throwsA(isA<ModelCancellationException>().having(
              (e) => e.result, 'result', ModelCancellationResult.timedOut)));
      final cancellation = h.scheduler.cancelOptional();
      await tester.pump();
      if (stalledAck) h.a.calls.single.finish();
      await tester.pump();
      await h.advance(tester, const Duration(seconds: 2));
      await check;
      expect(await optional, isNull);
      expect(await cancellation, ModelCancellationResult.timedOut);
      expect(h.b.calls, isEmpty);
      await expectLater(h.run('retry', _fg, engine: h.b),
          throwsA(isA<ModelCancellationException>()));
      if (stalledAck) {
        h.a.cancelGate!.complete();
      } else {
        h.a.calls.single.finish();
      }
      await tester.pump();
      final recovered = h.run('recovered', _fg, engine: h.b);
      await tester.pump();
      h.b.calls.single.finish();
      await tester.pump();
      expect(await recovered, 'done');
      expect(h.logs.single, contains('quarantined'));
      await h.close(tester);
    });
  }

  testWidgets('cancel failure is bounded and quarantines until generation ends',
      (tester) async {
    final h = _Harness();
    h.a.throwOnCancel = true;
    final optional = h.run('mood', _optional);
    await tester.pump();
    final foreground = h.run('chat', _fg, engine: h.b);
    final check = expectLater(
        foreground,
        throwsA(isA<ModelCancellationException>().having(
            (e) => e.result, 'result', ModelCancellationResult.failed)));
    final cancellation = h.scheduler.cancelOptional();
    await tester.pump();
    await check;
    expect(await cancellation, ModelCancellationResult.failed);
    expect(await optional, isNull);
    expect(h.b.calls, isEmpty);
    h.a.calls.single.finish();
    await tester.pump();
    final recovered = h.run('recovered', _fg, engine: h.b);
    await tester.pump();
    h.b.calls.single.finish();
    await tester.pump();
    expect(await recovered, 'done');
    await h.close(tester);
  });

  testWidgets(
      'callbacks are suppressed after preemption; optional text dedupes',
      (tester) async {
    final h = _Harness();
    final raw = <String>[];
    final text = <String>[];
    final optional = h.run('mood', _optional, onRaw: raw.add, onText: text.add);
    await tester.pump();
    const envelope = '{"type":"respond","text":"hello"}';
    final emit = h.a.calls.single.onRaw!;
    emit(envelope);
    emit(envelope);
    expect(raw, [envelope, envelope]);
    expect(text, ['hello']);
    h.scheduler.noteTurn();
    emit('{"type":"respond","text":"late"}');
    await tester.pump();
    expect(await optional, isNull);
    expect(raw, [envelope, envelope]);
    expect(text, ['hello']);
    await h.close(tester);
  });

  testWidgets('foreground streams raw/text and synchronous failure frees queue',
      (tester) async {
    final h = _Harness();
    h.a.throwOnGenerate = true;
    final failed = h.run('bad', _fg, key: 'bad');
    final check = expectLater(failed, throwsStateError);
    final raw = <String>[];
    final text = <String>[];
    final next =
        h.run('good', _fg, engine: h.b, onRaw: raw.add, onText: text.add);
    await tester.pump();
    await check;
    h.b.calls.single.onRaw!('raw');
    h.b.calls.single.onText!('visible');
    h.b.calls.single.finish('result');
    await tester.pump();
    expect(await next, 'result');
    expect(raw, ['raw']);
    expect(text, ['visible']);
    await h.close(tester);
  });

  testWidgets('background admission can start disabled', (tester) async {
    final h = _Harness(allowBackground: false);
    expect(await h.run('extract', _background), isNull);
    await h.advance(tester, _minute);
    expect(h.events, isEmpty);
    await h.close(tester);
  });

  for (final priority in [_optional, _background, _fg]) {
    testWidgets(
        'external llama_cancelled is not a failure for ${priority.name}',
        (tester) async {
      final h = _Harness();
      await h.advance(tester, _minute);
      for (var i = 0; i < 3; i++) {
        final result = h.run('cancel me', priority, key: 'external');
        final check = priority == _fg
            ? expectLater(
                result,
                throwsA(isA<PlatformException>()
                    .having((e) => e.code, 'code', 'llama_cancelled')))
            : null;
        await tester.pump();
        if (priority == _fg) {
          await h.a.cancel();
        } else {
          await h.a.cancelOptional();
        }
        await tester.pump();
        if (check != null) {
          await check;
        } else {
          expect(await result, isNull);
        }
        expect(h.scheduler.isBlocked('external'), isFalse);
      }
      expect(h.logs, isEmpty);
      await h.close(tester);
    });
  }

  testWidgets('real platform failures still block queued duplicates',
      (tester) async {
    final h = _Harness();
    await h.advance(tester, _minute);
    Future<ModelRunOutcome>? duplicate;
    for (var i = 0; i < 2; i++) {
      final result = h.outcome('bad', _background, key: 'extract:bad');
      final check = expectLater(result, throwsA(isA<PlatformException>()));
      await tester.pump();
      if (i == 1) {
        duplicate = h.outcome('duplicate', _background, key: 'extract:bad');
      }
      h.a.calls.last.result
          .completeError(PlatformException(code: 'llama_error'));
      await tester.pump();
      await check;
    }
    expect((await duplicate!).status, ModelRunStatus.blocked);
    expect(h.scheduler.isBlocked('extract:bad'), isTrue);
    expect((await h.outcome('retry', _background, key: 'extract:bad')).status,
        ModelRunStatus.blocked);
    expect(h.a.calls, hasLength(2));
    await h.close(tester);
  });

  testWidgets('cancelEngine drops only its own queued foreground and optional',
      (tester) async {
    final h = _Harness();
    final running = h.run('running', _fg, engine: h.b);
    await tester.pump();
    final cancelled = h.run('cancelled', _fg);
    final check = expectLater(
        cancelled,
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'llama_cancelled')));
    final survivor = h.run('survivor', _fg, engine: h.b);
    final optional = h.outcome('mood', _optional);
    h.scheduler.cancelEngine(h.a);
    await tester.pump();
    await check;
    expect((await optional).status, ModelRunStatus.cancelled);
    expect(h.events, ['b:foreground:running']);
    h.b.calls.single.finish();
    await tester.pump();
    expect(await running, 'done');
    expect(h.events.last, 'b:foreground:survivor');
    expect(h.a.calls, isEmpty);
    h.b.calls.last.finish();
    await tester.pump();
    expect(await survivor, 'done');
    await h.close(tester);
  });

  testWidgets(
      'cancelEngine suppresses active callbacks but keeps worker occupied',
      (tester) async {
    final h = _Harness();
    final raw = <String>[];
    final running = h.run('running', _fg, onRaw: raw.add);
    final check = expectLater(running, throwsA(isA<PlatformException>()));
    await tester.pump();
    final survivor = h.run('survivor', _fg, engine: h.b);
    h.scheduler.cancelEngine(h.a);
    await tester.pump();
    await check;
    h.a.calls.single.onRaw!('late');
    expect(raw, isEmpty);
    expect(h.b.calls, isEmpty);
    await h.a.cancel();
    await tester.pump();
    expect(h.b.calls, hasLength(1));
    h.b.calls.single.finish();
    await tester.pump();
    expect(await survivor, 'done');
    await h.close(tester);
  });

  testWidgets('idle starts after long foreground generation and turn activity',
      (tester) async {
    final h = _Harness();
    final foreground = h.run('chat', _fg);
    await tester.pump();
    final background = h.run('extract', _background);
    await h.advance(tester, const Duration(seconds: 40));
    h.a.calls.single.finish();
    await tester.pump();
    expect(await foreground, 'done');
    await h.advance(tester, const Duration(seconds: 59));
    expect(h.a.calls, hasLength(1));
    // Speech / other turn work can finish after the model itself.
    h.scheduler.noteActivity();
    await h.advance(tester, const Duration(seconds: 59));
    expect(h.a.calls, hasLength(1));
    await h.advance(tester, _second);
    expect(h.events.last, 'a:optional:extract');
    h.a.calls.last.finish();
    await tester.pump();
    expect(await background, 'done');
    await h.close(tester);
  });

  testWidgets('failed foreground completion also resets idle', (tester) async {
    final h = _Harness();
    final foreground = h.run('chat', _fg);
    final check = expectLater(foreground, throwsStateError);
    await tester.pump();
    final background = h.run('extract', _background);
    await h.advance(tester, _minute);
    h.a.calls.single.result.completeError(StateError('failed'));
    await tester.pump();
    await check;
    await h.advance(tester, const Duration(seconds: 59));
    expect(h.a.calls, hasLength(1));
    await h.advance(tester, _second);
    h.a.calls.last.finish();
    await tester.pump();
    expect(await background, 'done');
    await h.close(tester);
  });

  testWidgets('foreground submission invalidates old background idle deadline',
      (tester) async {
    final h = _Harness();
    final old = h.outcome('old', _background);
    await tester.pump();
    await h.advance(tester, const Duration(seconds: 59));
    final foreground = h.run('chat', _fg);
    final next = h.run('new', _background);
    await tester.pump();
    expect((await old).status, ModelRunStatus.preempted);
    h.a.calls.single.finish();
    await tester.pump();
    expect(await foreground, 'done');
    await h.advance(tester, const Duration(seconds: 59));
    expect(h.a.calls, hasLength(1));
    await h.advance(tester, _second);
    expect(h.events.last, 'a:optional:new');
    h.a.calls.last.finish();
    await tester.pump();
    expect(await next, 'done');
    await h.close(tester);
  });

  testWidgets('lifecycle disables queued background and resume restarts idle',
      (tester) async {
    final h = _Harness();
    final queued = h.outcome('queued', _background);
    await tester.pump();
    await h.advance(tester, const Duration(seconds: 59));
    h.scheduler.backgroundEnabled = false;
    expect((await queued).status, ModelRunStatus.backgroundDisabled);
    expect((await h.outcome('disabled', _background)).status,
        ModelRunStatus.backgroundDisabled);
    await h.advance(tester, const Duration(minutes: 5));
    expect(h.events, isEmpty);
    h.scheduler.backgroundEnabled = true;
    final resumed = h.run('resumed', _background);
    await tester.pump();
    await h.advance(tester, const Duration(seconds: 59));
    expect(h.events, isEmpty);
    await h.advance(tester, _second);
    h.a.calls.single.finish();
    await tester.pump();
    expect(await resumed, 'done');
    await h.close(tester);
  });

  testWidgets('pause cancels active background without overlapping foreground',
      (tester) async {
    final h = _Harness();
    h.a.finishOnCancel = false;
    final background = h.outcome('extract', _background);
    await tester.pump();
    await h.advance(tester, _minute);
    h.scheduler.backgroundEnabled = false;
    final foreground = h.run('chat', _fg, engine: h.b);
    await tester.pump();
    expect((await background).status, ModelRunStatus.backgroundDisabled);
    expect(h.events, ['a:optional:extract', 'a:cancel', 'a:cancelAck']);
    expect(h.b.calls, isEmpty);
    h.a.calls.single.finish();
    await tester.pump();
    h.b.calls.single.finish();
    await tester.pump();
    expect(await foreground, 'done');
    await h.close(tester);
  });

  for (final priority in [_fg, _optional]) {
    testWidgets('pause leaves active ${priority.name} work alone',
        (tester) async {
      final h = _Harness();
      final job = h.run('active', priority);
      await tester.pump();
      h.scheduler.backgroundEnabled = false;
      await tester.pump();
      expect(h.events, hasLength(1));
      h.a.calls.single.finish();
      await tester.pump();
      expect(await job, 'done');
      await h.close(tester);
    });
  }

  testWidgets(
      'per-call outcomes distinguish success, stale, blocked and disposed',
      (tester) async {
    final h = _Harness();
    final success = h.outcome('success', _optional);
    await tester.pump();
    h.a.calls.single.finish('value');
    await tester.pump();
    final completed = await success;
    expect(completed.status, ModelRunStatus.completed);
    expect(completed.output, 'value');
    h.scheduler.noteTurn();
    expect((await h.outcome('stale', _optional, turn: 0)).status,
        ModelRunStatus.stale);
    for (var i = 0; i < 2; i++) {
      final failure = h.outcome('bad', _optional, key: 'blocked');
      final check = expectLater(failure, throwsStateError);
      await tester.pump();
      h.a.calls.last.result.completeError(StateError('bad'));
      await tester.pump();
      await check;
    }
    final blocked = h.outcome('blocked', _optional, key: 'blocked');
    final queued = h.outcome('dispose me', _background);
    await h.scheduler.dispose();
    expect((await blocked).status, ModelRunStatus.blocked);
    expect((await queued).status, ModelRunStatus.disposed);
    await h.close(tester);
  });

  testWidgets(
      'foreground ignores blocked keys and its failures do not block keys',
      (tester) async {
    final h = _Harness();
    h.a.throwOnGenerate = true;
    for (var i = 0; i < 2; i++) {
      final failed = h.run('bad', _fg, key: 'foreground');
      final check = expectLater(failed, throwsStateError);
      await tester.pump();
      await check;
    }
    expect(h.scheduler.isBlocked('foreground'), isFalse);
    for (var i = 0; i < 2; i++) {
      final failed = h.run('bad', _optional, key: 'blocked');
      final check = expectLater(failed, throwsStateError);
      await tester.pump();
      await check;
    }
    expect(h.scheduler.isBlocked('blocked'), isTrue);
    final foreground = h.run('chat', _fg, engine: h.b, key: 'blocked');
    await tester.pump();
    expect(h.events.last, 'b:foreground:chat');
    h.b.calls.single.finish();
    await tester.pump();
    expect(await foreground, 'done');
    await h.close(tester);
  });

  testWidgets('dispose drops queued work, suppresses streams and rejects runs',
      (tester) async {
    final h = _Harness();
    final raw = <String>[];
    final foreground = h.run('chat', _fg, onRaw: raw.add);
    await tester.pump();
    final optional = h.run('mood', _optional);
    expect(await h.scheduler.dispose(), ModelCancellationResult.confirmed);
    expect(await optional, isNull);
    h.a.calls.single.onRaw!('late');
    h.a.calls.single.finish('finished');
    await tester.pump();
    expect(await foreground, 'finished');
    expect(raw, isEmpty);
    expect(h.events, ['a:foreground:chat']);
    await expectLater(h.run('new', _fg), throwsStateError);
    await h.close(tester);
  });
}
