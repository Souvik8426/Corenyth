import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';

import 'engine.dart';

enum ModelPriority { foreground, optional, background }

/// Per-call result; genuine generation errors still propagate as exceptions.
enum ModelRunStatus {
  completed,
  preempted,
  stale,
  blocked,
  backgroundDisabled,
  cancelled,
  disposed,
}

class ModelRunOutcome {
  const ModelRunOutcome(this.status, [this.output]);
  final ModelRunStatus status;
  final String? output;
}

enum ModelCancellationResult { confirmed, timedOut, failed }

/// Cancellation could not establish that the shared model worker was free.
class ModelCancellationException implements Exception {
  final ModelCancellationResult result;
  const ModelCancellationException(this.result);

  @override
  String toString() => 'Model cancellation ${result.name}; worker unavailable';
}

/// One instance belongs to AppServices, shared by chat and voice sessions even
/// when each session has its own engine. All model calls must pass through it.
/// This coordinates one Dart isolate; it cannot arbitrate another process's
/// native worker. Set [backgroundEnabled] from the app lifecycle; background
/// work is allowed only while the app is open.
///
/// Call [noteTurn] for every user turn (including rule-only and voice turns).
/// Capture its returned token before asynchronous optional-job preparation and
/// pass it as `turn` to [run], so late preparation cannot revive an old job.
/// Dropped/preempted/blocked work resolves to null via [run]; [runWithOutcome]
/// distinguishes those cases. Foreground cancellation and genuine errors throw.
class ModelScheduler {
  ModelScheduler({
    Duration Function()? clock,
    this.idleDelay = const Duration(seconds: 60),
    this.cancellationTimeout = const Duration(seconds: 2),
    bool allowBackground = true,
    void Function(String message)? log,
  })  : _backgroundEnabled = allowBackground,
        _clock = clock ?? (Stopwatch()..start()).elapsedGetter,
        _log = log ?? _defaultLog {
    if (idleDelay.isNegative || cancellationTimeout <= Duration.zero) {
      throw ArgumentError('Idle delay must be >= 0 and cancel timeout > 0');
    }
    _lastActivity = _clock();
  }

  final Duration idleDelay;
  final Duration cancellationTimeout;
  bool _backgroundEnabled;
  bool get allowBackground => _backgroundEnabled;
  bool get backgroundEnabled => _backgroundEnabled;

  /// Disable on pause: drop queued background jobs and cancel a running one.
  /// Foreground and optional jobs are unaffected. Resume starts a fresh idle wait.
  set backgroundEnabled(bool enabled) {
    if (_disposed) throw StateError('ModelScheduler is disposed');
    if (_backgroundEnabled == enabled) return;
    _backgroundEnabled = enabled;
    _idleTimer?.cancel();
    if (enabled) {
      noteActivity();
    } else {
      _dropWhere((job) => job.priority == ModelPriority.background,
          ModelRunStatus.backgroundDisabled);
      final job = _active;
      if (job != null && job.priority == ModelPriority.background) {
        unawaited(_cancelActive(job, ModelRunStatus.backgroundDisabled));
      }
      _schedulePump();
    }
  }

  final Duration Function() _clock;
  final void Function(String) _log;
  final _queue = <_ModelJob>[];
  final _failures = <String, int>{};
  late Duration _lastActivity;
  int _turn = 0;
  bool _disposed = false;
  bool _pumpScheduled = false;
  Timer? _idleTimer;
  _ModelJob? _active;
  _Cancellation? _cancellation;

  int get currentTurn => _turn;
  bool isBlocked(String jobKey) => (_failures[jobKey] ?? 0) >= 2;

  /// Starts a new app-wide turn and preempts lower-priority work immediately.
  int noteTurn() {
    if (_disposed) throw StateError('ModelScheduler is disposed');
    _turn++;
    noteActivity();
    unawaited(cancelOptional());
    return _turn;
  }

  /// Records turn completion (including speech or rule-only work) or activity
  /// outside generation, so background work waits a full idle interval.
  void noteActivity() {
    if (_disposed) throw StateError('ModelScheduler is disposed');
    _lastActivity = _clock();
    _idleTimer?.cancel();
    _schedulePump();
  }

  /// Enqueues a call on [engine]; the scheduler never loads or unloads it.
  /// Use a stable [jobKey] per input (for example `extract:42`). Two genuine
  /// failures block that key for this scheduler's lifetime, including queued
  /// duplicates and calls through other engines. Success does not reset the
  /// count; cancellation and dropped jobs do not increment it. Foreground
  /// calls ignore keys. No auto-retries or persistence across restarts.
  Future<String?> run(
    Prompt prompt,
    ModelPriority priority, {
    required LlmEngine engine,
    int? turn,
    void Function(String raw)? onRaw,
    void Function(String text)? onText,
    String? jobKey,
  }) {
    return runWithOutcome(prompt, priority,
            engine: engine,
            turn: turn,
            onRaw: onRaw,
            onText: onText,
            jobKey: jobKey)
        .then((outcome) => outcome.output);
  }

