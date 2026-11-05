import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/repos.dart';
import '../mascot/mascot_emotion.dart';
import 'authorization.dart';
import 'batch.dart';
import 'calculator.dart';
import 'core_policy.dart';
import 'engine.dart';
import 'follow_through.dart';
import 'model_scheduler.dart';
import 'rule_engine.dart';
import 'semantic.dart';
import 'temporal.dart';
import 'tools.dart';
import 'turn_contract.dart';

export 'turn_contract.dart'
    show
        Interpreter,
        InterpreterComparison,
        TurnRecord,
        RouteId,
        CandidatePlan,
        ExecutionReceipt,
        ReceiptStatus,
        AlarmStatus;

part 'session/session_pending.dart';
part 'session/session_batch.dart';
part 'session/session_semantic.dart';
part 'session/session_history.dart';
part 'session/session_reply.dart';
part 'session/session_receipts.dart';
part 'session/session_commit.dart';
part 'session/session_mood.dart';

enum SessionState {
  idle,
  initializing,
  listening,
  transcribing,
  processing,
  executing,
  speaking,
  shuttingDown
}

const _allowed = <SessionState, Set<SessionState>>{
  SessionState.idle: {SessionState.initializing},
  SessionState.initializing: {
    SessionState.listening,
    SessionState.shuttingDown
  },
  SessionState.listening: {
    SessionState.transcribing,
    SessionState.processing,
    SessionState.shuttingDown
  },
  SessionState.transcribing: {
    SessionState.processing,
    SessionState.listening,
    SessionState.shuttingDown
  },
  SessionState.processing: {
    SessionState.executing,
    SessionState.speaking,
    SessionState.listening,
    SessionState.shuttingDown
  },
  SessionState.executing: {
    SessionState.speaking,
    SessionState.listening,
    SessionState.shuttingDown
  },
  SessionState.speaking: {SessionState.listening, SessionState.shuttingDown},
  SessionState.shuttingDown: {SessionState.idle},
};

/// Max tasks put into a prompt; more are marked as partial context.
const _taskCap = 10;

/// Model calls one interpretation may make. Inference is greedy and grammar
/// constrained, so an identical prompt is never sent twice in a turn (its
/// earlier output is reused); no repair/retry call exists.
class _ModelBudget {
  static const maxPlan = 1, maxReply = 2;
  int plan = 0, reply = 0;
  final _seen = <String, String>{};
}

/// One conversation = one session. The LLM is shared and owned by AppServices
/// (never unloaded here). All inference/action flow goes through the explicit
/// state machine above.
///
/// A turn: the message is read for its [Authorization]; the active
/// [Interpreter] picks exactly one route ([RouteId]), whose handler returns a
/// [CandidatePlan] without writing anything; [validatePlan] accepts it or
/// substitutes a no-write reply; then the plan commits through
/// [ToolExecutor.run] (the only writer), which returns one
/// [ExecutionReceipt] per call. Each submitted turn has an operation id
/// journaled in [operations], so a retry never repeats a committed write.
class AssistantSession {
  final LlmEngine engine;

  /// Reads every time against [_now]: one instant per submitted turn.
  late final RuleEngine _fallback = RuleEngine(clock: _now);
  final ToolExecutor tools;
  final MemoryRepo memory;
  final ProfileRepo profile;
  final TaskRepo taskRepo;
  final ConversationRepo conversations;
  final Duration idleTimeout;
  final void Function()? onIdleTimeout;
  final DateTime Function() clock;

  /// Loads the shared engine (single owner: AppServices). Defaults to [engine].load.
  final Future<bool> Function()? loadEngine;

  /// TTS extension point: called in SPEAKING state; await playback completion.
  final Future<void> Function(String text)? speak;

  /// Which interpreter chooses routes ([defaultInterpreter] unless given).
  /// Both share the validator, executor, receipts and journal; only the
  /// active one ever writes ([compareInterpreters] runs both read-only).
  final Interpreter interpreter;

  /// Durable operation identity per submitted turn; null = not journaled.
  final OperationJournal? operations;

  /// Per-turn mood persistence; null (tests) keeps moods in memory only.
  final MoodRepo? moods;

  /// Every model generation of this session goes through it. AppServices
  /// passes its single app-wide instance, so chat and voice sessions (each
  /// with its own engine) never overlap in this isolate and a turn in one
  /// preempts optional work of another. Null (tests) = a private scheduler.
  final ModelScheduler models;

  /// Conversation id (`conversations.session_id` / `chats.id`).
  final String id;
  final state = StreamController<SessionState>.broadcast();
  SessionState _s = SessionState.idle;
  SessionState get current => _s;
  Timer? _idle;
  String engineInUse = '';

  /// Why the last turn used built-in rules instead of the loaded model, or null.
  String? lastFallbackReason;

  /// Milliseconds per phase of the last turn (route/context/execution/total).
  /// Durations only, never message text.
  Map<String, int> lastTiming = const {};

  /// The in-flight or completed optional mood job for the last turn, if dispatched.
  Future<void>? lastOptionalMoodJob;

  /// The last turn's accepted plan, validation and receipts (null: none ran,
  /// e.g. cancelled before commit or a replayed retry).
  TurnRecord? lastTurn;

  /// The operation id of the last submitted turn; [handle] with the same id
  /// and message is a retry of that turn.
  String? lastOperationId;

  /// `conversations.id` of the user message row the last submitted turn
  /// persisted, or null when no row was created (a replayed retry, or a turn
  /// that failed before the transcript write). The caller's optimistic user
  /// message reconciles with this id at completion, so its mood record —
  /// keyed by the same row — stays attached without matching by text or
  /// picking the newest row globally.
  int? lastUserRowId;

  /// Live turn plumbing, wired by [handle]:
  /// [_streamSink] takes the cumulative user-visible reply text as the model
  /// produces it (real streamed output, not a post-hoc typewriter reveal);
  /// [_moodSink] takes the turn's validated mood record once the model's
  /// mood envelope has arrived. Both stop with the turn; nothing fires after
  /// cancellation, and a final callback supersedes the draft.
  void Function(String liveText)? _streamSink;
  void Function(TurnMood mood)? _moodSink;

  /// `conversations.id` of this turn's user message row (the mood anchor).
  int? _userRowId;

  /// The in-flight mood persistence write of this turn, if any. The turn's
  /// completion awaits it, so a crash after [handle] resolves cannot lose the
  /// reading: by then the row is committed or its failure was swallowed with
  /// the display already updated.
  Future<void>? _moodSave;

  /// True once this turn's mood event has been emitted (first wins).
  bool _moodEmitted = false;

  /// The last live text sent this turn; '' = none (or the draft was cleared).
  String _liveSent = '';

  /// True once the streaming gate found an established violation: the checks
  /// the final text must pass are monotone over cumulative text, so a
  /// decidable failure cannot recover. Undecidable suffixes (numbers or
  /// action-verb words still arriving) are held, not judged.
  bool _streamBlocked = false;

  /// The running turn's timing map and clock, for first-visible-text and
  /// mood-arrival measurements written from deep inside the routes.
  Map<String, int>? _timing;
  final Stopwatch _turnClock = Stopwatch();

  /// Appended to this turn's reply (disclosed defaults, a replaced draft).
  String? _note;

  /// Put before this turn's reply (e.g. "Due tomorrow" over list rows).
  String? _header;

  /// Put before this turn's reply (an outcome noted alongside a new reminder).
  String? _prefix;

  /// The model's own follow-up (plan `reply`), shown after the app's exact
  /// confirmation when this turn's accepted plan wrote something.
  String? _modelLine;

  /// What an event is about, given with its time ("3pm, it's about the
  /// budget"); stored on the event once it is created.
  String? _subject;

  /// This turn's own early-alert offset ("15 minutes before"), see [leadOverride].
  int? _leadMin;

  /// The message as typed (before any [leadOverride] stripping).
  String _said = '';

  /// When the current turn was submitted. Every relative time ("in 10 min")
  /// resolves against it, however long model inference takes.
  DateTime? _turnNow;

  /// The current turn's submission time; the clock between turns.
  DateTime _now() => _turnNow ?? clock();

  /// Where the open clarification is stored; null keeps it in memory (tests).
  final PendingRepo? pending;

  /// Evening-review participation: a task the user talks about is answered.
  final ReviewRepo? review;
  String? _memDraft, _memPick;
  String? _memBatch, _batchUpdate;
  bool _batchTouched = false, _batchHandled = false;

  /// The task this chat last created/changed (from SQLite ids), for "that one".
  /// Cleared when a list or "Which one?" was shown: a pronoun then must ask.
  int? _lastTask;

  /// Per-turn debug facts, no message text: model called/used/invalid/failed/
  /// unavailable, the semantic intent, the tool run and whether the DB write
  /// or read succeeded. Printed with the timing; never sent anywhere.
  ///
  /// `route` names the path that produced the action: explicit_memory, early,
  /// complaint, follow_through, negated_cancel, semantic, rules, rule_plan,
  /// retry_replay or retry_recover (`route_id` is the exact [RouteId]).
  /// `fallback` is a code for why the model's plan was not used; `prompt` is
  /// the plan contract:fingerprint when the model was called. `auth` is the
  /// app's [Authorization], `validation` the validator verdict, `receipt`
  /// the main call's [ReceiptStatus], `op` the operation id.
  Map<String, String> lastDiagnostics = const {};
  var _diag = <String, String>{};

