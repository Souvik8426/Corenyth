import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/repos.dart';
import '../mascot/mascot_emotion.dart';
import 'authorization.dart';
import 'calculator.dart';
import 'core_policy.dart';
import 'engine.dart';
import 'follow_through.dart';
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
    Interpreter? interpreter,
    CorePolicyStore? policyStore,
  })  : id = conversationId ?? ConversationRepo.newChatId(),
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
    _note = null;
    _header = null;
    _prefix = null;
    _modelLine = null;
    _subject = null;
    _leadMin = null;
    // "not tonight, but remind me…": the request after "but" is the turn.
    text = RuleEngine.contrastRequest(text) ?? text;
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

  Future<String> _turn(String text, void Function(String)? onText) async {
    _go(SessionState.processing);
    final total = Stopwatch()..start();
    final timing = <String, int>{};
    _timing = timing;
    final journal = operations;
    journal?.registerActive(_op);
    try {
      final hash = _hash(text);
      final prior = journal == null ? null : await journal.get(_op);
      if (prior != null && prior.textHash != hash) {
        throw ArgumentError('operation $_op belongs to a different message');
      }
      _diag['op'] = _op;
      if (prior != null &&
          prior.receipt != null &&
          _final.contains(prior.status)) {
        return await _replay(prior, onText);
      }
      if (prior == null) {
        _userRowId = await conversations.add(id, 'user', text);
        lastUserRowId = _userRowId;
        await journal?.begin(_op, id, hash);
      }
      _diag['interpreter'] = _mode.name;
      _diag['auth'] = _auth.kind.name;
      var status = OperationJournal.noWrite;
      String reply;
      try {
        final route = Stopwatch()..start();
        final recovering = (prior?.status == OperationJournal.executing ||
                prior?.status == OperationJournal.committed) &&
            prior?.action != null;
        final CandidatePlan plan;
        if (recovering) {
          // Crashed while writing: finish the journaled validated action;
          // rows it already committed are found by their op id, not redone.
          plan = CandidatePlan.fromActionJson(prior!.action!, _mode, _auth);
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
      if (_header != null) reply = '$_header:\n$reply';
      if (_prefix != null) reply = '$_prefix $reply';
      if (_note != null) reply = '$reply $_note';
      if (_modelLine != null &&
          status != OperationJournal.failed &&
          lastTurn?.receipts.any((r) => r.wrote) == true) {
        reply = '$reply $_modelLine';
        _diag['reply'] = 'model_line';
      }
      await conversations.add(id, 'assistant', reply);
      await journal?.mark(_op, status,
          receipt: jsonEncode({...?lastTurn?.toJson(), 'reply': reply}));
      onText?.call(reply);
      _go(SessionState.speaking);
      if (!_cancelled) await speak?.call(reply);

      // Foreground confirmation settles before optional mood; mood work runs with
      // captured immutable inputs without delaying or blocking foreground replies.
      if (!_scopeRefused &&
          _budget.plan + _budget.reply == 0 &&
          !_dryRun &&
          !_cancelled &&
          engineInUse == engine.name &&
          engine is! RuleEngine &&
          !_mechanicalRoutes.contains(_routeId)) {
        _dispatchOptionalMood(
          text: text,
          opId: _op,
          userRowId: _userRowId,
          moodSink: _moodSink,
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
    }
  }

  /// A retried turn whose result was final: the same reply, no new writes.
  Future<String> _replay(Operation prior, void Function(String)? onText) async {
    final reply = (jsonDecode(prior.receipt!) as Map)['reply'] as String? ?? '';
    _routeId = RouteId.retryReplay;
    _diag['route'] = routeName(RouteId.retryReplay);
    if (prior.status == OperationJournal.committed) {
      // Committed but its reply was never shown (crash): show it once.
      await conversations.add(id, 'assistant', reply);
      await operations!.mark(_op, OperationJournal.replied);
    }
    onText?.call(reply);
    _go(SessionState.speaking);
    if (!_cancelled) await speak?.call(reply);
    return reply;
  }

  /// Cancelled before commit: nothing was written; the "Which one?" this
  /// turn consumed is dropped as before.
  Future<void> _abandon(OperationJournal? journal) async {
    try {
      await journal?.mark(_op, OperationJournal.abandoned);
      if (_pickStored) await _storePick(null);
    } catch (_) {}
  }

  /// Inputs whose answer is purely mechanical; spending a model call to read
  /// a mood from "#3" or "in 20 minutes" would only add latency.
  static const _mechanicalRoutes = {
    RouteId.calculator,
    RouteId.pendingPick,
    RouteId.pendingAnswer,
  };

  /// Dispatches optional mood work with captured immutable inputs, completely
  /// independent of foreground turn settlement and mutable turn budget.
  void _dispatchOptionalMood({
    required String text,
    required String opId,
    required int? userRowId,
    required void Function(TurnMood mood)? moodSink,
  }) {
    final epoch = _generationEpoch;
    final now = _turnNow ?? _now();
    lastOptionalMoodJob = _runOptionalMood(
      text: text,
      opId: opId,
      userRowId: userRowId,
      moodSink: moodSink,
      now: now,
      epoch: epoch,
    );
  }

  Future<void> _runOptionalMood({
    required String text,
    required String opId,
    required int? userRowId,
    required void Function(TurnMood mood)? moodSink,
    required DateTime now,
    required int epoch,
  }) async {
    if (_cancelled || epoch != _generationEpoch || _closeRequested) return;
    try {
      final p = Prompt(PromptKind.reply, text,
          tone: (await profile.get())?.tone,
          now: now,
          context: 'Goal: a mascot mood reading of the user\'s current message. '
              'The reply text is not shown or used.',
          personalContext: buildPersonalContext(
              await profile.get() ?? const UserProfile(), const []));
      await engine.completeStreaming(p, onRaw: (chunk) {
        if (_cancelled || epoch != _generationEpoch || _closeRequested) return;
        final reading = planStreamView(chunk).mood;
        if (reading != null) {
          final record = TurnMood(
            source: 'model:reply',
            conversationId: id,
            turnId: opId,
            generationId: '$opId/optional_mood',
            emotion: reading.mood == null
                ? null
                : MascotEmotion(reading.mood!, reading.intensity),
            confidence: reading.confidence,
            messageRowId: userRowId,
          );
          moodSink?.call(record);
          final repo = moods;
          if (repo != null && userRowId != null) {
            repo
                .save(
                  messageId: userRowId,
                  chatId: id,
                  source: 'model:reply',
                  mood: reading.mood?.name,
                  intensity: reading.intensity,
                  confidence: reading.confidence,
                )
                .catchError((_) {});
          }
        }
      });
      _diag['model_calls'] = '${_budget.plan}p${_budget.reply + 1}r';
      _diag['mood'] = 'emitted';
      lastDiagnostics = Map.unmodifiable(_diag);
    } on PlatformException {
    } catch (_) {}
  }

  // ---- interpretation: one route -> a candidate plan, no writes ----

  Future<CandidatePlan> _plan(String text, void Function(String)? onText,
      Map<String, int> timing) async {
    text = RuleEngine.contrastRequest(text) ?? text;
    final hasPending = await _draft() != null;
    final isCalc = calculate(text) != null;
    // Pending answers and arithmetic keep route precedence but still advance
    // policy so an outside topic does not linger across them.
    if (hasPending || isCalc) {
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
    final explicit = RuleEngine.isExplicitRemember(text);
    final memo = _memoryCandidate(text, explicit);
    if (memo != null) {
      final replaces = RuleEngine.correctedObject(text);
      _memoryEffect = ToolCall('save_memory', {
        'content': memo.content,
        'category': memo.category,
        'source': 'chat:$id',
        if (replaces != null) 'replaces': replaces,
      });
    }
    final ToolCall call;
    final forget = RegExp(r'^(?:please\s+)?forget\s+(?:that\s+)?(.+)$',
            caseSensitive: false)
        .firstMatch(text.trim());
    if (forget != null &&
        _auth.permitsWrite &&
        !RegExp(r'^(?:it|about it|that|that one|one)$', caseSensitive: false)
            .hasMatch(forget.group(1)!.trim())) {
      _routeId = RouteId.explicitMemory;
      _memoryEffect = null;
      final raw = forget.group(1)!;
      final fact = _fallback.extractMemory(raw)['memory'] as String? ?? raw;
      final candidates = await memory.search(fact, limit: 10);
      final exactMatches = candidates
          .where((m) =>
              m.content.toLowerCase().replaceAll(RegExp(r'[.!?]+$'), '') ==
              fact.toLowerCase())
          .toList();
      final matches = exactMatches.isNotEmpty
          ? exactMatches
          : (candidates.length == 1 ? candidates : const <Memory>[]);
      if (matches.length == 1) {
        _evidence['target'] = 'exact_memory';
        call = ToolCall('delete_memory', {'id': matches.single.id});
      } else {
        call = _say(candidates.isEmpty
            ? "I couldn't identify that saved memory. You can review or delete it in Memories."
            : 'Several memories match. Please choose one in Memories.');
      }
    } else if (explicit) {
      _routeId = RouteId.explicitMemory;
      timing['route'] = 0;
      // The memory is written (as an effect) before this reply is shown.
      call = _say(memo != null
          ? "Okay, I'll remember that."
          : (RuleEngine.isTemporary(text)
              ? "I won't store short-lived plans as memories. Want a reminder or task instead?"
              : "That's too long for me to remember; try a shorter sentence."));
    } else {
      final grounded = await _groundedTurn(text);
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
      (
        RouteId.rulePlan,
        () async => _rulePlanCall(t)
      ),
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

  /// Settled without the model: "#3" for this chat's "which one?", a
  /// calculation, or a reply that only gives the pending question's time.
  Future<ToolCall?> _early(String text) async {
    for (final (id, c) in [
      (RouteId.pendingPick, await _pickRoute(text)),
    ]) {
      if (c != null) {
        _routeId = id;
        return c;
      }
    }
    final calc = _calcRoute(text);
    if (calc != null) {
      _routeId = RouteId.calculator;
      return calc;
    }
    final answer = await _pendingAnswerRoute(text);
    if (answer != null) _routeId = RouteId.pendingAnswer;
    return answer;
  }

  /// A reply to the "Which one?" this chat asked last turn.
  Future<ToolCall?> _pickRoute(String text) async {
    final pick = await _loadPick();
    final n = RegExp(r'^(?:#|number |task )?(\d+)$', caseSensitive: false)
        .firstMatch(text.trim());
    int? selected = n == null ? null : int.parse(n.group(1)!);
    if (pick != null &&
        selected == null &&
        pick.args['text'] is String &&
        !_isCommand(text) &&
        !hasCommandWord(text) &&
        !isQuestionLike(text) &&
        !isProgressUpdate(text) &&
        !looksLikeOutcome(text)) {
      final choices = <Task>[];
      for (final id in pick.ids) {
        final task = await taskRepo.get(id);
        if (task != null) choices.add(task);
      }
      final matches = named(choices, text);
      if (matches.length == 1) selected = matches.single.id;
      if (matches.length > 1) {
        _setPick(pick);
        return _say('Which one? Please give the full name or task number.');
      }
    }
    if (pick != null && selected != null) {
      final id = selected;
      if (pick.ids.contains(id)) {
        final said = pick.args['text'];
        if (said is! String) return _withId(pick, id, 'pick');
        final t = await taskRepo.get(id);
        if (t == null)
          return _say(
              'That task no longer exists, so I left everything as it was.');
        return switch (pick.tool) {
          'discuss' => await _discuss(t, said),
          'outcome' => await _recordOutcome(t, said),
          _ => await _applyDetails(t, said) ??
              _say("I couldn't read those details."),
        };
      }
      _setPick(pick);
      return _say(
          "That isn't one of ${pick.ids.map((i) => '#$i').join(', ')}. Which one?");
    }
    return null;
  }

  ToolCall? _calcRoute(String text) {
    final calc = calculate(text.trim());
    return calc == null ? null : _say(calc);
  }

  Future<ToolCall?> _pendingAnswerRoute(String text) async {
    final draft = await _draft();
    if (draft == null) return null;
    var answer = text;
    String? subject;
    // An event's time question may be answered with its topic too.
    final about = draft.day == null
        ? null
        : RegExp(
                r"^(.+?)[,;.]?\s+(?:and\s+)?(?:it'?s\s+|it is\s+)?about\s+(.+?)[.!]*$",
                caseSensitive: false)
            .firstMatch(text.trim());
    if (about != null && _fallback.isTimeAnswer(draft, about.group(1)!)) {
      answer = about.group(1)!;
      subject = about.group(2)!;
    }
    if (_fallback.isTimeAnswer(draft, answer)) {
      final c =
          await _answer(draft, _fallback.resolveClarify(draft, answer), answer);
      if (c != null && c.tool != 'respond') _subject = subject;
      return c;
    }
    return null;
  }

  /// Applies a clarification result: done (or cancelled) clears the draft.
  Future<ToolCall?> _answer(ClarifyDraft draft,
      ({Map<String, Object?> call, bool keep})? r, String answer) async {
    if (r == null) return null;
    if (!r.keep) _clearDraft();
    _evidence['title'] = 'pending';
    final words = _fallback.readWhen(answer).spans.map((s) => s.text);
    if (words.isNotEmpty) _evidence['time'] = 'answer: ${words.join(' | ')}';
    if (draft.time != null) _evidence['time'] ??= 'pending: ${draft.time}';
    return _call(r.call);
  }

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

  ToolCall? _briefingRoute(String text) =>
      isBriefingRequest(text) && _fallback.parseCreate(text) == null
          ? ToolCall('briefing', const {})
          : null;

  static final _reminderWord = RegExp(
      r'\b(?:remind|alert|notify|alarm|nudge|ping)',
      caseSensitive: false);

  /// Unified only: "Don't remind me about the meeting" while reminders for
  /// it exist. Nothing is created or cancelled here; the reply names the
  /// saved reminders and a typed pick lets "#12" cancel the intended one.
  Future<ToolCall?> _negatedCancelRoute(String text) async {
    // "the gym reminder isn't needed, cancel it" asks to drop it: once the
    // not-needed words are set aside nothing is refused ("don't cancel the
    // gym reminder" still is).
    final unneeded = _notNeeded.hasMatch(text) &&
        !RuleEngine.isNegated(text.replaceAll(_notNeeded, ' '));
    if ((_auth.kind != Authorization.negated && !unneeded) ||
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

  /// The last few turns of this chat for a prose reply, this turn excluded.
  /// Check-ins and replies listing tasks stay out: task facts come from SQLite.
  Future<List<Message>> _chatHistory() async {
    try {
      final l = await conversations.recent(id, n: 7);
      if (l.isNotEmpty &&
          l.last.role == 'user' &&
          l.last.content.trim() == _said) {
        l.removeLast();
      }
      return [
        for (final m in l)
          if (m.role == 'user' &&
              m.content.trim() != _said &&
              _safeHistorical(m.content))
            Message(m.role, _cut(m.content))
      ];
    } catch (_) {
      return const [];
    }
  }

  /// "That was dumb, give a proper reply to my previous prompt": the last
  /// reply missed, so answer the user's earlier message again (no writes).
  Future<ToolCall> _complaint() async {
    String? earlier;
    try {
      final l = await conversations.recent(id, n: 12);
      var skipped = false;
      for (final m in l.reversed) {
        if (m.role != 'user') continue;
        if (!skipped && m.content.trim() == _said) {
          skipped = true;
          continue;
        }
        if (!isComplaint(m.content)) {
          earlier = m.content.trim();
          break;
        }
      }
    } catch (_) {}
    if (earlier == null) {
      return _say("Sorry, that wasn't helpful. What would you like me to do? "
          'I can add tasks, set reminders, or go over your plans.');
    }
    final last = _lastTask == null ? null : await taskRepo.get(_lastTask!);
    final t = last != null && named([last], earlier).isNotEmpty ? last : null;
    final String fallback;
    if (t == null) {
      fallback =
          'Sorry, that reply missed the point. About "${_cut(earlier)}": '
          'should I make it a task or a reminder, or did you just want to talk it through?';
    } else if (t.done) {
      fallback =
          'Sorry, that reply missed the point. #${t.id} ${t.title} is marked done'
          '${t.outcome == null ? '' : ', and I noted: ${_cut(t.outcome!)}'}. '
          'Want a reminder to follow up on it later?';
    } else {
      fallback =
          'Sorry, that reply missed the point. About #${t.id} ${t.title}: '
          'should I mark it done, or move it to another day?';
    }
    return _say(await _converse(
        earlier,
        [
          if (t != null) 'Task: ${_line(t)}',
          if (t?.outcome != null) 'Outcome noted: ${t!.outcome}',
        ],
        fallback,
        'Your previous reply was unhelpful. Start with a short apology, then respond properly to this message and offer one useful next step.',
        history: await _chatHistory()));
  }

  /// The user's own earlier messages from any chat sharing words with [text]
  /// (this turn excluded). Optional context: a failed read is just none.
  Future<List<Message>> _related(String text) async {
    try {
      return (await conversations.relevant(text, limit: 4))
          .where((m) =>
              _safeHistorical(m.content) &&
              m.content.trim() != _said &&
              m.content.trim() != text.trim())
          .take(3)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // Durable personal facts are sourced only from active memory rows. Replaying
  // old chat statements would resurrect deleted or superseded preferences.
  bool _safeHistorical(String text) =>
      !RuleEngine.isExplicitRemember(text) &&
      !isUsefulPersonalMemory(
          (_fallback.extractMemory(text)['memory'] as String?) ?? text) &&
      !text.toLowerCase().contains('remember');

  Future<List<String>> _personalMemories(String text) async {
    if (RuleEngine.isGeneralKnowledge(text)) return const [];
    try {
      return (await memory.relevantForContext(text, limit: 3))
          .map((m) => _cut(m.content))
          .toList();
    } catch (_) {
      _diag['memory'] = 'retrieval_failed';
      return const [];
    }
  }

  /// Sends [p] to the model within this turn's [_ModelBudget]: null when the
  /// budget for its kind is spent. An identical prompt reuses its output (a
  /// cache hit — the callbacks of the original call do not replay).
  /// [onRaw] receives the cumulative raw output while the model generates;
  /// [onText] the cumulative user-visible respond text, when the contract has
  /// one.
  Future<String?> _complete(Prompt p,
      {void Function(String raw)? onRaw,
      void Function(String visible)? onText}) async {
    final key = '${p.kind.name}\u0000${p.contract}\u0000${p.render()}';
    final seen = _budget._seen[key];
    if (seen != null) return seen;
    if (p.kind == PromptKind.plan) {
      if (_budget.plan >= _ModelBudget.maxPlan) return null;
      _budget.plan++;
    } else {
      if (_budget.reply >= _ModelBudget.maxReply) return null;
      _budget.reply++;
    }
    final raw = await engine.completeStreaming(p, onText: onText, onRaw: onRaw);
    _budget._seen[key] = raw;
    return raw;
  }

  /// Publishes one live-draft update: cumulative visible reply text (''
  /// withdraws the draft). Records the first-visible-text latency once.
  void _sendLive(String text) {
    if (text == _liveSent) return;
    _liveSent = text;
    final t = _timing;
    if (text.isNotEmpty && t != null && !t.containsKey('first_text')) {
      t['first_text'] = _turnClock.elapsedMilliseconds;
    }
    _streamSink?.call(text);
  }

  /// The streaming gate shared by the plan and reply paths: given one
  /// cumulative chunk of visible reply text and [passes] — the same checks
  /// the completed answer must pass — returns the text to publish (cumulative
  /// replace; '' withdraws), or null when nothing new may be shown.
  ///
  /// Guarantees: an *established* violation (ungrounded completed number,
  /// action claim, JSON, oversized text, echo) permanently blocks the stream —
  /// these checks only ever flip from pass to fail as text grows, so nothing
  /// that later fails was ever displayed. An *undecidable* suffix (a number or
  /// claim-verb word still arriving) is held, not judged: 'Those 1' waits,
  /// then 'Those 12 ideas' is released whole when 12 is grounded. Held tails
  /// surface at finalization, when the authoritative answer replaces the
  /// draft. Write plans never reach this gate at all: their replies stay
  /// buffered until the operation commits.
  String? _streamedDraft(String cumulative, bool Function(String) passes) {
    if (_streamBlocked) return null;
    final hold = undecidableSuffixLength(cumulative);
    final decidable = cumulative.substring(0, cumulative.length - hold);
    if (decidable.isEmpty) return null;
    if (passes(decidable)) return decidable;
    _streamBlocked = true;
    return '';
  }

  /// Emits this turn's mood at most once (the first valid reading wins),
  /// reports its arrival latency, and stores it against the turn's user
  /// message row. A storage failure never affects the reply.
  void _emitMood(MoodReading reading, {required String source}) {
    if (_moodEmitted) return;
    _moodEmitted = true;
    final t = _timing;
    if (t != null && !t.containsKey('mood')) {
      t['mood'] = _turnClock.elapsedMilliseconds;
    }
    final record = TurnMood(
      source: source,
      conversationId: id,
      turnId: _op,
      generationId: '$_op/$source#${_budget.plan}p${_budget.reply}r',
      emotion: reading.mood == null
          ? null
          : MascotEmotion(reading.mood!, reading.intensity),
      confidence: reading.confidence,
      messageRowId: _userRowId,
    );
    _moodSink?.call(record);
    _diag['mood'] = '${reading.mood?.name ?? 'unknown'}($source)';
    final repo = moods;
    final row = _userRowId;
    if (repo != null && row != null) {
      _moodSave = repo
          .save(
            messageId: row,
            chatId: id,
            source: source,
            mood: reading.mood?.name,
            intensity: reading.intensity,
            confidence: reading.confidence,
          )
          .catchError((_) {}); // display already updated; retried next turn
    }
  }

  /// A short reply from the local model about facts the app read, in the
  /// user's tone. Only prose: anything claiming an action, carrying an
  /// ungrounded number, parroting the message, or not a plain reply falls
  /// back to [fallback]. [history]: recent turns from [_chatHistory].
  /// A dry run ([compareInterpreters]) never calls the model here.
  ///
  /// The reply is streamed into the live draft as it grows: each cumulative
  /// chunk is shown only while it still passes the same checks the final text
  /// must pass, so no unverified claim is ever displayed. A chunk that fails
  /// a check stops the stream and withdraws the draft; the final reply (or
  /// the fallback) is decided afterwards exactly as before.
  Future<String> _converse(
      String text, List<String> facts, String fallback, String goal,
      {List<Message> history = const []}) async {
    if (_dryRun) return fallback;
    if (engineInUse != engine.name || engine is RuleEngine) return fallback;
    if (loadEngine != null) {
      try {
        if (!await loadEngine!()) return fallback;
      } catch (_) {
        return fallback;
      }
    }
    if (_cancelled) throw ToolError('cancelled');
    final context = ['Goal: $goal', ...facts].join('\n');
    final p = Prompt(PromptKind.reply, text,
        tone: (await profile.get())?.tone,
        now: _now(),
        context: context,
        history: history,
        personalContext: buildPersonalContext(
            await profile.get() ?? const UserProfile(),
            await _personalMemories(text)));
    String? raw;
    try {
      if (_liveSent.isNotEmpty) _sendLive(''); // a replaced draft starts clean
      final grounding = '$context\n$text';
      raw = await _complete(p, onRaw: (chunk) {
        if (_cancelled) return;
        if (!_moodEmitted) {
          final reading = planStreamView(chunk).mood;
          if (reading != null) _emitMood(reading, source: 'model:reply');
        }
        final v = visibleRespondText(chunk);
        if (v == null || v.isEmpty) return;
        final next = _streamedDraft(
            v,
            (t) =>
                safeReply(t, grounding) &&
                !echoes(t, text) &&
                !echoes(t, _said));
        if (next == null) return;
        _sendLive(next);
        _diag['stream'] = next.isEmpty ? 'withheld' : 'reply';
      });
      if (raw == null) _diag['reply_budget'] = 'spent';
    } on PlatformException catch (e) {
      if (e.code == 'llama_cancelled') _cancelled = true;
    } catch (_) {}
    if (_cancelled) throw ToolError('cancelled');
    _diag['reply'] = 'fallback';
    if (raw == null) return fallback;
    try {
      final c = parseToolCall(raw);
      final r = c.args['text'];
      if (c.tool == 'respond' &&
          r is String &&
          safeReply(r, '$context\n$text') &&
          !echoes(r, text) &&
          !echoes(r, _said)) {
        _diag['reply'] = 'model';
        return r.trim();
      }
    } on ToolError {
      // not a plain reply: the deterministic text stands
    }
    return fallback;
  }

  /// Rewrites a validated call by app rules only: a timed meeting the user
  /// said they have gets its alerts (task-linked reminders on) even without
  /// "remind me"; "15 minutes before" is that item's own early alert.
  Future<ToolCall> _adjust(ToolCall c) async {
    final a = c.args, due = a['due'];
    final r = c.tool.startsWith('create_') ? _fallback.readWhen(_said) : null;
    if (c.tool == 'create_task' &&
        due is DateTime &&
        r != null &&
        r.dated &&
        !r.timed &&
        RegExp(r'^call(?: with .+)?$', caseSensitive: false)
            .hasMatch((a['title'] as String).trim())) {
      final draft = ClarifyDraft(
          tool: c.tool,
          title: a['title'] as String,
          day: due.toIso8601String().substring(0, 10));
      _diag['clarify'] = 'event_time';
      _note = null;
      await _setDraft(draft);
      return _say(draft.prompt);
    }
    final rel = r?.anchor?.relation;
    final deadline = r != null &&
        r.role == TemporalRole.deadline &&
        (rel == TemporalRelation.within || rel == TemporalRelation.before);
    if (deadline && c.tool == 'create_reminder' && r.at == a['at']) {
      _note = _note == null ? _deadlineNote : '$_note $_deadlineNote';
    }
    if (c.tool == 'create_task' &&
        !deadline &&
        tools.preferences != null &&
        due is DateTime &&
        due.isAfter(_now()) &&
        (isEventTitle(a['title'] as String) ||
            (await tools.preferences!.get()).multiple)) {
      c = ToolCall('create_reminder', {'title': a['title'], 'at': due});
    }
    if (c.tool == 'create_reminder' && _leadMin != null) {
      c = ToolCall(c.tool, {
        ...c.args,
        'lead': [_leadMin!]
      });
    }
    if (c.tool == 'create_reminder' &&
        tools.preferences != null &&
        !isEventTitle(c.args['title'] as String) &&
        !c.args.containsKey('follow_up')) {
      c = ToolCall(c.tool, {...c.args, 'follow_up': false});
    }
    return c;
  }

  static const _deadlineNote =
      "That's the deadline you gave; tell me if you want an earlier alert.";

  /// Grounding for [c]'s fields, as the route recorded it, else read from
  /// the message itself: a title said (at least half its words), the user's
  /// own time words, an id the user typed or an exact title they gave.
  Map<String, String> _evidenceFor(ToolCall c) {
    final e = {..._evidence};
    final f = familyOf(c.tool);
    if (f == ActionFamily.create) {
      final title = c.args['title'];
      if (e['title'] == null && title is String && _grounded(title, _said)) {
        e['title'] = 'said';
      }
      final timed = c.args['at'] != null || c.args['due'] != null;
      if (e['time'] == null && timed) {
        final r = _fallback.readWhen(_said);
        if (r.spans.isNotEmpty) {
          e['time'] = r.spans.map((s) => s.text).join(' | ');
        } else if (r.at != null || _fallback.findWhen(_said).at != null) {
          e['time'] = 'resolved';
        }
      }
    } else if (f == ActionFamily.change && e['target'] == null) {
      final id = c.args['id'];
      final sel = c.args['title'] ?? c.args['target_title'];
      if (id is int && RegExp('(?:#|\\b)$id\\b').hasMatch(_said)) {
        e['target'] = 'typed';
      } else if (sel is String && _grounded(sel, _said, all: true)) {
        e['target'] = 'exact_title';
      }
    }
    return e;
  }

  /// The task a completion is about, read before it runs (its follow-up is
  /// cancelled by it): is it a meeting-like event?
  Future<({Task task, bool event})?> _before(ToolCall c) async {
    if (c.tool != 'complete_task') return null;
    try {
      final ref = c.args['id'], title = c.args['title'];
      Task? t;
      if (ref is int) {
        t = await taskRepo.get(ref);
      } else if (title is String) {
        final l = await taskRepo.byTitle(title);
        t = l.length == 1 ? l.single : null;
      }
      if (t == null || t.done) return null;
      final id = t.id;
      final follow = (await tools.reminders.upcoming())
          .any((r) => r.taskId == id && r.kind == 'follow_up');
      return (
        task: t,
        event: follow ||
            t.endsAt != null ||
            t.subject != null ||
            isEventTitle(t.title)
      );
    } catch (_) {
      return null;
    }
  }

  /// After a committed write: a new meeting asks its optional details; a
  /// finished one asks how it went (follow-ups on) or notes the outcome the
  /// message already gave. Metadata only, through the executor ([run]); a
  /// failure here never hides the write's own reply.
  Future<String> _after(
      ToolCall c,
      ({Task task, bool event})? before,
      String reply,
      String text,
      Future<ExecutionReceipt> Function(ToolCall) run) async {
    try {
      if (_subject != null &&
          c.tool.startsWith('create_') &&
          _lastTask != null) {
        await run(ToolCall(
            'set_event_details', {'id': _lastTask, 'subject': _subject}));
      }
      if (c.tool == 'create_reminder' && _lastTask != null) {
        final found = await taskRepo.get(_lastTask!);
        if (found == null || found.done || !isEventTitle(found.title)) {
          return reply;
        }
        var t = found;
        // "meeting in 10 minutes for half an hour": its end, not its start.
        final r = _fallback.readWhen(text);
        if (r.end != null && t.dueAt == r.at && t.endsAt == null) {
          try {
            await run(
                ToolCall('set_event_details', {'id': t.id, 'ends_at': r.end}));
            t = await taskRepo.get(t.id) ?? t;
          } on ToolError {
            // not after the start: the optional question below still asks
          }
        }
        final more = <String>[];
        if (t.awaiting == null && t.endsAt == null && t.subject == null) {
          await run(ToolCall(
              'set_awaiting', {'id': t.id, 'question': TaskRepo.details}));
          final follow = (await tools.reminders.upcoming())
              .any((r) => r.taskId == t.id && r.kind == 'follow_up');
          more.add(follow
              ? 'When does it end, and what is it about? Then I can check in right after it ends. (Optional.)'
              : 'Optional: when does it end, and what is it about?');
        }
        final k = keyWords(t.title)
            .where((w) => !isEventTitle(w) && w != 'meet')
            .toSet();
        for (final o in await taskRepo.list()) {
          if (o.id != t.id &&
              isArrangement(o.title) &&
              keyWords(o.title).any(k.contains)) {
            more.add(
                'Your task #${o.id} "${o.title}" is still open; say "complete task #${o.id}" '
                'when setting it up is done.');
            break;
          }
        }
        return [reply, ...more].join(' ');
      }
      if (c.tool != 'complete_task' ||
          before == null ||
          (!before.event && c.args['outcome'] == null)) return reply;
      final t = before.task;
      await run(ToolCall('review_answered', {'id': t.id}));
      final outcome =
          (c.args['outcome'] as String?) ?? eventDone(text)?.outcome;
      if (outcome != null) {
        final sp = splitRequest(outcome);
        if (t.awaiting == TaskRepo.details) {
          await run(ToolCall('set_awaiting', {'id': t.id, 'question': null}));
        }
        if (sp.outcome.isNotEmpty) {
          await run(
              ToolCall('record_outcome', {'id': t.id, 'outcome': sp.outcome}));
        }
        final ack = sp.outcome.isEmpty
            ? ''
            : await _converse(
                sp.outcome,
                [_line(t)],
                'Thanks for telling me how it went; I noted it.',
                'This is finished and the user said how it went (it may not have happened). Acknowledge that in one sentence; do not ask how it went.');
        return [
          reply,
          if (ack.isNotEmpty) ack,
          sp.request == null
              ? 'If anything from it needs a reminder, just tell me.'
              : 'To set a reminder from it, send it on its own, e.g. "${sp.request}".',
        ].join(' ');
      }
      if (!before.event) return reply;
      if ((await tools.preferences?.get())?.followUp ?? false) {
        await run(ToolCall('set_awaiting',
            {'id': t.id, 'question': TaskRepo.outcomeQuestion}));
        return '$reply How did it go? Anything from it you want me to remind you about later?';
      }
      if (t.awaiting == TaskRepo.details) {
        await run(ToolCall('set_awaiting', {'id': t.id, 'question': null}));
      }
      return reply;
    } on ToolError {
      return reply; // cancelled mid-reply: the committed write still reports itself
    } catch (e) {
      debugPrint('follow-through metadata failed');
      return reply;
    }
  }

  // ---- commit: validate, then the executor is the only writer ----

  Future<String> _commit(CandidatePlan plan, String text,
      Map<String, int> timing, OperationJournal? journal,
      {bool recovering = false}) async {
    var p = plan;
    final v = validatePlan(p);
    _diag['validation'] = v.accepted ? 'ok' : v.reason!;
    if (!v.accepted) {
      _note = _header = _prefix = null;
      p = CandidatePlan(
          interpreter: p.interpreter,
          route: p.route,
          call: _say(v.reply!),
          evidence: p.evidence,
          authorization: p.authorization,
          modelAuthorization: p.modelAuthorization);
    }
    final memo = _memoryEffect != null && _auth.permitsReport && !recovering
        ? _memoryEffect
        : null;
    if (p.call.tool != 'respond' || p.effects.isNotEmpty) {
      _go(SessionState.executing);
    }
    _diag['tool'] = p.call.tool;
    _diag['db'] = p.call.tool == 'respond' ? 'none' : 'error';
    if ((p.writes || memo != null) && !recovering) {
      await journal?.mark(_op, OperationJournal.executing,
          action: p.toActionJson());
    }
    final receipts = <ExecutionReceipt>[];
    final opId = journal == null ? null : _op;
    Future<ExecutionReceipt> run(ToolCall c) async {
      final r = await tools.run(c, operationId: opId, recovering: recovering);
      receipts.add(r);
      return r;
    }

    final exec = Stopwatch()..start();
    try {
      if (memo != null) {
        await run(memo);
        _saved.add(memo.args['content'] as String);
      }
      for (final e in p.effects) {
        await run(e);
      }
      await _applyPending(p.pending);
      final before = await _before(p.call);
      final main = await run(p.call);
      if (p.call.tool != 'respond') _diag['db'] = 'ok';
      _diag['receipt'] = main.status.name;
      if (main.alarm != AlarmStatus.none) _diag['alarm'] = main.alarm.name;
      await _rememberTask(p.call);
      final reply = await _after(p.call, before, main.reply, text, run);
      lastTurn = TurnRecord(
          operationId: _op,
          plan: p,
          validation: v,
          receipts: receipts,
          reply: reply);
      if (receipts.any((r) => r.wrote)) {
        await journal?.mark(_op, OperationJournal.committed,
            receipt: jsonEncode(lastTurn!.toJson()));
      }
      return reply;
    } on ToolError catch (e) {
      receipts.add(ExecutionReceipt(
          tool: p.call.tool,
          status: ReceiptStatus.failed,
          operationId: opId,
          reply: e.message,
          error: e.message));
      _diag['receipt'] = 'failed';
      lastTurn = TurnRecord(
          operationId: _op,
          plan: p,
          validation: v,
          receipts: receipts,
          reply: e.message);
      rethrow;
    } finally {
      timing['execution'] = exec.elapsedMilliseconds;
    }
  }

  // ---- model-first semantic planning ----

  /// One grammar-constrained model call -> [Semantic] -> validated tool call.
  /// Null = no usable plan (rules take over; [lastFallbackReason] says why).
  /// The legacy interpreter uses plan-v1, the unified one plan-v2.
  Future<ToolCall?> _semantic(String text, Map<String, int> timing) async {
    var loaded = true;
    if (loadEngine != null) {
      try {
        loaded = await loadEngine!();
      } catch (_) {
        loaded = false;
      }
    }
    if (_cancelled) throw ToolError('cancelled');
    if (!loaded) {
      lastFallbackReason = 'the local model is not loaded';
      _diag['model'] = 'unavailable';
      _diag['fallback'] = 'not_loaded';
      return null;
    }
    final v2 = _mode == Interpreter.unified;
    final contract = v2 ? planContractV2 : promptContractVersion;
    final ctx = Stopwatch()..start();
    final open = await taskRepo.relevantTasks(text, cap: _taskCap);
    final draft = await _draft();
    final last = _lastTask == null ? null : await taskRepo.get(_lastTask!);
    // Only the user's own earlier words: assistant replies (old lists) never.
    final earlier = (await conversations.recent(id, n: 5))
        .where((m) =>
            m.role == 'user' &&
            m.content.trim() != text.trim() &&
            _safeHistorical(m.content))
        .map((m) =>
            m.content.length > 120 ? m.content.substring(0, 120) : m.content)
        .toList();
    // Context is global: the user's related words from any chat.
    final related = (await _related(text))
        .map((m) =>
            m.content.length > 120 ? m.content.substring(0, 120) : m.content)
        .where((m) => !earlier.contains(m))
        .toList();
    final p = Prompt(PromptKind.plan, text,
        now: _now(),
        contract: contract,
        // The most relevant tasks, listed by id: a stable order keeps the
        // KV-cached prefix valid from one message to the next.
        tasks: open.isEmpty
            ? '(none)'
            : [
                for (final t
                    in open.take(_taskCap).toList()
                      ..sort((a, b) => a.id.compareTo(b.id)))
                  _line(t),
                if (open.length > _taskCap)
                  '(and ${open.length - _taskCap} more)',
              ].join('\n'),
        context: [
          if (last != null && !last.done) 'Last task mentioned: ${_line(last)}',
          for (final m in earlier.reversed.take(2).toList().reversed)
            'Earlier user message: $m',
          for (final m in related.take(2))
            'Related earlier user message (any chat): $m',
        ].join('\n'),
        pending: draft == null
            ? null
            : '${draft.tool == 'create_reminder' ? 'reminder' : 'task'} '
                '"${draft.title}" still needs a time',
        // Profile (name, tone) stays in the KV-cached system prompt; the
        // memories picked for this message go in the user turn.
        memories: (await _personalMemories(text))
            .where(isUsefulPersonalMemory)
            .take(3)
            .toList(),
        tone: (await profile.get())?.tone,
        personalContext: buildPersonalContext(
            await profile.get() ?? const UserProfile(), const []));
    timing['context'] = ctx.elapsedMilliseconds;
    if (_cancelled) throw ToolError('cancelled');
    _diag['model'] = 'called';
    _diag['prompt'] = promptIdentity(contract);
    final Semantic s;
    try {
      // Streamed: the mood envelope (first field of the contract) is emitted
      // as soon as it completes, and a chat plan's reply prose flows into the
      // live draft while the plan is still generating. Only `chat` streams:
      // its reply is the answer itself and passes the same checks now that
      // the final text must pass later. Write/list/recall plans buffer —
      // their reply is a follow-up the app appends after its own exact
      // confirmation, and never a success claim (nothing has committed yet).
      final raw = await _complete(p, onRaw: (chunk) {
        if (_cancelled) return;
        final view = planStreamView(chunk);
        if (view.mood != null) {
          _emitMood(view.mood!, source: 'model:$contract');
        }
        if (view.intent != 'chat' || view.replyText == null) return;
        final next = _streamedDraft(
            view.replyText!,
            (t) =>
                safeReply(t, text) &&
                !echoes(t, text) &&
                !_groundless(t, open));
        if (next == null) return;
        _sendLive(next);
        _diag['stream'] = next.isEmpty ? 'withheld' : 'plan';
      });
      if (raw == null) {
        lastFallbackReason = 'the model was already asked this turn';
        _diag['fallback'] = 'model_budget';
        return null;
      }
      if (_logRaw) debugPrint('raw plan: $raw');
      s = parseSemantic(raw, version: v2 ? 2 : 1);
    } on PlatformException catch (e) {
      if (e.code == 'llama_cancelled' || _cancelled) {
        _cancelled = true;
        throw ToolError('cancelled');
      }
      if (e.code == 'prompt_too_long') return _say(tooLongReply);
      lastFallbackReason = 'the local model failed (${e.code})';
      _diag['model'] = 'failed';
      _diag['fallback'] = 'native_${e.code}';
      return null;
    } on ToolError {
      lastFallbackReason = 'the model reply was not a valid plan';
      _diag['model'] = 'invalid';
      _diag['fallback'] = 'invalid_plan';
      return null;
    } catch (_) {
      lastFallbackReason = 'the local model failed';
      _diag['model'] = 'failed';
      _diag['fallback'] = 'engine_exception';
      return null;
    }
    if (_cancelled) throw ToolError('cancelled');
    _diag['intent'] = s.intent;
    _modelAuth = s.authorization;
    if (s.authorization != null) _diag['auth_model'] = s.authorization!;
    final c = await _act(s, text, open, draft);
    final line = s.reply;
    if (c != null &&
        line != null &&
        c.tool == 'respond' &&
        _diag['clarify'] == 'event_time' &&
        isSafeFollowUp(line, text)) {
      _diag['reply'] = 'model_line';
      return _say('${c.args['text']} ${line.trim()}');
    }
    if (c != null && line != null && _writes.contains(c.tool)) {
      if (_diag['clarify'] != null) {
        _diag['line'] = 'clarify';
      } else if (!isSafeFollowUp(line, text)) {
        _diag['line'] = 'unsafe';
      } else {
        _modelLine = line.trim();
      }
    }
    if (c == null) {
      lastFallbackReason ??=
          'the model\'s reading (${s.intent}) did not fit your message';
      _diag['fallback'] ??= 'rejected_${s.intent}';
    }
    return c;
  }

  /// "#3 buy milk (due tomorrow (Thu 15 Oct) at 9:00 AM)": dates from SQLite.
  String _line(Task t) => '#${t.id} ${t.done ? '[done] ' : ''}${t.title}'
      '${t.dueAt == null ? '' : ' (due ${friendlyTime(t.dueAt!, _now())})'}'
      '${t.subject == null ? '' : ', about ${t.subject}'}';

  Future<void> _rememberTask(ToolCall c) async {
    if (c.tool == 'list_tasks') _lastTask = null;
    final id = c.args['id'];
    if (id is int && c.tool.endsWith('_task')) _lastTask = id;
    if (c.tool == 'create_task' || c.tool == 'create_reminder') {
      // The task this call is about: its explicit link, or the one pending task
      // with its title (a repeated reminder resolves to its existing task). A
      // standalone reminder (no preferences = no task) or an ambiguous title
      // clears the context; never "newest id", which may be unrelated.
      final link = c.args['task_id'];
      final standalone =
          c.tool == 'create_reminder' && tools.preferences == null;
      final same = standalone || link is int
          ? const <Task>[]
          : await taskRepo.byTitle(c.args['title'] as String);
      _lastTask = link is int
          ? link
          : same.length == 1
              ? same.single.id
              : null;
    }
  }

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

  /// The app's side of a semantic plan: every title/ref must come from the
  /// message, every date from the app's own parser, every id from SQLite.
  Future<ToolCall?> _act(
      Semantic s, String text, List<Task> open, ClarifyDraft? draft) async {
    final explicit = _fallback.fastRoute(text);
    final et = explicit?['type'] == 'tool' ? explicit!['tool'] as String : null;
    if (_ruleOnly.contains(et) ||
        (et == 'edit_task' &&
            (explicit!['arguments'] as Map).containsKey('title'))) {
      return null;
    }
    // A clear command the model filed as chat/list/recall: the rules handle it.
    bool command() =>
        _fallback.parseCreate(text) != null ||
        RuleEngine.doneRef(text) != null ||
        (_auth.kind == Authorization.request &&
            RegExp(r'^(?:please )?(?:delete|remove|mark|complete|move|push|postpone|change|rename|reschedule)\b',
                    caseSensitive: false)
                .hasMatch(text.trim()));
    // plan-v2: the model said "don't"/"only asking"/"what if" about a message
    // the app reads as an authorizing request. Its label never authorizes or
    // forbids alone: the plan is set aside and the deterministic rules,
    // which only act on fully recognized commands, decide.
    const doubtful = {'negated', 'question', 'hypothetical'};
    if (_mode == Interpreter.unified &&
        doubtful.contains(s.authorization) &&
        _auth.permitsWrite &&
        familyOf(_intentTool(s.intent)) != ActionFamily.read) {
      _diag['fallback'] = 'authorization_disagreement';
      lastFallbackReason =
          'the model read your message as ${s.authorization}, which did not match it';
      return null;
    }
    // A question about the user's own plans is answered from SQLite, never prose.
    final dataQuestion = !command() &&
        !RuleEngine.isNegated(text) &&
        (_dataQuestion.hasMatch(text) || _rangeIn(text) != null) &&
        RegExp(r"\b(?:what|which|any|anything|show|list|tell|pending|left|got)\b|\?",
                caseSensitive: false)
            .hasMatch(text);
    switch (s.intent) {
      case 'chat':
        if (command()) return null;
        // "did I miss anything", "am I behind on anything": the overdue list.
        if (_overdueQuestion.hasMatch(text) && !RuleEngine.isNegated(text)) {
          _header = rangeLabel('overdue');
          return ToolCall('list_tasks', rangeArgs('overdue', _now()));
        }
        if (dataQuestion) {
          _header = rangeLabel(_rangeIn(text) ?? 'all');
          return ToolCall(
              'list_tasks', rangeArgs(_rangeIn(text) ?? 'all', _now()));
        }
        final r = s.reply;
        final planned =
            r != null && !_groundless(r, open) && !echoes(r, text) ? r : null;
        // One call per turn: the plan already carries the toned answer.
        if (planned != null && safeReply(planned, text)) {
          _diag['reply'] = 'model';
          return _say(_corePolicy.concise(planned.trim(), text));
        }
        final said = await _converse(text, const [], planned ?? '',
            'Small talk or a general message. Reply naturally to what the user actually said, in one or two sentences.',
            history: await _chatHistory());
        if (said.isNotEmpty && !_groundless(said, open)) {
          return _say(_corePolicy.concise(said, text));
        }
        return planned == null ? null : _say(planned);
      case 'list':
        if (command()) return null;
        // "which reminders are coming up", "got any alarms lined up": the
        // reminders, not the task list.
        if (_reminderNoun.hasMatch(text) && !RuleEngine.isNegated(text)) {
          return ToolCall('list_reminders', const {});
        }
        if (!dataQuestion) {
          final read = _fallback.plan(text);
          if (read['type'] == 'tool' && read['tool'] == 'search_memory') {
            return _recall(text);
          }
          // The model heard a request to see plans in words the app's own
          // patterns miss ("gimme a rundown of tmrw", "did i miss anything").
          // Listing only reads, so that reading stands unless the user said
          // not to.
          if (!RuleEngine.isNegated(text)) {
            final range = _rangeIn(text) ?? RuleEngine.agendaRange(text);
            _header = rangeLabel(range);
            return ToolCall('list_tasks', rangeArgs(range, _now()));
          }
          final r = s.reply;
          if (r != null &&
              safeReply(r, text) &&
              !_groundless(r, open) &&
              !echoes(r, text)) {
            _diag['reply'] = 'model';
            return _say(r.trim());
          }
          return _say(await _converse(text, const [], 'Tell me a little more.',
              'Respond to the actual message. No tasks, reminders or actions were requested.',
              history: await _chatHistory()));
        }
        // The day the user said wins over a missing or different model range.
        final range = _rangeIn(text) ?? RuleEngine.agendaRange(text);
        _header = rangeLabel(range);
        return ToolCall('list_tasks', rangeArgs(range, _now()));
      case 'recall':
        if (command()) return null;
        if (_auth.kind == Authorization.hypothetical) {
          final relevant = named(open, text);
          final fallback = relevant.isEmpty
              ? "I haven't changed anything. Tell me if you decide to make that change."
              : '${relevant.map((t) => t.title).join(', ')} is still on your list. Let me know if you decide to change it.';
          return _say(await _converse(
              text,
              relevant.map(_line).toList(),
              fallback,
              'Discuss this possibility briefly. The user has not decided; no action was taken.',
              history: await _chatHistory()));
        }
        if (RuleEngine.isGeneralKnowledge(text)) {
          return _say(
              "I can't look that up offline, and I'd rather not guess.");
        }
        if (!isQuestionLike(text) &&
            !RegExp(r'\bremember\b', caseSensitive: false).hasMatch(text))
          return null;
        return _recall(text);
      case 'cancel_pending':
        if (draft == null) return null;
        _clearDraft();
        return _say('Okay, I dropped "${draft.title}".');
      case 'answer_pending':
        if (draft == null) return null;
        final w = s.when;
        final answer = w != null && _mentioned(w, text) ? w : text;
        final r = _fallback.resolveClarify(draft, answer);
        return await _answer(draft, r, answer) ?? _say(draft.prompt);
      case 'create_task':
      case 'create_reminder':
        return _create(s, text);
      case 'complete':
      case 'delete':
      case 'postpone':
        return _change(s, text, open);
      // plan-v2 follow-through intents: the same handlers as the
      // deterministic routes, reached when those did not recognize it.
      case 'progress':
      case 'outcome':
      case 'details':
        if (_mode != Interpreter.unified || !_auth.permitsReport) return null;
        return _followIntent(s, text, open);
    }
    return null;
  }

  /// The deterministic plan as a call. A memory lookup goes through [_recall],
  /// which also checks earlier chats; a bare search_memory call would not.
  Future<ToolCall> _rulePlanCall(String text) async {
    final plan = _fallback.plan(text);
    if (plan['type'] == 'tool' && plan['tool'] == 'search_memory') {
      return _recall(text);
    }
    return parseToolCall(jsonEncode(plan));
  }

  Future<ToolCall> _recall(String text) async {
    final hits = await memory.search(text, limit: 3);
    if (hits.isNotEmpty) return ToolCall('search_memory', {'query': text});
    final related = await _related(text);
    if (related.isNotEmpty) {
      return _say(
          'Earlier you said: ${related.map((m) => _cut(m.content)).join('; ')}');
    }
    return _say('I have nothing stored about that.');
  }

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

  /// plan-v2 progress / outcome / details: the target must be named in the
  /// message (every word of the model's ref) among the tasks that intent
  /// applies to; meeting details are read by the app's own parser.
  Future<ToolCall?> _followIntent(
      Semantic s, String text, List<Task> open) async {
    final ref = s.ref ?? s.title;
    final asked = await taskRepo.awaitingAnswers();
    final pool = switch (s.intent) {
      'outcome' => [
          for (final t in asked)
            if (t.awaiting == TaskRepo.outcomeQuestion) t
        ],
      'details' => [
          for (final t in asked)
            if (t.awaiting == TaskRepo.details && !t.done && t.dueAt != null) t
        ],
      _ => open,
    };
    if (pool.isEmpty) return null;
    List<Task> l;
    if (ref != null) {
      if (!_grounded(ref, text, all: true)) return null;
      l = await _matching(ref, pool);
      if (l.isEmpty) l = named(pool, ref);
    } else {
      l = pool.length == 1 ? pool : named(pool, text);
    }
    if (l.isEmpty) return null;
    if (l.length > 1) {
      return _ask(s.intent == 'progress' ? 'discuss' : s.intent, l, text,
          'Which one do you mean?');
    }
    final t = l.single;
    _evidence['target'] = 'model_ref';
    return switch (s.intent) {
      'progress' => _discuss(t, text),
      'outcome' => _recordOutcome(t, text),
      _ => _applyDetails(t, text),
    };
  }

  Future<ToolCall?> _create(Semantic s, String text) async {
    // Reminder vs silent task follows what the user said: "remind me…" always
    // notifies; a plain statement never gets an alarm it didn't ask for.
    if (RegExp(r'^(?:please )?(?:(?:can|could|would|will) (?:you|u) )?(?:book|order|send|pay|call|email)\b',
                caseSensitive: false)
            .hasMatch(text.trim()) &&
        !RegExp(r'\b(?:task|remind|reminder|need to|have to)\b',
                caseSensitive: false)
            .hasMatch(text)) {
      return _say(
          "I can't do that action for you. Would you like me to save it as a task or reminder?");
    }
    final asked = _fallback.parseCreate(text)?.tool == 'create_reminder' ||
        _notifyAsk.hasMatch(text);
    final reminder = asked;
    if (s.negated || RuleEngine.isNegated(text)) {
      return _say("Okay, I won't save that.");
    }
    if (RuleEngine.isQuestionOrNegated(text))
      return null; // "How do I buy milk?"
    if (RuleEngine.isTentative(text)) {
      _diag['clarify'] = 'tentative';
      return _say("I haven't set anything since that sounds undecided. "
          'If you want a reminder, tell me what and when.');
    }
    final parsed = _fallback.parseCreate(text);
    final title = parsed != null
        ? (parsed.note == RuleEngine.conflict
            ? parsed.title
                .replaceFirst(RegExp(r'^the ', caseSensitive: false), '')
            : parsed.title)
        : RuleEngine.cleanTitle(_fallback.readWhen(s.title ?? '').rest);
    if (RegExp(r'^(?:it|that|this)(?: later)?$', caseSensitive: false)
        .hasMatch(title)) {
      _diag['clarify'] = 'target';
      return _say('What should I remind you about?');
    }
    // Every content word of the title as the user said it: no invented object.
    if (title.isEmpty || !_grounded(title, text, all: true)) return null;
    _evidence['title'] = 'said';
    // Two commitments in the message: save both or neither, never a subset.
    if (RuleEngine.isMulti(title) || RuleEngine.isMulti(text)) {
      return _say(RuleEngine.multiReply(title));
    }
    // Overrides only when the message talks about them; explicit words win.
    final (mult, follow, _) = RuleEngine.extractFlags(text);
    final multiple = mult ??
        (RegExp(r'\b(?:multiple|several|times|alerts?|again)\b',
                    caseSensitive: false)
                .hasMatch(text)
            ? s.multiple
            : null);
    final followUp = follow ??
        (RegExp(r'\bfollow', caseSensitive: false).hasMatch(text)
            ? s.followUp
            : null);
    final tool = reminder ? 'create_reminder' : 'create_task';
    // Asking for one value keeps everything else that was understood.
    Future<ToolCall> askTime(String code, String lead,
        {String? time, DateTime? day}) async {
      _diag['clarify'] = code;
      final d = ClarifyDraft(
          tool: tool,
          title: title,
          multiple: multiple,
          followUp: followUp,
          time: time,
          day: day?.toIso8601String().substring(0, 10));
      await _setDraft(d);
      return _say('$lead${d.prompt}');
    }

    // The same resolver as the rules, over the whole message: the model's
    // time words never outvote other time words the user also said.
    final whole = _fallback.readWhen(text);
    if (whole.conflict) {
      return askTime('temporal_conflict',
          '${RuleEngine.timeProblem(whole, reminder, _now())} ');
    }
    // Whole-message words the app can't schedule ("in 2 weeks", "every
    // week", "30 February", or time words left over after the parts it did
    // read) outrank any valid-looking subset the model copied.
    if (whole.unsupported ||
        (whole.at != null && RuleEngine.hasUnsupportedDate(whole.rest))) {
      return askTime('unsupported_date', "I can't schedule that date yet. ");
    }
    DateTime? at;
    String? note;
    var reading = whole;
    final w = s.when;
    if (whole.at != null) {
      at = whole.at;
      note = whole.note;
      _evidence['time'] = whole.spans.isEmpty
          ? 'resolved'
          : whole.spans.map((s) => s.text).join(' | ');
    } else if (w != null && _mentioned(w, text)) {
      final r = _fallback.resolveWhen(w);
      if (!r.ok) {
        // Words the app can't schedule: ask, keep the item, never guess.
        return askTime(
            'model_when_unresolved', 'I couldn\'t read "$w" as a time. ');
      }
      at = r.at;
      note = r.note;
      reading = _fallback.readWhen(w);
      _evidence['time'] = 'model_copied: $w';
    } else if (RuleEngine.hasUnsupportedDate(text)) {
      return askTime('unsupported_date', "I can't schedule that date yet. ");
    }
    final anchor = reading.anchor;
    final deadline = at != null &&
        reading.role == TemporalRole.deadline &&
        (anchor?.relation == TemporalRelation.within ||
            anchor?.relation == TemporalRelation.before);
    if (deadline && _pronounTitle.hasMatch(title)) {
      // "Finish this within 10 minutes": a deadline for something unnamed.
      _diag['clarify'] = 'deadline_target';
      return _say('What needs to be done ${anchor!.text}? Tell me and I can '
          'add it as a task or set a reminder.');
    }
    // "I have a meeting tomorrow": a day but no time for an event the user
    // only mentioned. Ask its time (the day is kept) instead of guessing 9 AM.
    if (!reminder &&
        at != null &&
        reading.dated &&
        !reading.timed &&
        (isEventTitle(title) ||
            RegExp(r'^call(?: with .+)?$', caseSensitive: false)
                .hasMatch(title.trim()))) {
      return askTime('event_time', '', day: at);
    }
    final problem = RuleEngine.timeProblem(reading, reminder, _now());
    if (problem != null) return askTime('deadline_not_alert', '$problem ');
    if (at == null && !reminder) return ToolCall(tool, {'title': title});
    if (at == null || at.isBefore(_now())) {
      return askTime(at == null ? 'no_time_found' : 'time_passed',
          at == null ? '' : '${friendlyTime(at, _now())} has already passed. ',
          time: at == null || note != null ? null : RuleEngine.clockText(at));
    }
    if (note != null) _note = _note == null ? note : '$note $_note';
    return ToolCall(
        tool,
        reminder
            ? {
                'title': title,
                'at': at,
                if (multiple != null) 'multiple': multiple,
                if (followUp != null) 'follow_up': followUp,
              }
            : {'title': title, 'due': at});
  }

  Future<ToolCall?> _change(Semantic s, String text, List<Task> open) async {
    if (s.negated || RuleEngine.isQuestionOrNegated(text)) {
      return _say("I didn't change anything.");
    }
    // "Add a task to clean my room" never completes or deletes: the user's
    // words ask to create, so this plan is unsafe, not merely different.
    if (s.intent != 'postpone' && _fallback.parseCreate(text) != null) {
      return null;
    }
    final tool = const {
      'complete': 'complete_task',
      'delete': 'delete_task',
      'postpone': 'edit_task'
    }[s.intent]!;
    var ref = s.ref ?? s.title;
    var id = ref == null
        ? null
        : RegExp(r'^#?(\d+)(?:\s+\D.*)?$').firstMatch(ref.trim());
    var modelPicked = false;
    // The prompt offers "#id" from Current tasks: a model-picked id stands
    // when that task's own words are in the message, as if the user named it.
    if (id != null && !RegExp('(?:#|\\b)${id.group(1)}\\b').hasMatch(text)) {
      final picked =
          open.where((t) => t.id == int.parse(id!.group(1)!)).toList();
      if (picked.length != 1 || !_grounded(picked.single.title, text)) {
        return null;
      }
      ref = picked.single.title;
      id = null;
      modelPicked = true;
    }
    // Words must come from the message.
    if (ref != null &&
        id == null &&
        !modelPicked &&
        !_grounded(ref, text, all: true)) {
      return null;
    }
    Duration? shift;
    Map<String, Object?> args = const {};
    if (tool == 'edit_task') {
      final w = s.when;
      // The user's own "by 30 minutes" wins when the model reworded it.
      final by = RegExp(r'^.*\b(?:by|for)\s+(.+?)[.!?]*$', caseSensitive: false)
          .firstMatch(text);
      final d = (w == null || !_mentioned(w, text)
              ? null
              : RuleEngine.parseDuration(w)) ??
          (by == null ? null : RuleEngine.parseDuration(by.group(1)!));
      final r = w == null || d != null || !_mentioned(w, text)
          ? null
          : _fallback.resolveWhen(w);
      if (d != null) {
        shift = d;
      } else if (r != null && r.ok && r.at!.isAfter(_now())) {
        args = {'due': r.at};
      } else {
        return _say(
            'When should I move it to? Try "by 2 hours" or "tomorrow at 5pm".');
      }
      _evidence['time'] = 'model_copied: $w';
    }
    final pronoun = ref != null &&
        RegExp(r'^(?:it|that|this|that one|this one|the last one|the same one)$',
                caseSensitive: false)
            .hasMatch(ref.trim());
    final last = pronoun ? open.where((t) => t.id == _lastTask).toList() : null;
    var l = last ?? (ref == null ? <Task>[] : await _matching(ref, open));
    // A ref that names nothing ("postpone"): the task the message names.
    if (l.isEmpty && !modelPicked && id == null) {
      final said = named(open, text);
      if (said.length == 1) l = said;
    }
    final pick = TargetPick(
        tool: tool,
        args: args,
        shift: shift,
        ids: [for (final t in l) t.id],
        askedAt: _now());
    if (l.length == 1) {
      return _withId(pick, l.first.id,
          pronoun ? 'pronoun' : (id != null ? 'typed' : 'named'));
    }
    final choices = l.isEmpty ? open : l;
    if (choices.isEmpty) return _say("You don't have any pending tasks.");
    _setPick(TargetPick(
        tool: tool,
        args: args,
        shift: shift,
        ids: [for (final t in choices) t.id],
        askedAt: _now()));
    _lastTask = null;
    return _say(
        '${l.isEmpty ? 'I couldn\'t find ${ref == null ? 'which task you mean' : 'a pending task matching "$ref"'}.' : 'Several tasks match "$ref":'}\n'
        '${choices.take(_taskCap).map((t) => '#${t.id} ${t.title}${t.dueAt == null ? '' : ' (${friendlyTime(t.dueAt!, _now())})'}').join('\n')}\n'
        'Which one? Say the number, e.g. #${choices.first.id}.');
  }

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

  // ---- typed pending interactions (applied only when a turn commits) ----
  // The time question is global (main chat key; old per-chat rows remain
  // readable). A "Which one?" belongs to the chat that asked it (key
  // `pick:<chat>`) and lives for its next turn, across restarts.

  Future<ClarifyDraft?> _draft() async {
    final repo = pending;
    final raw = repo == null
        ? _memDraft
        : await repo.get(ConversationRepo.mainChatId) ?? await repo.get(id);
    if (raw == null) return null;
    try {
      return ClarifyDraft.fromJson(
          Map<String, Object?>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return null; // unreadable draft: treated as none
    }
  }

  Future<void> _setDraft(ClarifyDraft d) async {
    final old = await _draft();
    if (old != null && old.title != d.title) {
      _note = '(I replaced the unfinished "${old.title}" with this one.)';
    }
    _changes.add(PendingChange.setDraft(d));
  }

  void _clearDraft() => _changes.add(const PendingChange.clearDraft());

  void _setPick(TargetPick p) => _changes.add(PendingChange.setPick(p));

  String get _pickKey => 'pick:$id';

  /// This chat's "Which one?" if still fresh. Reading it consumes it at
  /// commit (unless this turn asks again).
  Future<TargetPick?> _loadPick() async {
    final raw = pending == null ? _memPick : await pending!.get(_pickKey);
    if (raw == null) return null;
    _pickStored = true;
    try {
      final p = TargetPick.fromJson(
          Map<String, Object?>.from(jsonDecode(raw) as Map));
      if (p == null) return null;
      final age = _now().difference(p.askedAt);
      if (age > TargetPick.maxAge || age < const Duration(minutes: -1)) {
        return null;
      }
      return p;
    } catch (_) {
      return null;
    }
  }

  Future<void> _storePick(TargetPick? p) async {
    final raw = p == null ? null : jsonEncode(p.toJson());
    final repo = pending;
    if (repo == null) {
      _memPick = raw;
    } else if (raw == null) {
      await repo.clear(_pickKey);
    } else {
      await repo.put(_pickKey, raw);
    }
  }

  Future<void> _applyPending(List<PendingChange> changes) async {
    var pickSet = false;
    for (final c in changes) {
      if (c.draft != null) {
        final raw = jsonEncode(c.draft!.toJson());
        final repo = pending;
        if (repo == null) {
          _memDraft = raw;
        } else {
          await repo.put(ConversationRepo.mainChatId, raw);
        }
      } else if (c.pick != null) {
        await _storePick(c.pick);
        pickSet = true;
      } else if (c.clearDraft) {
        final repo = pending;
        if (repo == null) {
          _memDraft = null;
        } else {
          await repo.clear(ConversationRepo.mainChatId);
          if (id != ConversationRepo.mainChatId) await repo.clear(id);
        }
      }
    }
    if (_pickStored && !pickSet) await _storePick(null);
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
    final j = _fallback.extractMemory(text);
    final m = j['memory'];
    if (j['remember'] != true || m is! String) return null;
    if (m.trim().isEmpty || m.length > 300) return null;
    if (!explicit && !isUsefulPersonalMemory(m)) return null;
    return (content: m, category: j['category'] as String? ?? 'fact');
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

  /// Stops the in-flight turn and waits for it to settle. A turn cancelled
  /// before its action runs executes nothing; an action already running finishes.
  Future<void> cancel() async {
    final op = _active;
    if (op == null) return;
    _cancelled = true;
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