  /// Like [run], with a result belonging to this call rather than shared state.
  /// Foreground keys are ignored: background failure limits cannot block a turn.
  Future<ModelRunOutcome> runWithOutcome(
    Prompt prompt,
    ModelPriority priority, {
    required LlmEngine engine,
    int? turn,
    void Function(String raw)? onRaw,
    void Function(String text)? onText,
    String? jobKey,
  }) {
    if (_disposed) {
      return Future.error(StateError('ModelScheduler is disposed'));
    }
    if (priority == ModelPriority.foreground) {
      jobKey = null;
      noteActivity();
      unawaited(cancelOptional());
    }
    if (jobKey != null && isBlocked(jobKey)) {
      return Future.value(const ModelRunOutcome(ModelRunStatus.blocked));
    }
    if (priority == ModelPriority.background && !backgroundEnabled) {
      return Future.value(
          const ModelRunOutcome(ModelRunStatus.backgroundDisabled));
    }
    if (priority == ModelPriority.optional && (turn ?? _turn) != _turn) {
      return Future.value(const ModelRunOutcome(ModelRunStatus.stale));
    }
    final cancellation = _cancellation;
    if (cancellation?.failure != null) {
      return Future.error(ModelCancellationException(cancellation!.failure!));
    }
    final job = _ModelJob(
        prompt, priority, engine, turn ?? _turn, jobKey, onRaw, onText);
    _queue.add(job);
    _schedulePump();
    return job.result.future;
  }

  /// Drops queued optional/background work and requests cancellation on the
  /// *running job's engine*. Foreground jobs are never cancelled by this API.
  ///
  /// Confirmation requires BOTH cancelOptional's acknowledgement and generation
  /// settlement within [cancellationTimeout]. On timeout/error, queued and new
  /// work fails with [ModelCancellationException] until both settle. In
  /// particular, neither a timeout nor acknowledgement alone proves generation
  /// has stopped. LlmEngine does not guarantee overlapping generations are safe.
  /// This bound cannot interrupt synchronous code blocking the Dart isolate.
  Future<ModelCancellationResult> cancelOptional() {
    _idleTimer?.cancel();
    _dropWhere((job) => job.priority != ModelPriority.foreground,
        ModelRunStatus.preempted);
    final pending = _cancellation;
    if (pending != null) return pending.result.future;
    final job = _active;
    if (job == null || job.priority == ModelPriority.foreground) {
      return Future.value(ModelCancellationResult.confirmed);
    }
    return _cancelActive(job, ModelRunStatus.preempted);
  }

  Future<ModelCancellationResult> _cancelActive(
      _ModelJob job, ModelRunStatus status) {
    final pending = _cancellation;
    if (pending != null) return pending.result.future;
    job.cancelled = true;
    if (!job.result.isCompleted) job.result.complete(ModelRunOutcome(status));
    final cancellation = _Cancellation();
    _cancellation = cancellation;
    cancellation.timer = Timer(cancellationTimeout, () {
      _cancellationFailed(cancellation, ModelCancellationResult.timedOut);
    });
    unawaited(_cancelAndWait(job, cancellation));
    return cancellation.result.future;
  }

  /// Cancels this engine's queued jobs and suppresses its active callbacks.
  /// The owner must also call `engine.cancel()` to stop native work. The active
  /// worker slot stays occupied until generation (and any pending cancel) settles.
  /// Foreground callers receive the native cancellation code, including queued
  /// callers that have not reached the engine yet.
  void cancelEngine(LlmEngine engine) {
    _dropWhere(
        (job) => identical(job.engine, engine), ModelRunStatus.cancelled);
    final job = _active;
    if (job != null && identical(job.engine, engine)) {
      job.cancelled = true;
      _completeDrop(job, ModelRunStatus.cancelled);
    }
    _schedulePump();
  }

  /// Stops admission, drops queued work, and bounds lower-priority cancellation.
  /// An already-running foreground call is allowed to finish, with callbacks
  /// suppressed. Engine unload/lifetime remains the owner's responsibility.
  Future<ModelCancellationResult> dispose() {
    _disposed = true;
    _idleTimer?.cancel();
    _dropWhere((_) => true, ModelRunStatus.disposed);
    return cancelOptional();
  }

  Future<void> _cancelAndWait(_ModelJob job, _Cancellation cancellation) async {
    try {
      await job.engine.cancelOptional();
    } catch (_) {
      _cancellationFailed(cancellation, ModelCancellationResult.failed);
    }
    await job.finished.future;
    cancellation.timer?.cancel();
    if (!cancellation.result.isCompleted) {
      cancellation.result.complete(ModelCancellationResult.confirmed);
    }
    _cancellation = null;
    _schedulePump();
  }

  void _cancellationFailed(
      _Cancellation cancellation, ModelCancellationResult reason) {
    if (cancellation.result.isCompleted) return;
    cancellation.failure = reason;
    cancellation.timer?.cancel();
    cancellation.result.complete(reason);
    final queued = _queue.toList();
    _queue.clear();
    for (final job in queued) {
      job.result.completeError(ModelCancellationException(reason));
    }
    _writeLog('ModelScheduler cancellation ${reason.name}; worker quarantined');
  }