  /// Build/model identity merged into every turn's diagnostics (AppServices).
  final Map<String, String> Function()? modelDiagnostics;

  Future<void>? _starting;
  Future<String>? _active;
  Future<List<String>>? _closing;
  bool _closeRequested = false, _cancelled = false;
  final _saved = <String>[];

  /// Hook for backup import (SessionRegistry): while true, [handle] refuses
  /// new turns so nothing writes during a restore.
  bool writesPaused = false;

  /// Hook for backup import: a turn (or read-only comparison) is in flight.
  bool get hasActiveTurn => _active != null;

  // ---- per-interpretation state (reset by [_resetTurn]) ----
  late Interpreter _mode = interpreter;
  String _op = '';
  RouteId? _routeId;
  var _effects = <ToolCall>[];
  var _changes = <PendingChange>[];
  var _evidence = <String, String>{};
  ToolCall? _memoryEffect;
  String? _modelAuth;
  bool _dryRun = false, _pickStored = false;
  late final CorePolicy _corePolicy;
  bool _scopeRefused = false;
  bool _persistedOutside = false;
  var _budget = _ModelBudget();
  var _auth = const AuthorizationReading(Authorization.statement, '');
  static final _rand = Random();
  int _generationEpoch = 0;

  /// Test-only barrier invoked once after planning, immediately before commit.
  FutureOr<void> Function()? onBeforeCommit;

  /// Marks the in-flight turn cancelled without awaiting settlement.
  /// Used by evaluation for deterministic `cancel: before_commit`.
  void markCancelled() => _cancelled = true;

  AssistantSession({
    required this.engine,
    required this.tools,
    required this.memory,
    required this.profile,
    required this.taskRepo,
    required this.conversations,
    String? conversationId,
    DateTime Function()? clock,
    this.idleTimeout = const Duration(seconds: 60),
    this.onIdleTimeout,
    this.speak,
    this.loadEngine,
    this.pending,
    this.review,
    this.modelDiagnostics,
    this.operations,
    this.moods,
    ModelScheduler? modelScheduler,
    Interpreter? interpreter,
    CorePolicyStore? policyStore,
  })  : id = conversationId ?? ConversationRepo.newChatId(),
        models = modelScheduler ?? ModelScheduler(),
        clock = clock ?? DateTime.now,
        interpreter = interpreter ?? defaultInterpreter {
    _corePolicy = CorePolicy(store: policyStore, chatId: id);
  }

  void _go(SessionState n) {
    if (!_allowed[_s]!.contains(n)) {
      throw StateError('illegal transition $_s -> $n');
    }
    _s = n;
    state.add(n);
  }

  Future<void> start() {
    if (_s != SessionState.idle) {
      return Future.error(StateError('start() while $_s'));
    }
    _closing = null;
    _closeRequested = false;
    return _starting = _start();
  }

  Future<void> _start() async {
    _go(SessionState.initializing);
    bool ok;
    try {
      ok = await (loadEngine ?? engine.load)();
    } catch (_) {
      ok = false;
    }
    engineInUse = ok ? engine.name : _fallback.name;
    if (_closeRequested) return; // close() finishes the transition
    _go(SessionState.listening);
    _armIdle();
  }

  void _armIdle() {
    _idle?.cancel();
    _idle = Timer(idleTimeout, () => onIdleTimeout?.call());
  }

  /// [ModelScheduler.noteTurn]; a disposed scheduler (app teardown) only
  /// rejects model calls, it never fails a rule-only turn.
  int _noteSchedulerTurn() {
    try {
      return models.noteTurn();
    } on StateError {
      return models.currentTurn;
    }
  }

  void _noteSchedulerActivity() {
    try {
      models.noteActivity();
    } on StateError {
      // disposed: nothing left to schedule
    }
  }

  /// Handles one finalized utterance (typed now, ASR transcript later).
  /// [onText] gets the cumulative reply text (streamed from the model when it
  /// answers in prose, then the final reply). [onStream] gets the cumulative
  /// visible reply while the model is still generating — chunks replace the
  /// caller's draft, and the final [onText] supersedes them. [onMood] gets
  /// the turn's validated mood record as soon as the model's mood envelope
  /// completes (before the reply is finished); it fires at most once per
  /// turn and never after [cancel]. Returns '' when [cancel]led before any
  /// action ran.
  ///
  /// [operationId]: omit for a new message (a fresh id is made; see
  /// [lastOperationId]). Passing an earlier turn's id with the same message
  /// retries that turn: a final result is replayed, an interrupted write is
  /// finished from its journaled action without repeating committed rows,
  /// and a turn interrupted before any write runs again. A different message
  /// with a used id is rejected. A newly sent similar message is never a
  /// retry.
  Future<String> handle(String text,
      {void Function(String)? onText,
      void Function(String)? onStream,
      void Function(TurnMood mood)? onMood,
      String? operationId}) {
    text = text.trim();
    if (text.isEmpty) return Future.value('');
    if (writesPaused) {
      return Future.error(StateError('writes are paused for a backup import'));
    }
    if (_s != SessionState.listening || _closeRequested || _active != null) {
      return Future.error(StateError('session is not listening ($_s)'));
    }
    _idle?.cancel();
    _cancelled = false;
    lastFallbackReason = null;
    lastTiming = const {};
    lastTurn = null;
    lastUserRowId = null;
    _resetTurn(text);
    _streamSink = onStream;
    _moodSink = onMood;
    _op = operationId ?? _newOpId();
    lastOperationId = _op;
    final op = _turn(text, onText);
    _active = op;
    return op.whenComplete(() {
      _active = null;
      _turnNow = null;
      _streamSink = null;
      _moodSink = null;
    });
  }

  String _newOpId() => '${clock().microsecondsSinceEpoch.toRadixString(36)}-'
      '${_rand.nextInt(1 << 32).toRadixString(36)}';

  static String _hash(String text) =>
      sha256.convert(utf8.encode(text)).toString().substring(0, 16);

  void _resetTurn(String text, {Interpreter? mode, bool dryRun = false}) {
    _generationEpoch++;
    _batchUpdate = null;
    _batchTouched = true;
    _batchHandled = false;
    _note = null;
    _header = null;
    _prefix = null;
    _modelLine = null;
    _subject = null;
    _leadMin = null;
    // "not tonight, but remind me…": the request after "but" is the turn.
    if (readBatch(text) == null) {
      text = RuleEngine.contrastRequest(text) ?? text;
    }
    _said = text;
    _turnNow = _now();
    _userRowId = null;
    _moodEmitted = false;
    _liveSent = '';
    _streamBlocked = false;
    _moodSave = null;
    _timing = null;
    // A reset turn has nowhere to stream to: compareInterpreters' dry runs
    // must never leak live events into a previous handle's caller.
    _streamSink = null;
    _moodSink = null;
    _turnClock
      ..reset()
      ..start();
    _diag = {};
    _mode = mode ?? interpreter;
    _dryRun = dryRun;
    _routeId = null;
    _effects = [];
    _changes = [];
    _evidence = {};
    _memoryEffect = null;
    _modelAuth = null;
    _pickStored = false;
    _scopeRefused = false;
    _persistedOutside = false;
    _budget = _ModelBudget();
    _auth = readAuthorization(text);
  }

  /// Persisted outside answers stay read-only even if a tool plan was produced.
  CandidatePlan _readOnlyOutside(CandidatePlan plan, String text) {
    _memoryEffect = null;
    _effects = [];
    _changes = [];
    if (!plan.writes && plan.call.tool == 'respond') {
      final raw = plan.call.args['text'] as String? ?? '';
      return CandidatePlan(
        interpreter: plan.interpreter,
        route: plan.route,
        call: _say(_corePolicy.concise(raw, text)),
        authorization: plan.authorization,
        modelAuthorization: plan.modelAuthorization,
      );
    }
    final fallback = plan.call.tool == 'respond'
        ? (plan.call.args['text'] as String? ?? '')
        : "Here's what I can say about that.";
    return CandidatePlan(
      interpreter: plan.interpreter,
      route: plan.route,
      call: _say(_corePolicy.concise(fallback.trim(), text)),
      authorization: plan.authorization,
      modelAuthorization: plan.modelAuthorization,
    );
  }

  static const _final = {
    OperationJournal.committed,
    OperationJournal.replied,
    OperationJournal.noWrite,
  };

  bool _hasFinalReceipt(Operation op) {
    if (op.receipt == null) return false;
    if (_final.contains(op.status)) return true;
    if (op.status != OperationJournal.recoveryUnresolved) return false;
    // Withholding memory must not turn a failed independent action into a
    // final result. Such retries still recover that action from the journal.
    final receipts = (jsonDecode(op.receipt!) as Map)['receipts'] as List?;
    return receipts != null &&
        !receipts.any((r) =>
            r is Map &&
            r['tool'] != 'save_memory' &&
            r['status'] == ReceiptStatus.failed.name);
  }

  Future<String> _turn(String text, void Function(String)? onText) async {
    _go(SessionState.processing);
    final total = Stopwatch()..start();
    final timing = <String, int>{};
    _timing = timing;
    final journal = operations;
    journal?.registerActive(_op);
    void Function()? moodJob;
    // App-wide: drops queued optional work and cancels a running optional
    // job on whichever engine owns it (any session). Foreground generation
    // waits for that cancellation inside the scheduler; a rule-only turn
    // does not. The token keeps this turn's mood job from outliving a newer
    // turn in any session.
    final schedulerTurn = _noteSchedulerTurn();
    try {
      final hash = _hash(text);
      final prior = journal == null ? null : await journal.get(_op);
      if (prior != null && (prior.textHash != hash || prior.chatId != id)) {
        throw ArgumentError('operation $_op belongs to a different message');
      }
      _diag['op'] = _op;
      if (prior != null && _hasFinalReceipt(prior)) {
        return await _replay(prior, onText);
      }
      if (prior == null) {
        _userRowId = journal == null
            ? await conversations.add(id, 'user', text)
            : await journal.beginTurn(_op, id, hash, text);
      } else {
        // Durable identity only. Legacy rows stay unlinked; never find a
        // replacement by newest row, matching content, or timestamp.
        final source = await MemoryWriteSource.forOperation(journal!.db, _op);
        _userRowId = source?.messageId;
      }
      lastUserRowId = _userRowId;
      _diag['interpreter'] = _mode.name;
      _diag['auth'] = _auth.kind.name;
      var status = OperationJournal.noWrite;
      String reply;
      try {
        final route = Stopwatch()..start();
        final recovering = (prior?.status == OperationJournal.executing ||
                prior?.status == OperationJournal.committed ||
                prior?.status == OperationJournal.recoveryUnresolved) &&
            prior?.action != null;
        final CandidatePlan plan;
        if (recovering) {
          // Crashed while writing: finish the journaled validated action;
          // rows it already committed are found by their op id, not redone.
          plan = CandidatePlan.fromActionJson(prior!.action!, _mode, _auth);
          // The turn's memory write, journaled beside the plan (plan 1.3),
          // replays with its original arguments and observation time.
          final journaledMemory = (jsonDecode(prior.action!) as Map)['memory'];
          if (journaledMemory is Map) {
            _memoryEffect =
                decodeCall(Map<String, Object?>.from(journaledMemory));
          }
          _routeId = RouteId.retryRecover;
          _diag['route'] = routeName(RouteId.retryRecover);
          _note = plan.note;
          _header = plan.header;
          _prefix = plan.prefix;
        } else {
          plan = await _plan(text, onText, timing);
        }
        timing['route'] ??= route.elapsedMilliseconds;
        final prepared =
            _persistedOutside ? _readOnlyOutside(plan, text) : plan;
        final beforeCommit = onBeforeCommit;
        onBeforeCommit = null;
        if (beforeCommit != null) await beforeCommit();
        if (_cancelled && !recovering) {
          await _abandon(journal);
          return '';
        }
        reply = await _commit(prepared, text, timing, journal,
            recovering: recovering);
        if (lastTurn!.receipts.any((r) => r.wrote)) {
          status = OperationJournal.replied;
        }
      } on ToolError catch (e) {
        if (_cancelled) {
          await _abandon(journal);
          return '';
        }
        reply = e.message;
        status = OperationJournal.failed;
      }
      if (lastTurn?.receipts.any((r) => r.error == memoryRecoveryUnresolved) ==
          true) {
        status = OperationJournal.recoveryUnresolved;
        _diag['memory'] = 'recovery_unresolved';
        if (!reply.contains(_memoryRecoveryWithheld)) {
          reply = '$reply $_memoryRecoveryWithheld';
        }
      }
      if (_header != null) reply = '$_header:\n$reply';
      if (_prefix != null) reply = '$_prefix $reply';
      if (_note != null) reply = '$reply $_note';
      if (_modelLine != null &&
          status != OperationJournal.failed &&
          lastTurn?.receipts.any((r) => r.wrote) == true) {
        reply = '$reply $_modelLine';
        _diag['reply'] = 'model_line';
      }
      if (journal == null) {
        await conversations.add(id, 'assistant', reply);
      } else {
        await journal.publishReply(
            _op, reply, status, {...?lastTurn?.toJson(), 'reply': reply});
      }
      onText?.call(reply);
      _go(SessionState.speaking);
      if (!_cancelled) await speak?.call(reply);

      // Foreground confirmation settles before optional mood; mood work runs with
      // captured immutable inputs without delaying or blocking foreground replies.
      // Dispatched at the end of `finally`, after this turn's diagnostics are
      // final, so the job's mood diagnostics are never overwritten by them.
      if (!_scopeRefused &&
          !_batchHandled &&
          _budget.plan + _budget.reply == 0 &&
          !_dryRun &&
          !_cancelled &&
          engineInUse == engine.name &&
          engine is! RuleEngine &&
          !_mechanicalRoutes.contains(_routeId)) {
        final opId = _op, rowId = _userRowId, sink = _moodSink;
        moodJob = () => _dispatchOptionalMood(
              text: text,
              opId: opId,
              userRowId: rowId,
              moodSink: sink,
              schedulerTurn: schedulerTurn,
            );
      }
      return reply;
    } finally {
      timing['total'] = total.elapsedMilliseconds;
      try {
        await _moodSave; // the mood row is committed before the turn settles
      } catch (_) {}
      lastTiming = Map.unmodifiable(timing);
      _timing = null;
      _diag['model_calls'] = '${_budget.plan}p${_budget.reply}r';
      if (_moodEmitted) {
        _diag['mood'] = 'emitted';
      } else if (_budget.plan + _budget.reply > 0) {
        _diag['mood'] = 'unknown'; // model ran, no valid envelope came back
      }
      try {
        _diag.addAll(modelDiagnostics?.call() ?? const {});
      } catch (_) {} // diagnostics never fail a turn
      lastDiagnostics = Map.unmodifiable(_diag);
      debugPrint('turn timing ms: $lastTiming $lastDiagnostics');
      if (_s != SessionState.listening) _go(SessionState.listening);
      if (!_closeRequested) _armIdle();
      journal?.unregisterActive(_op);
      _noteSchedulerActivity(); // speech/rules ended: background idle restarts
      if (moodJob != null && !_cancelled && !_closeRequested) moodJob();
    }
  }

  /// Inputs whose answer is purely mechanical; spending a model call to read
  /// a mood from "#3" or "in 20 minutes" would only add latency.
  static const _mechanicalRoutes = {
    RouteId.calculator,
    RouteId.pendingPick,
    RouteId.pendingAnswer,
  };

  // ---- interpretation: one route -> a candidate plan, no writes ----