  void _schedulePump() {
    if (_pumpScheduled || _disposed) return;
    _pumpScheduled = true;
    scheduleMicrotask(() {
      _pumpScheduled = false;
      _pump();
    });
  }

  void _pump() {
    _idleTimer?.cancel();
    if (_disposed || _active != null || _cancellation != null) return;
    _dropWhere(
        (job) => job.priority == ModelPriority.optional && job.turn != _turn,
        ModelRunStatus.stale);
    _dropWhere((job) => job.key != null && isBlocked(job.key!),
        ModelRunStatus.blocked);
    _dropWhere(
        (job) => job.priority == ModelPriority.background && !backgroundEnabled,
        ModelRunStatus.backgroundDisabled);
    if (_queue.isEmpty) return;
    var index =
        _queue.indexWhere((j) => j.priority == ModelPriority.foreground);
    if (index < 0) {
      index = _queue.indexWhere((j) => j.priority == ModelPriority.optional);
    }
    if (index < 0) {
      // Only pending background jobs remain: no active/queued foreground or
      // optional job. Run background jobs FIFO, one at a time.
      final remaining = idleDelay - (_clock() - _lastActivity);
      if (remaining > Duration.zero) {
        _idleTimer = Timer(remaining, _schedulePump);
        return;
      }
      index = 0;
    }
    final job = _queue.removeAt(index);
    _active = job;
    unawaited(_execute(job));
  }

  bool _canPublish(_ModelJob job) =>
      !_disposed &&
      !job.cancelled &&
      (job.priority != ModelPriority.optional || job.turn == _turn);

  Future<void> _execute(_ModelJob job) async {
    try {
      void raw(String value) {
        if (_canPublish(job)) job.onRaw?.call(value);
      }

      final output = job.priority == ModelPriority.foreground
          ? await job.engine.completeStreaming(job.prompt,
              onRaw: job.onRaw == null ? null : raw,
              onText: job.onText == null
                  ? null
                  : (text) {
                      if (_canPublish(job)) job.onText!(text);
                    })
          : await job.engine.completeOptional(job.prompt,
              onRaw: job.onRaw == null && job.onText == null
                  ? null
                  : (value) {
                      raw(value);
                      if (!_canPublish(job) || job.onText == null) return;
                      final text = visibleRespondText(value);
                      if (text != null && text != job.lastText) {
                        job.lastText = text;
                        job.onText!(text);
                      }
                    });
      if (!job.result.isCompleted) {
        job.result.complete(ModelRunOutcome(ModelRunStatus.completed, output));
      }
    } catch (error, stack) {
      if (error is PlatformException && error.code == 'llama_cancelled') {
        _completeDrop(job, ModelRunStatus.cancelled, error, stack);
      } else if (!job.cancelled) {
        final key = job.key;
        if (key != null) {
          _failures[key] = (_failures[key] ?? 0) + 1;
          if (isBlocked(key)) {
            _writeLog('ModelScheduler blocked job key "$key" after 2 failures');
          }
        }
        if (!job.result.isCompleted) job.result.completeError(error, stack);
      }
    } finally {
      if (job.priority != ModelPriority.background) _lastActivity = _clock();
      if (identical(_active, job)) _active = null;
      job.finished.complete();
      _schedulePump();
    }
  }

  void _dropWhere(bool Function(_ModelJob) drop, ModelRunStatus status) {
    final dropped = _queue.where(drop).toList();
    _queue.removeWhere(drop);
    for (final job in dropped) {
      _completeDrop(job, status);
    }
  }

  void _completeDrop(_ModelJob job, ModelRunStatus status,
      [PlatformException? error, StackTrace? stack]) {
    if (job.result.isCompleted) return;
    if (status == ModelRunStatus.cancelled &&
        job.priority == ModelPriority.foreground) {
      job.result.completeError(
          error ?? PlatformException(code: 'llama_cancelled'), stack);
    } else {
      job.result.complete(ModelRunOutcome(status));
    }
  }

  void _writeLog(String message) {
    try {
      _log(message);
    } catch (_) {
      // Diagnostics must never hold the worker or strand a queued caller.
    }
  }

  static void _defaultLog(String message) =>
      developer.log(message, name: 'ModelScheduler');
}

extension on Stopwatch {
  Duration elapsedGetter() => elapsed;
}

class _ModelJob {
  _ModelJob(this.prompt, this.priority, this.engine, this.turn, this.key,
      this.onRaw, this.onText);

  final Prompt prompt;
  final ModelPriority priority;
  final LlmEngine engine;
  final int turn;
  final String? key;
  final void Function(String)? onRaw;
  final void Function(String)? onText;
  final result = Completer<ModelRunOutcome>();
  final finished = Completer<void>();
  bool cancelled = false;
  String? lastText;
}

class _Cancellation {
  final result = Completer<ModelCancellationResult>();
  ModelCancellationResult? failure;
  Timer? timer;
}