  Future<CandidatePlan> _plan(String text, void Function(String)? onText,
      Map<String, int> timing) async {
    final batch = readBatch(text);
    if (batch == null) text = RuleEngine.contrastRequest(text) ?? text;
    final hasPending = await _draft() != null;
    final hasBatch = batch != null || await _loadBatch() != null;
    final isCalc = calculate(text) != null;
    // Pending answers and arithmetic keep route precedence but still advance
    // policy so an outside topic does not linger across them.
    if (hasPending || hasBatch || isCalc) {
      _corePolicy.noteCoreTurn();
      _scopeRefused = false;
      _persistedOutside = false;
    } else {
      final decision = _corePolicy.evaluate(text);
      _scopeRefused = decision == ScopeDecision.refuse;
      _persistedOutside = decision == ScopeDecision.persistedOutside;
    }
    if (_scopeRefused) {
      _routeId = RouteId.rules;
      _diag['route'] = 'scope';
      _diag['route_id'] = _routeId!.name;
      return CandidatePlan(
          interpreter: _mode,
          route: _routeId!,
          call: _say(CorePolicy.refusal),
          authorization: _auth);
    }
    final explicit = batch == null && RuleEngine.isExplicitRemember(text);
    var memo = batch != null ? null : _memoryCandidate(text, explicit);
    // Plan 1.5: an instruction for the assistant is not a memory. An explicit
    // request is refused below; an implicit candidate is dropped silently and
    // the turn goes on. Nothing is stored either way.
    final memoRejected = batch == null &&
        (explicit || memo != null) &&
        _instructionLikeMemory(text, memo?.content);
    if (memoRejected) {
      memo = null;
      _diag['memory'] = 'instruction_rejected';
    }
    int? memoExpiresAt;
    if (memo != null) {
      final replaces = RuleEngine.correctedObject(text);
      final at = _turnNow ?? _now();
      // Plan 1.4: the same expiry the executor will store from these args
      // (corrections never expire), for the confirmation reply.
      memoExpiresAt = replaces != null
          ? null
          : memoryExpiresAt(memo.content,
              observedAt: at,
              observationOffsetMin: at.timeZoneOffset.inMinutes);
      _memoryEffect = ToolCall('save_memory', {
        'content': memo.content,
        'category': memo.category,
        'source': 'chat:$id',
        if (explicit) 'explicit': true,
        if (replaces != null) 'replaces': replaces,
        // Plan 1.3: when it was said, as integers so a journal replay
        // stores the same instant (see ToolExecutor `save_memory`).
        'observed_at_utc': at.toUtc().millisecondsSinceEpoch,
        'observation_offset_min': at.timeZoneOffset.inMinutes,
      });
    }
    final ToolCall call;
    final forget = RegExp(r'^(?:please\s+)?forget\s+(?:that\s+)?(.+)$',
            caseSensitive: false)
        .firstMatch(text.trim());
    if (batch == null &&
        forget != null &&
        _auth.permitsWrite &&
        !RegExp(r'^(?:it|about it|that|that one|one)$', caseSensitive: false)
            .hasMatch(forget.group(1)!.trim())) {
      _routeId = RouteId.explicitMemory;
      _memoryEffect = null;
      final raw = forget.group(1)!;
      final fact =
          _fallback.extractMemory(raw, timeBound: true)['memory'] as String? ??
              raw;
      final match = await memory.matchForForget(fact);
      if (match.evidence == ForgetEvidence.exact ||
          match.evidence == ForgetEvidence.slot) {
        _evidence['target'] = match.evidence == ForgetEvidence.exact
            ? 'exact_memory'
            : 'slot_memory';
        call = ToolCall('delete_memory', {'id': match.memories.single.id});
      } else if (match.evidence == ForgetEvidence.candidates) {
        _setPick(TargetPick(
            tool: 'delete_memory',
            args: const {},
            ids: match.memories.map((m) => m.id).toList(),
            askedAt: _now()));
        call = _say('Which memory should I forget?\n'
            '${match.memories.map((m) => '#${m.id} ${m.content}').join('\n')}');
      } else {
        call = _say(!match.severalMatch
            ? "I couldn't identify that saved memory. You can review or delete it in Memories."
            : 'Several memories match. Please choose one in Memories.');
      }
    } else if (explicit) {
      _routeId = RouteId.explicitMemory;
      timing['route'] = 0;
      // The memory is written (as an effect) before this reply is shown.
      call = _say(memoRejected
          ? memoryInstructionRefusal
          : memo != null
              ? (memoExpiresAt == null
                  ? "Okay, I'll remember that."
                  : "Okay, I'll remember that through "
                      '${_lastDayBefore(memoExpiresAt, _turnNow ?? _now())}.')
              : (RuleEngine.isTemporary(text)
                  ? "I won't store short-lived plans as memories. Want a reminder or task instead?"
                  : "That's too long for me to remember; try a shorter sentence."));
    } else {
      final grounded = batch != null ? null : await _groundedTurn(text);
      if (grounded != null) {
        _routeId = RouteId.rules;
        call = grounded;
      } else {
        call = await _adjust(_mode == Interpreter.legacy
            ? await _route(text, onText, timing)
            : await _coordinate(text, onText, timing));
      }
    }
    _diag['route'] = routeName(_routeId!);
    _diag['route_id'] = _routeId!.name;
    return CandidatePlan(
      interpreter: _mode,
      route: _routeId!,
      call: call,
      effects: List.of(_effects),
      pending: List.of(_changes),
      evidence: _evidenceFor(call),
      authorization: _auth,
      modelAuthorization: _modelAuth,
      clarify: _diag['clarify'],
      note: _note,
      header: _header,
      prefix: _prefix,
    );
  }

  /// Narrow app-grounded cases: questions never inherit a model mutation,
  /// and unresolved references ask before acting.
  Future<ToolCall?> _groundedTurn(String text) async {
    RegExpMatch? match;
    RegExp ci(String value) => RegExp(value, caseSensitive: false);
    if ((match =
            ci(r'^(?:am i done with|have i (?:finished|completed)|did i (?:finish|complete)) (.+?)[?!.]*$')
                .firstMatch(text.trim())) !=
        null) {
      final hits = await _matching(
          match!.group(1)!, await taskRepo.list(includeDone: true));
      return _say(hits.isEmpty
          ? 'Which task do you mean?'
          : hits
              .map((t) =>
                  '#${t.id} ${t.title}: ${t.done ? 'done' : 'still pending'}')
              .join('\n'));
    }
    if ((match = ci(r'^did i (?:already )?(?:add|save) (.+?)[?!.]*$')
            .firstMatch(text.trim())) !=
        null) {
      final words = keyWords(match!.group(1)!);
      final hits = (await taskRepo.list(includeDone: true))
          .where((t) => keyWords(t.title).intersection(words).isNotEmpty)
          .toList();
      return _say(hits.isEmpty
          ? 'I could not find that task.'
          : hits.map(_line).join('\n'));
    }
    if (ci(r'^(?:did you (?:set|save|schedule)|is it (?:set|saved|scheduled))(?: (?:it|that))?[?!.]*$')
        .hasMatch(text.trim())) {
      final upcoming = await tools.reminders.upcoming();
      final last = upcoming.lastOrNull;
      if (last != null) {
        String? issue;
        try {
          issue = await tools.scheduler.deliveryIssue();
        } catch (_) {}
        if (issue != null) {
          return _say(
              'Saved the reminder for ${friendlyTime(last.triggerAt, _now())}: ${last.title}, but $issue so it is not scheduled to alert until enabled.');
        } else {
          return _say(
              'Yes, I set the reminder for ${friendlyTime(last.triggerAt, _now())}: ${last.title}.');
        }
      }
    }
    if (_auth.kind == Authorization.hypothetical ||
        _auth.kind == Authorization.question) return null;
    if ((match =
            ci(r'^i (?:don.t|do not|no longer) need to (.+?)(?: anymore)?[.!]*$')
                .firstMatch(text.trim())) !=
        null) {
      final hits = await _matching(match!.group(1)!, await taskRepo.list());
      if (hits.isEmpty) return _say('Which task should I remove?');
      _setPick(TargetPick(
          tool: 'delete_task',
          args: const {},
          ids: hits.map((t) => t.id).toList(),
          askedAt: _now()));
      return _say(
          'Should I remove this task?\n${hits.map(_line).join('\n')}\nSay its number to confirm; otherwise it stays.');
    }
    if ((match =
            ci(r'^(?:please )?get rid of (.+)$').firstMatch(text.trim())) !=
        null) {
      final hits = await taskRepo.list();
      if (hits.isNotEmpty)
        _setPick(TargetPick(
            tool: 'delete_task',
            args: const {},
            ids: hits.map((t) => t.id).toList(),
            askedAt: _now()));
      return _say(
          'Which task should I remove?${hits.isEmpty ? '' : '\n${hits.take(10).map(_line).join('\n')}'}');
    }
    if ((match =
            ci(r'^(?:move|change|postpone|push|reschedule)(?: the| my)? (.+?) to (.+?) same time[.!]*$')
                .firstMatch(text.trim())) !=
        null) {
      final day = _fallback.readWhen(match!.group(2)!);
      if (day.conflict || day.unsupported || day.at == null)
        return _say('Which day should I move it to?');
      _evidence['time'] = 'said day and stored clock';
      return await _byRef('edit_task', {'due': day.at, 'keep_time': true},
              match.group(1)!) ??
          _say('Which task should I move?');
    }
    if ((match = ci(r'^sometime (.+?) i (?:need|have) to (.+)$')
            .firstMatch(text.trim())) !=
        null) {
      final draft = ClarifyDraft(
          tool: 'create_task', title: RuleEngine.cleanTitle(match!.group(2)!));
      await _setDraft(draft);
      return _say(draft.prompt);
    }
    if (ci(r'\b(?:finally sent|got cancelled|got canceled)\b').hasMatch(text) &&
        !hasCommandWord(text)) {
      final hits = named(await taskRepo.list(), text);
      if (hits.isNotEmpty) {
        _setPick(TargetPick(
            tool: 'complete_task',
            args: const {},
            ids: hits.map((t) => t.id).toList(),
            askedAt: _now()));
        return _say(
            'Should I mark this complete and stop its alerts?\n${hits.map(_line).join('\n')}\nSay its number to confirm.');
      }
    }
    return null;
  }

  /// The pre-P2 route chain, kept as the legacy interpreter: early replies,
  /// lead override, complaints, follow-through, the plan-v1 model, rules,
  /// then the read-only rule plan.
  Future<ToolCall> _route(String text, void Function(String)? onText,
      Map<String, int> timing) async {
    final route = Stopwatch()..start();
    final early = await _early(text);
    if (early != null) {
      timing['route'] = route.elapsedMilliseconds;
      return early;
    }
    final batch = await _batchRoute(text);
    if (batch != null) {
      _routeId = RouteId.pendingAnswer;
      timing['route'] = route.elapsedMilliseconds;
      return batch;
    }
    final lead = leadOverride(text, _now());
    if (lead != null) {
      _leadMin = lead.minutes;
      text = lead.text;
    }
    if (isComplaint(text) && !_isCommand(text)) {
      timing['route'] = route.elapsedMilliseconds;
      _routeId = RouteId.complaint;
      return _complaint();
    }
    final follow = await _followThrough(text);
    timing['route'] = route.elapsedMilliseconds;
    if (follow != null) return follow;
    if (engineInUse == engine.name && engine is! RuleEngine) {
      final c = await _semantic(text, timing);
      if (c != null) {
        _routeId = RouteId.semantic;
        return c;
      }
    } else {
      _diag['model'] = 'unavailable';
      _diag['fallback'] = 'engine_not_in_use';
    }
    final rules = await _rules(text);
    if (rules != null) {
      _routeId = RouteId.rules;
      return rules;
    }
    _routeId = RouteId.rulePlan;
    return _rulePlanCall(text);
  }

  /// The unified coordinator: one route table in explicit priority order
  /// ([RouteId]); the first route that handles the message (an action or a
  /// clarification) settles it, every other route is skipped. The lead
  /// override ("remind me 5 minutes before") is a normalization between the
  /// pending-interaction routes and the rest, as in the legacy chain.
  Future<ToolCall> _coordinate(String text, void Function(String)? onText,
      Map<String, int> timing) async {
    final route = Stopwatch()..start();
    var t = text;
    final table = <(RouteId, Future<ToolCall?> Function())>[
      (RouteId.pendingPick, () => _pickRoute(t)),
      (RouteId.calculator, () async => _calcRoute(t)),
      (RouteId.pendingAnswer, () => _pendingAnswerRoute(t)),
      (RouteId.pendingAnswer, () => _batchRoute(t)),
      (
        RouteId.complaint,
        () async {
          final lead = leadOverride(t, _now());
          if (lead != null) {
            _leadMin = lead.minutes;
            t = lead.text;
          }
          return isComplaint(t) && !_isCommand(t) ? _complaint() : null;
        }
      ),
      (RouteId.dailySchedule, () => _dailyRoute(t)),
      (RouteId.eventDetails, () => _detailsRoute(t)),
      (RouteId.eventDone, () => _eventDoneRoute(t)),
      (RouteId.outcome, () => _outcomeRoute(t)),
      (RouteId.progress, () => _progressRoute(t)),
      (RouteId.briefing, () async => _briefingRoute(t)),
      (RouteId.negatedCancel, () => _negatedCancelRoute(t)),
      (
        RouteId.semantic,
        () async {
          timing['route'] = route.elapsedMilliseconds;
          if (engineInUse == engine.name && engine is! RuleEngine) {
            return _semantic(t, timing);
          }
          _diag['model'] = 'unavailable';
          _diag['fallback'] = 'engine_not_in_use';
          return null;
        }
      ),
      (RouteId.rules, () => _rules(t)),
      (RouteId.rulePlan, () async => _rulePlanCall(t)),
    ];
    for (final (id, handler) in table) {
      final c = await handler();
      if (c != null) {
        _routeId = id;
        timing['route'] ??= route.elapsedMilliseconds;
        return c;
      }
    }
    throw StateError('rule plan always handles a message');
  }

  static ToolCall _say(String s) => ToolCall('respond', {'text': s});

  // ---- follow-through: daily schedules, meeting details/outcomes, updates ----

  static final _createCue = RegExp(
      r'\b(?:remind|alert|notify|add|task|need to|have to|must)\b',
      caseSensitive: false);

  /// A clear command the rules would run; never read as an answer or an update.
  bool _isCommand(String text) =>
      _fallback.parseCreate(text) != null ||
      RuleEngine.doneRef(text) != null ||
      _fallback.fastRoute(text)?['type'] == 'tool';

  /// Settled from SQLite before any planning (legacy chain): a daily
  /// schedule, an answer to a task's open question (stored on the task, so
  /// any chat or a restart can answer it, and anything else simply routes
  /// on), a finished meeting, news about existing work, or a briefing.
  /// Null = route normally.
  Future<ToolCall?> _followThrough(String text) async {
    for (final (id, route) in <(RouteId, Future<ToolCall?> Function())>[
      (RouteId.dailySchedule, () => _dailyRoute(text)),
      (RouteId.eventDetails, () => _detailsRoute(text)),
      (RouteId.eventDone, () => _eventDoneRoute(text)),
      (RouteId.outcome, () => _outcomeRoute(text)),
      (RouteId.progress, () => _progressRoute(text)),
      (RouteId.briefing, () async => _briefingRoute(text)),
      (RouteId.negatedCancel, () => _negatedCancelRoute(text)),
    ]) {
      final c = await route();
      if (c != null) {
        _routeId = id;
        return c;
      }
    }
    return null;
  }

  /// "remind me to stretch" -> "daily at 8am".
  Future<ToolCall?> _dailyRoute(String text) async {
    final draft = await _draft();
    final daily = (_createCue.hasMatch(text) || draft != null) &&
            !RuleEngine.isQuestionOrNegated(text)
        ? _fallback.parseDaily(text)
        : null;
    if (daily == null) return null;
    if (daily.problem != null) return _say(daily.problem!);
    final s = daily.schedule!;
    var title = RuleEngine.cleanTitle(_fallback.parseCreate(s.rest)?.title ??
        s.rest.replaceFirst(
            RegExp(r'^\s*(?:please\s+)?(?:remind me|add (?:a )?task:?)\s*',
                caseSensitive: false),
            ''));
    if (title.isEmpty && draft != null) {
      title = draft.title;
      _evidence['title'] = 'pending';
      _clearDraft();
    }
    if (title.isEmpty) return _say('What should I remind you about every day?');
    if (RuleEngine.isMulti(title)) return _say(RuleEngine.multiReply(title));
    if (RuleEngine.hasUnsupportedDate(title)) {
      return _say("I couldn't read all of that schedule, so I saved nothing. "
          'Try e.g. "remind me daily at 8:46 AM until 5 November to take medicine".');
    }
    if (s.note != null) _note = s.note;
    _evidence['time'] = 'daily';
    return ToolCall('create_daily',
        {'title': title, 'minute': s.hour * 60 + s.minute, 'until': s.until});
  }

  Future<ToolCall?> _detailsRoute(String text) async {
    final sentences = _sentences(text);
    if (sentences.length > 1) {
      for (final sentence in sentences) {
        final call = await _detailsRoute(sentence);
        if (call != null) return call;
      }
      return null;
    }
    final details = [
      for (final t in await taskRepo.awaitingAnswers())
        if (t.awaiting == TaskRepo.details && !t.done && t.dueAt != null) t
    ];
    if (details.isEmpty || _isCommand(text)) return null;
    return _details(details, text);
  }

  Future<ToolCall?> _eventDoneRoute(String text) async {
    final done = eventDone(text);
    return done == null ? null : _eventDone(done);
  }

  Future<ToolCall?> _outcomeRoute(String text) async {
    final sentences = _sentences(text);
    if (sentences.length > 1) {
      for (final sentence in sentences) {
        final call = await _outcomeRoute(sentence);
        if (call != null) return call;
      }
      return null;
    }
    final outcomes = [
      for (final t in await taskRepo.awaitingAnswers())
        if (t.awaiting == TaskRepo.outcomeQuestion) t
    ];
    final said = splitRequest(text).outcome;
    if (outcomes.isEmpty ||
        said.isEmpty ||
        !looksLikeOutcome(said) ||
        _isCommand(said)) {
      return null;
    }
    final n = named(outcomes, said);
    if (n.length == 1) return _recordOutcome(n.single, text);
    if (n.isEmpty && outcomes.length == 1 && await _justAsked()) {
      return _recordOutcome(outcomes.single, text);
    }
    if (n.length > 1 ||
        (n.isEmpty && outcomes.length > 1 && await _justAsked())) {
      return _ask('outcome', n.isEmpty ? outcomes : n, text,
          'Which one was that about?');
    }
    return null;
  }

  Future<ToolCall?> _progressRoute(String text) async {
    final sentences = _sentences(text);
    if (sentences.length > 1) {
      for (final sentence in sentences) {
        final call = await _progressRoute(sentence);
        if (call != null) return call;
      }
      return null;
    }
    if (!isProgressUpdate(text) || _isCommand(text)) return null;
    final open = await taskRepo.list();
    var l = named(open, text);
    if (l.isEmpty) {
      // Linked through the user's earlier words in any chat ("Ask Aditya to
      // arrange the client meeting"), never through a guess.
      final related = await _related(text);
      l = [
        for (final t in open)
          if (related.any((m) {
            final k = keyWords(t.title);
            return k.isNotEmpty &&
                keyWords(m.content).intersection(k).length >=
                    (k.length < 2 ? 1 : 2);
          }))
            t
      ];
    }
    if (l.length == 1) return _discuss(l.single, text);
    if (l.length > 1) return _ask('discuss', l, text, 'Which one do you mean?');
    return null;
  }

  static List<String> _sentences(String text) => text
      .split(RegExp(r'(?<=[.!?])\s+|[\r\n]+'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  ToolCall? _briefingRoute(String text) {
    for (final sentence in _sentences(text)) {
      if (isBriefingRequest(sentence) &&
          _fallback.parseCreate(sentence) == null) {
        return ToolCall('briefing', const {});
      }
    }
    return null;
  }

  static final _reminderWord = RegExp(
      r'\b(?:remind|alert|notify|alarm|nudge|ping)',
      caseSensitive: false);

  /// Unified only: "Don't remind me about the meeting" while reminders for
  /// it exist. Nothing is created or cancelled here; the reply names the
  /// saved reminders and a typed pick lets "#12" cancel the intended one.
  Future<ToolCall?> _negatedCancelRoute(String text) async {
    final sentences = _sentences(text);
    if (sentences.length > 1) {
      for (final sentence in sentences) {
        final call = await _negatedCancelRoute(sentence);
        if (call != null) return call;
      }
      return null;
    }
    // "the gym reminder isn't needed, cancel it" asks to drop it: once the
    // not-needed words are set aside nothing is refused ("don't cancel the
    // gym reminder" still is).
    final unneeded = _notNeeded.hasMatch(text) &&
        !RuleEngine.isNegated(text.replaceAll(_notNeeded, ' '));
    if ((readAuthorization(text).kind != Authorization.negated && !unneeded) ||
        !_reminderWord.hasMatch(text)) {
      return null;
    }
    final k = keyWords(text);
    if (k.isEmpty) return null;
    final seen = <int>{};
    final hits = [
      for (final r in await tools.reminders.upcoming())
        if (r.kind == 'reminder' &&
            (r.taskId == null || seen.add(r.taskId!)) &&
            keyWords(r.title).intersection(k).isNotEmpty)
          r
    ];
    if (hits.isEmpty) return null;
    // "don't cancel the gym reminder": the refusal is of cancelling itself.
    if (!unneeded && _cancelVerb.hasMatch(text)) {
      return _say(hits.length == 1
          ? 'Okay, your ${hits.single.title} reminder stays.'
          : 'Okay, those reminders stay.');
    }
    // Said it is not needed and said to cancel it, and only one reminder
    // fits: cancel it. Anything less certain asks first, as below.
    if (unneeded &&
        hits.length == 1 &&
        _cancelVerb.hasMatch(text) &&
        _auth.permitsWrite) {
      _evidence['target'] = 'reminder_words';
      return ToolCall('cancel_reminder', {'id': hits.single.id});
    }
    _setPick(TargetPick(
        tool: 'cancel_reminder',
        args: const {},
        ids: [for (final r in hits) r.id],
        askedAt: _now()));
    _lastTask = null;
    _diag['clarify'] = 'cancel_target';
    final rows = hits
        .take(_taskCap)
        .map(
            (r) => '#${r.id} ${r.title} (${friendlyTime(r.triggerAt, _now())})')
        .join('\n');
    return _say(hits.length == 1
        ? "I haven't set or changed anything. You have this reminder:\n$rows\n"
            'Should I cancel it? Say #${hits.single.id} to cancel it; otherwise it stays.'
        : "I haven't set or changed anything. Which of these should I cancel?\n$rows\n"
            'Say the number, e.g. #${hits.first.id}; otherwise they all stay.');
  }

  /// "Which one?" for a follow-through reply; a bare "#3" finishes it with [text].
  ToolCall _ask(String tool, List<Task> l, String text, String question) {
    _setPick(TargetPick(
        tool: tool,
        args: {'text': text},
        ids: [for (final t in l) t.id],
        askedAt: _now()));
    _lastTask = null;
    return _say('$question\n${l.take(_taskCap).map(_line).join('\n')}\n'
        'Say the number, e.g. #${l.first.id}.');
  }

  /// The last assistant message here asked how something went (or, with
  /// [phrase], asked that question).
  Future<bool> _justAsked([String phrase = 'how did']) async {
    var last = (await conversations.recent(id, n: 3))
        .where((m) => m.role == 'assistant')
        .lastOrNull;
    if (last == null && id != ConversationRepo.mainChatId) {
      last = (await conversations.recent(ConversationRepo.mainChatId, n: 3))
          .where((m) => m.role == 'assistant')
          .lastOrNull;
    }
    return last != null &&
        ((phrase == 'how did' && last.kind == 'follow_up') ||
            last.content.toLowerCase().contains(phrase));
  }

  Future<ToolCall?> _details(List<Task> open, String text) async {
    const asked = 'what is it about';
    if (declinesDetails(text) && open.length == 1 && await _justAsked(asked)) {
      _effects.add(
          ToolCall('set_awaiting', {'id': open.single.id, 'question': null}));
      return _say("No problem, I'll go with the times I have.");
    }
    if (isQuestionLike(text) || RuleEngine.isNegated(text)) return null;
    final d = eventDetails(text, open.first.dueAt!);
    if (d == null) return null;
    // Details only when they name the meeting, follow the question, or
    // speak of "it" with one meeting waiting; "busy until 5" is something else.
    final pronoun = open.length == 1 &&
        RegExp(r"^(?:it|it'?s|its|ends?|until|till|lasts?|runs?)\b",
                caseSensitive: false)
            .hasMatch(text.trim());
    if (!pronoun && named(open, text).isEmpty && !await _justAsked(asked))
      return null;
    final n = open.length == 1 ? open : named(open, text);
    if (n.length == 1) return _applyDetails(n.single, text);
    return _ask('details', n.isEmpty ? open : n, text,
        'Which meeting are those details for?');
  }

  /// Saves end time/subject (executor tool `set_event_details`); a known end
  /// replaces the follow-up estimate. Null = no details in [text].
  Future<ToolCall?> _applyDetails(Task t, String text) async {
    final start = t.dueAt;
    final d = start == null ? null : eventDetails(text, start);
    if (d == null) return null;
    _lastTask = t.id;
    _evidence['target'] ??= 'details_question';
    return ToolCall('set_event_details', {
      'id': t.id,
      if (d.end != null) 'ends_at': d.end,
      if (d.subject != null) 'subject': d.subject,
      if (d.note != null) 'note': d.note,
    });
  }

  /// A finished meeting named in the message: completed by id (several = ask).
  Future<ToolCall?> _eventDone(({String ref, String? outcome}) done) async {
    final open = await taskRepo.list();
    var l = await _matching(done.ref, open);
    final events = l.where((t) => isEventTitle(t.title)).toList();
    if (events.isNotEmpty) l = events; // not the "arrange the meeting" errand
    if (l.isEmpty) return null;
    final args = <String, Object?>{
      if (done.outcome != null) 'outcome': done.outcome
    };
    if (l.length == 1) {
      _evidence['target'] = 'named';
      return ToolCall('complete_task', {...args, 'id': l.single.id});
    }
    _setPick(TargetPick(
        tool: 'complete_task',
        args: args,
        ids: [for (final t in l) t.id],
        askedAt: _now()));
    _lastTask = null;
    return _say(
        'Several tasks match "${done.ref}":\n${l.take(_taskCap).map(_line).join('\n')}\n'
        'Which one? Say the number, e.g. #${l.first.id}.');
  }

  /// Notes how [t] went (effect `record_outcome`); a "remind me…" part
  /// becomes this turn's request.
  Future<ToolCall> _recordOutcome(Task t, String text) async {
    final sp = splitRequest(text);
    _effects.add(sp.outcome.isNotEmpty
        ? ToolCall('record_outcome', {'id': t.id, 'outcome': sp.outcome})
        : ToolCall('review_answered', {'id': t.id}));
    _lastTask = t.id;
    final open = t.done
        ? ''
        : ' It is still open in Tasks; say "complete task #${t.id}" if it is finished.';
    final ack = sp.outcome.isEmpty
        ? ''
        : await _converse(
            sp.outcome,
            [_line(t), if (t.subject != null) 'About: ${t.subject}'],
            'Thanks, I noted how ${t.title} went.',
            'The user said how this went. Acknowledge it warmly in one sentence; if they mention a next step, ask whether they want a reminder for it.');
    if (sp.request != null) {
      final call = await _rules(sp.request!);
      if (call != null) {
        _prefix = '$ack$open'.trim();
        return call;
      }
      return _say(
          '$ack$open I couldn\'t read that reminder; try "remind me to … tomorrow at 10am".'
              .trim());
    }
    return _say(
        '$ack$open${t.done ? ' If anything from it needs a reminder, just tell me.' : ''}');
  }

  /// News about [t] ("Aditya hasn't replied"): talked through, never acted on.
  Future<ToolCall> _discuss(Task t, String text) async {
    _lastTask = t.id;
    _effects.add(ToolCall('review_answered', {'id': t.id}));
    final related = await _related(text);
    final fallback =
        'Thanks for the update on #${t.id} ${t.title}. I haven\'t changed anything. '
        '${t.dueAt == null ? 'Want a reminder to follow up on it?' : 'Want a reminder to follow up, or should I move it?'}';
    return _say(await _converse(
        text,
        [
          'Task: ${_line(t)}',
          if (t.subject != null) 'About: ${t.subject}',
          if (t.outcome != null) 'Earlier outcome: ${t.outcome}',
          for (final m in related) 'Earlier the user said: ${_cut(m.content)}',
        ],
        fallback,
        'The user gave news about this task. Acknowledge it and offer one or two next steps, such as a reminder to follow up or moving it. Nothing has been changed.'));
  }

  static String _cut(String s) => s.length > 160 ? s.substring(0, 160) : s;

  static const _deadlineNote =
      "That's the deadline you gave; tell me if you want an earlier alert.";

  // ---- commit: validate, then the executor is the only writer ----

  /// The rules' and explicit route's memory confirmations ("Okay, I'll
  /// remember that." / "... through Mon 2 Nov."), shown only after a write.
  static final _memoryClaim =
      RegExp(r"^Okay, I'll remember that\b", caseSensitive: false);
  static const _memoryRecoveryWithheld =
      'Memory recovery is unresolved; the earlier memory action was withheld.';
  static const _memoryWriteFailed =
      "I couldn't save that memory just now. Please try again.";

  /// Development only (`--dart-define=CORENYTH_LOG_RAW=true`): logs the
  /// model's raw plan, which quotes the user. Off in every normal build.
  static const _logRaw = bool.fromEnvironment('CORENYTH_LOG_RAW');

  /// Tools whose confirmation may carry the model's follow-up line.
  static const _writes = {
    'create_task',
    'create_reminder',
    'complete_task',
    'delete_task',
    'edit_task',
  };

  /// Commands the semantic schema has no intent for (rename, reminder
  /// edit/cancel/list): a plan can't stand in for them; the rules run them.
  static const _ruleOnly = {
    'edit_reminder',
    'cancel_reminder',
    'list_reminders'
  };

  static String _intentTool(String intent) => switch (intent) {
        'create_task' => 'create_task',
        'create_reminder' => 'create_reminder',
        'complete' => 'complete_task',
        'delete' => 'delete_task',
        'postpone' => 'edit_task',
        'list' => 'list_tasks',
        'recall' => 'search_memory',
        'progress' => 'review_answered',
        'outcome' => 'record_outcome',
        'details' => 'set_event_details',
        _ => 'respond',
      };

  /// A title naming nothing: "finish this", "do it".
  static final _pronounTitle = RegExp(
      r'^(?:(?:finish|complete|do|submit|send|get|wrap up|hand in)\s+)?(?:this|that|it|them|these|those)(?:\s+(?:one|done|up))?$',
      caseSensitive: false);

  static final _stop = {
    'the',
    'my',
    'a',
    'an',
    'to',
    'of',
    'for',
    'with',
    'task',
    'i'
  };
  static Set<String> _words(String s) => {
        for (final w in normTitle(s).split(' '))
          if (w.isNotEmpty && !_stop.contains(w)) RuleEngine.stem(w)
      };

  /// At least half of [phrase]'s words occur in [text] (stems compared):
  /// the model may tidy wording, not invent it.
  /// References need every word ([all]): "bring milk" is not "buying milk".
  static bool _grounded(String phrase, String text, {bool all = false}) {
    final p = _words(phrase), t = _words(text);
    final hits = p.where(t.contains).length;
    return p.isNotEmpty && (all ? hits == p.length : hits * 2 >= p.length);
  }

  /// today/tomorrow named in the message itself (incl. "tomo"), else null.
  String? _rangeIn(String text) {
    if (RegExp(r'\bthis week\b', caseSensitive: false).hasMatch(text))
      return 'week';
    if (RegExp(r'\bafter lunch\b', caseSensitive: false).hasMatch(text) &&
        RegExp(r'\btoday\b', caseSensitive: false).hasMatch(text))
      return 'afternoon_today';
    if (RegExp(r'\boverdue\b', caseSensitive: false).hasMatch(text))
      return 'overdue';
    final at = _fallback.parseWhen(text).$1;
    if (at == null) return null;
    final now = _now();
    final days = DateTime.utc(at.year, at.month, at.day)
        .difference(DateTime.utc(now.year, now.month, now.day))
        .inDays;
    return days == 0
        ? 'today'
        : days == 1
            ? 'tomorrow'
            : null;
  }

  /// Words that ask to be notified, so a create becomes a reminder rather
  /// than a silent task ("ping me at 5", "set a reminder: …").
  static final _notifyAsk = RegExp(
      r'\b(?:remind(?:er|ers)?|alert|notify|alarm|ping|nudge|buzz|heads[- ]?up|wake me|let me know)\b',
      caseSensitive: false);

  static final _reminderNoun =
      RegExp(r'\b(?:reminders?|alarms?|alerts?)\b', caseSensitive: false);

  /// "the gym reminder isn't needed", "I don't need the parcel reminder":
  /// a request to drop it, not a refusal. "no need to cancel it" is the
  /// opposite and never matches.
  static final _notNeeded = RegExp(
      r"\b(?:(?:is|are)n'?t\s+(?:needed|necessary|required)|(?:is|are)\s+not\s+(?:needed|necessary|required)|"
      r"not\s+(?:needed|necessary|required)|no\s+longer\s+(?:needed|necessary|required)|"
      r"(?:don'?t|do\s+not|no)\s+need)\b(?!\s+(?:it\s+)?to\s+(?:cancel|remove|delete|drop|clear|stop))",
      caseSensitive: false);
  static final _cancelVerb = RegExp(
      r'\b(?:cancel|remove|delete|drop|clear|stop|turn\s+off|get\s+rid\s+of)\b',
      caseSensitive: false);

  /// A question about whether anything slipped ("did I miss anything"); a
  /// specific thing ("did I miss the bus") is not one.
  static final _overdueQuestion = RegExp(
      r'^(?:did|have|am|was)\s+i\b.*\b(?:miss(?:ed)?|late|behind|forg[eo]t(?:ten)?)\b.*\b(?:anything|something|stuff|tasks?)\b',
      caseSensitive: false);

  static final _dataQuestion = RegExp(
      r'\b(?:pending|left|tasks?|to-?dos?|plans?|planned|schedule|agenda|due|reminders?)\b',
      caseSensitive: false);

  /// The model's time words were really said (or mean what the message says).
  bool _mentioned(String when, String text) {
    final t = _words(text);
    if (_words(when).every(t.contains)) return true;
    final a = _fallback.resolveWhen(when).at;
    return a != null && a == _fallback.parseWhen(text).$1;
  }

  /// Pending tasks [ref] names: an id, the exact title, or every word of ref
  /// (stemmed) in the title. Several = ask; never a similarity guess.
  Future<List<Task>> _matching(String ref, List<Task> open) async {
    final id = RegExp(r'^#?(\d+)$').firstMatch(ref.trim());
    if (id != null)
      return open.where((t) => t.id == int.parse(id.group(1)!)).toList();
    final exact =
        open.where((t) => normTitle(t.title) == normTitle(ref)).toList();
    if (exact.isNotEmpty) return exact;
    final want = _words(ref);
    if (want.isEmpty) return [];
    return open.where((t) => _words(t.title).containsAll(want)).toList();
  }

  /// A chat reply stating task facts (ids, due dates, titles) or claiming an
  /// action: only the database may answer those.
  static bool _groundless(String reply, List<Task> open) {
    if (_claim.hasMatch(reply) ||
        RegExp(
                r'#\d|\bdue\b|\d{4}-\d{2}-\d{2}|\breminders?\b|\btasks?\b|\btoday\b|\btomorrow\b|'
                r'\btonight\b|\bpending\b|\bnothing (?:left|due|planned)\b|\bschedule',
                caseSensitive: false)
            .hasMatch(reply)) {
      return true;
    }
    final r = ' ${normTitle(reply)} ';
    return open.any((t) =>
        normTitle(t.title).length > 3 && r.contains(' ${normTitle(t.title)} '));
  }

  // ---- rules fallback (no model, or no usable plan) ----

  Future<ToolCall?> _rules(String text) async {
    final draft = await _draft();
    if (draft != null && _fallback.parseCreate(text) == null) {
      final r =
          await _answer(draft, _fallback.resolveClarify(draft, text), text);
      if (r != null) return r;
    }

    final rp = RuleEngine.relativePostpone(text);
    if (rp != null) {
      final delta = RuleEngine.parseDuration(rp.$2);
      if (delta == null) {
        return _say('How long should I postpone it? Try "by 2 hours" or '
            '"postpone gym to tomorrow at 5".');
      }
      _evidence['time'] = 'shift: ${rp.$2}';
      return await _byRef('edit_task', const {}, rp.$1, shift: delta) ??
          _say('I couldn\'t find a pending task called "${rp.$1}".');
    }

    final done = RuleEngine.doneRef(text);
    if (done != null) {
      final c = await _byRef('complete_task', const {}, done.first,
          also: done.skip(1));
      if (c != null) return c;
      // Clear completion, unknown target: ask here, never let anything guess.
      final want = done.map(normTitle).toSet();
      final already = (await taskRepo.list(includeDone: true))
          .any((t) => t.done && want.contains(normTitle(t.title)));
      final open = await taskRepo.list();
      if (already || open.isEmpty) {
        return _say(already
            ? '"${done.last}" is already marked done.'
            : "You don't have any pending tasks to mark done.");
      }
      _setPick(TargetPick(
          tool: 'complete_task',
          args: const {},
          ids: [for (final t in open) t.id],
          askedAt: _now()));
      return _say('I couldn\'t find a pending task called "${done.first}". '
          'Which one did you finish?\n'
          '${open.take(10).map((t) => '#${t.id} ${t.title}').join('\n')}\n'
          'Say the number, e.g. #${open.first.id}.');
    }

    final ask = _fallback.maybeClarify(text);
    if (ask != null &&
        RegExp(r'^(?:it|that|this)(?: later)?$', caseSensitive: false)
            .hasMatch(ask.title)) {
      return _say('What should I remind you about?');
    }
    if (ask != null) {
      final r = _fallback.readWhen(text);
      _diag['clarify'] = r.role == TemporalRole.deadline && r.at != null
          ? 'deadline_not_alert'
          : 'rules_missing_time';
      await _setDraft(ask);
      return _say('${_fallback.clarifyReason(text)}${ask.prompt}');
    }

    final clash = _fallback.conflictDraft(text);
    if (clash != null) {
      // Which time? The rest of the request waits in the draft.
      _diag['clarify'] = 'temporal_conflict';
      await _setDraft(clash);
      return _say('${_fallback.clarifyReason(text)}${clash.prompt}');
    }

    final fast = _fallback.fastRoute(text);
    return fast == null ? null : _resolve(_call(fast));
  }

  /// Parses a rule result, keeping its disclosure `note` for the reply.
  ToolCall _call(Map<String, Object?> j) {
    final note = j['note'];
    if (note is String) _note = _note == null ? note : '$note $_note';
    return parseToolCall(jsonEncode(j));
  }

  /// Task title selectors resolved here so duplicates can be picked by number.
  Future<ToolCall> _resolve(ToolCall c) async {
    final key = const {
      'complete_task': 'title',
      'delete_task': 'title',
      'edit_task': 'target_title',
    }[c.tool];
    final ref = key == null ? null : c.args[key];
    if (ref is! String) return c;
    return await _byRef(c.tool, {...c.args}..remove(key), ref) ?? c;
  }

  /// The pending task [ref] ("#3", "3", or an exact title; or an exact
  /// [also] alternative title) names: one match runs [tool], several ask which, none = null.
  /// Never guesses an id.
  Future<ToolCall?> _byRef(String tool, Map<String, Object?> args, String ref,
      {Iterable<String> also = const [], Duration? shift}) async {
    final n =
        RegExp(r'^(?:task )?#?(\d+)$', caseSensitive: false).firstMatch(ref);
    List<Task> l;
    if (n != null) {
      final t = await taskRepo.get(int.parse(n.group(1)!));
      l = [if (t != null && !t.done) t];
    } else {
      final seen = <int>{};
      l = [
        for (final v in [ref, ...also]) ...await taskRepo.byTitle(v)
      ].where((t) => seen.add(t.id)).toList();
    }
    if (l.isEmpty && n == null && _pronounTitle.hasMatch(ref.trim())) {
      l = await taskRepo.list();
    }
    if (l.isEmpty && n == null) {
      final words = keyWords(ref);
      if (words.isNotEmpty) {
        l = (await taskRepo.list())
            .where((t) => keyWords(t.title).containsAll(words))
            .toList();
      }
    }
    if (l.isEmpty) return null;
    final pick = TargetPick(
        tool: tool,
        args: args,
        shift: shift,
        ids: [for (final t in l) t.id],
        askedAt: _now());
    if (l.length == 1) {
      return _withId(pick, l.first.id, n != null ? 'typed' : 'exact_title');
    }
    _setPick(pick);
    return _say('Several tasks match "$ref":\n'
        '${l.map((t) => '#${t.id} ${t.title}${t.dueAt == null ? '' : ' (${friendlyTime(t.dueAt!, _now())})'}').join('\n')}\n'
        'Which one? Say the number, e.g. #${l.first.id}.');
  }

  /// [p]'s action on [id]; [source] is the target's evidence (typed, pick,
  /// named, exact_title, pronoun).
  Future<ToolCall> _withId(TargetPick p, int id, String source) async {
    final args = {...p.args, 'id': id};
    if (args.remove('keep_time') == true) {
      final previous = (await taskRepo.get(id))?.dueAt;
      final day = args['due'] as DateTime;
      if (previous == null)
        return _say('What time should I use for that task?');
      args['due'] = DateTime(
          day.year, day.month, day.day, previous.hour, previous.minute);
    }
    if (p.shift != null) {
      args['due'] = ((await taskRepo.get(id))?.dueAt ?? _now()).add(p.shift!);
      _evidence['time'] ??= 'shift: ${p.shift!.inMinutes} min';
    }
    _evidence['target'] = source;
    return ToolCall(p.tool, args);
  }

  /// Deterministic, incremental memory: explicit "remember ..." requests and
  /// clear personal facts are stored as they are said (no model, no
  /// close-time pass). Written by the executor (`save_memory`) at commit.
  ({String content, String category})? _memoryCandidate(
      String text, bool explicit) {
    // Plan 1.4: an explicit "remember" also keeps a short-lived fact (stored
    // with an expiry); implicit statements of plans are still not saved.
    final j = _fallback.extractMemory(text, timeBound: explicit);
    final m = j['memory'];
    if (j['remember'] != true || m is! String) return null;
    if (m.trim().isEmpty || m.length > 300) return null;
    // Plan 1.5: the extractor keeps trailing filler (", you know"; on an
    // explicit request also ", will you"); drop that one anchored tag, as the
    // instruction scan does, so the stored text is the fact alone.
    final content = stripMemoryFillerTag(m,
        request: memoryRequestCue.hasMatch(text.trim()));
    if (content.isEmpty) return null;
    if (!explicit && !isUsefulPersonalMemory(content)) return null;
    return (content: content, category: j['category'] as String? ?? 'fact');
  }

  /// Plan 1.5: the extracted [content] or the user's own words (less a
  /// leading "remember that"/"note:" cue) read as an instruction for the
  /// assistant ([memoryInstructionIssue]). The raw text is scanned too, so an
  /// extraction that drops the directive never launders it into a fact; this
  /// fails closed. A removed request cue still lets the scan drop a trailing
  /// ", will you?" courtesy tag ([stripMemoryFillerTag]); only that tag.
  static bool _instructionLikeMemory(String text, String? content) {
    if (content != null && memoryInstructionIssue(content) != null) {
      return true;
    }
    final request = memoryRequestCue.hasMatch(text.trim());
    final words = text.trim().replaceFirst(
        RegExp(
            r"^(?:please\s+)?(?:remember|note|fyi|keep\s+in\s+mind|don'?t\s+forget|do\s+not\s+forget)"
            r'(?:\s+that\b\s*[:,]?|\s*[:,])\s*',
            caseSensitive: false),
        '');
    return memoryInstructionIssue(words, request: request) != null;
  }

  /// The last local day (in [at]'s offset) a memory expiring at
  /// [expiresAtMs] is still current, e.g. "Mon 2 Nov".
  static String _lastDayBefore(int expiresAtMs, DateTime at) {
    final offset = at.timeZoneOffset;
    final last =
        DateTime.fromMillisecondsSinceEpoch(expiresAtMs - 1, isUtc: true)
            .add(offset);
    return shortDate(last);
  }

  static const tooLongReply =
      "That message is too long for me to handle on this device. Please try a shorter message.";

  // ---- read-only old/new comparison ----

  /// Runs both interpreters on [text] without writing anything (no
  /// transcript, journal, pending, task, reminder or memory writes, and no
  /// reply-model calls; a plan-model call per interpreter is allowed) and
  /// returns their candidate plans. For synthetic fixtures and parity
  /// checks only; the live turn is [handle].
  Future<InterpreterComparison> compareInterpreters(String text) async {
    text = text.trim();
    if (_s != SessionState.listening || _active != null) {
      throw StateError('session is not listening ($_s)');
    }
    final lastTask = _lastTask, memDraft = _memDraft, memPick = _memPick;
    final cancelled = _cancelled;
    final diagnostics = lastDiagnostics, fallback = lastFallbackReason;
    final at = clock();
    Future<CandidatePlan> once(Interpreter mode) async {
      _turnNow = null;
      _turnNow = at;
      _resetTurn(text, mode: mode, dryRun: true);
      _cancelled = false;
      try {
        return await _plan(text, null, <String, int>{});
      } finally {
        _lastTask = lastTask;
        _memDraft = memDraft;
        _memPick = memPick;
      }
    }

    final done = Completer<String>();
    _active = done.future;
    try {
      final legacy = await once(Interpreter.legacy);
      final unified = await once(Interpreter.unified);
      return InterpreterComparison(legacy, unified);
    } finally {
      _resetTurn(text);
      _dryRun = false;
      _turnNow = null;
      _cancelled = cancelled;
      lastDiagnostics = diagnostics;
      lastFallbackReason = fallback;
      done.complete('');
      _active = null;
    }
  }

  /// Stops foreground and optional generation, waiting only for the foreground
  /// turn to settle. A turn cancelled before its action runs executes nothing;
  /// an action already running finishes.
  Future<void> cancel() async {
    final op = _active;
    // Optional work can outlive the foreground future (or still be preparing
    // its prompt). Invalidate it before native cancel can deliver callbacks;
    // the epoch keeps it stale even when a later turn clears _cancelled.
    _cancelled = true;
    _generationEpoch++;
    // Drops only this session's queued calls (other sessions keep their
    // place) and silences its running one; the scheduler keeps the worker
    // slot occupied until the native generation really ends.
    models.cancelEngine(engine);
    try {
      await engine.cancel();
    } catch (_) {}
    try {
      await op;
    } catch (_) {}
  }

  /// Ends the session after any in-flight start/turn settles. The shared model
  /// stays loaded. Safe from any state; idempotent. Returns the memories saved
  /// during this session.
  Future<List<String>> close() => _closing ??= _close();

  Future<List<String>> _close() async {
    _closeRequested = true;
    _idle?.cancel();
    try {
      await _starting;
    } catch (_) {}
    await cancel();
    _idle?.cancel();
    if (_s != SessionState.idle) {
      _go(SessionState.shuttingDown);
      _go(SessionState.idle);
    }
    return List.of(_saved);
  }
}

/// A model reply saying it did something; only tools do things.
final _claim = RegExp(
    r"^(?:(?:ok(?:ay)?|sure|done|great)[,!.]?\s*)?(?:i(?:'ve| have|'ll| will)?\s+)?(?:set|added|created|scheduled|saved|deleted|removed|completed|marked|cancell?ed|updated|reminded|postponed)\b",
    caseSensitive: false);
