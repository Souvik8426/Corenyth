import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/repos.dart';
import 'calculator.dart';
import 'engine.dart';
import 'rule_engine.dart';
import 'semantic.dart';
import 'tools.dart';

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

/// One conversation = one session. The LLM is shared and owned by AppServices
/// (never unloaded here). All inference/action flow goes through the explicit
/// state machine above.
class AssistantSession {
  final LlmEngine engine;
  final RuleEngine _fallback;
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

  /// "Which one?" asked for an ambiguous task reference; a bare "#3" reply
  /// finishes it. In memory only: losing it loses no data.
  _Pick? _pick;

  /// Appended to this turn's reply (disclosed defaults, a replaced draft).
  String? _note;

  /// Put before this turn's reply (e.g. "Due tomorrow" over list rows).
  String? _header;

  /// Where the open clarification is stored; null keeps it in memory (tests).
  final PendingRepo? pending;
  String? _memDraft;

  /// The task this chat last created/changed (from SQLite ids), for "that one".
  /// Cleared when a list or "Which one?" was shown: a pronoun then must ask.
  int? _lastTask;

  /// Per-turn debug facts, no message text: model called/used/invalid/failed/
  /// unavailable, the semantic intent, the tool run and whether the DB write
  /// or read succeeded. Printed with the timing; never sent anywhere.
  Map<String, String> lastDiagnostics = const {};
  var _diag = <String, String>{};

  Future<void>? _starting;
  Future<String>? _active;
  Future<List<String>>? _closing;
  bool _closeRequested = false, _cancelled = false;
  final _saved = <String>[];

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
  })  : id = conversationId ?? ConversationRepo.newChatId(),
        clock = clock ?? DateTime.now,
        _fallback = RuleEngine(clock: clock);

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
  /// answers in prose, then the final reply). Returns '' when [cancel]led
  /// before any action ran.
  Future<String> handle(String text, {void Function(String)? onText}) {
    text = text.trim();
    if (text.isEmpty) return Future.value('');
    if (_s != SessionState.listening || _closeRequested || _active != null) {
      return Future.error(StateError('session is not listening ($_s)'));
    }
    _idle?.cancel();
    _cancelled = false;
    lastFallbackReason = null;
    lastTiming = const {};
    _note = null;
    _header = null;
    _diag = {};
    final op = _turn(text, onText);
    _active = op;
    return op.whenComplete(() => _active = null);
  }

  Future<String> _turn(String text, void Function(String)? onText) async {
    _go(SessionState.processing);
    final total = Stopwatch()..start();
    final timing = <String, int>{};
    try {
      await conversations.add(id, 'user', text);
      // Memory is written before any reply that says it was saved.
      final explicit = RuleEngine.isExplicitRemember(text);
      final saved = await _remember(text, explicit);
      String reply;
      try {
        final route = Stopwatch()..start();
        if (explicit) {
          timing['route'] = route.elapsedMilliseconds;
          if (_cancelled) return '';
          reply = saved != null
              ? "Okay, I'll remember that."
              : (RuleEngine.isTemporary(text)
                  ? "I won't store short-lived plans as memories. Want a reminder or task instead?"
                  : "That's too long for me to remember; try a shorter sentence.");
        } else {
          final call = await _route(text, onText, timing);
          timing['route'] ??= route.elapsedMilliseconds;
          if (_cancelled) return '';
          if (call.tool != 'respond') _go(SessionState.executing);
          _diag['tool'] = call.tool;
          _diag['db'] = call.tool == 'respond' ? 'none' : 'error';
          final exec = Stopwatch()..start();
          try {
            reply = await tools.execute(call);
            if (call.tool != 'respond') _diag['db'] = 'ok';
            await _rememberTask(call);
          } finally {
            timing['execution'] = exec.elapsedMilliseconds;
          }
        }
      } on ToolError catch (e) {
        if (_cancelled) return '';
        reply = e.message;
      }
      if (_header != null) reply = '$_header:\n$reply';
      if (_note != null) reply = '$reply $_note';
      await conversations.add(id, 'assistant', reply);
      onText?.call(reply);
      _go(SessionState.speaking);
      if (!_cancelled) await speak?.call(reply);
      return reply;
    } finally {
      timing['total'] = total.elapsedMilliseconds;
      lastTiming = Map.unmodifiable(timing);
      lastDiagnostics = Map.unmodifiable(_diag);
      debugPrint('turn timing ms: $lastTiming $lastDiagnostics');
      if (_s != SessionState.listening) _go(SessionState.listening);
      if (!_closeRequested) _armIdle();
    }
  }

  Future<ToolCall> _route(
      String text, void Function(String)? onText, Map<String, int> timing) async {
    final route = Stopwatch()..start();
    final early = await _early(text);
    timing['route'] = route.elapsedMilliseconds;
    if (early != null) return early;
    if (engineInUse == engine.name && engine is! RuleEngine) {
      final c = await _semantic(text, timing);
      if (c != null) return c;
    } else {
      _diag['model'] = 'unavailable';
    }
    return await _rules(text) ?? parseToolCall(jsonEncode(_fallback.plan(text)));
  }

  static ToolCall _say(String s) => ToolCall('respond', {'text': s});

  /// Settled without the model: "#3" for this session's "which one?", a
  /// calculation, or a reply that only gives the pending question's time.
  Future<ToolCall?> _early(String text) async {
    final pick = _pick;
    _pick = null;
    final n = RegExp(r'^(?:#|number |task )?(\d+)$', caseSensitive: false)
        .firstMatch(text.trim());
    if (pick != null && n != null) {
      final id = int.parse(n.group(1)!);
      if (pick.ids.contains(id)) return _withId(pick, id);
      _pick = pick;
      return _say("That isn't one of ${pick.ids.map((i) => '#$i').join(', ')}. Which one?");
    }
    final calc = calculate(text.trim());
    if (calc != null) return _say(calc);
    final draft = await _draft();
    if (draft != null && _fallback.isTimeAnswer(draft, text)) {
      return _answer(draft, _fallback.resolveClarify(draft, text));
    }
    return null;
  }

  /// Applies a clarification result: done (or cancelled) clears the draft.
  Future<ToolCall?> _answer(
      ClarifyDraft draft, ({Map<String, Object?> call, bool keep})? r) async {
    if (r == null) return null;
    if (!r.keep) await _clearDraft();
    return _call(r.call);
  }

  // ---- model-first semantic planning ----

  /// One grammar-constrained model call -> [Semantic] -> validated tool call.
  /// Null = no usable plan (rules take over; [lastFallbackReason] says why).
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
      return null;
    }
    final ctx = Stopwatch()..start();
    final open = await taskRepo.list();
    final draft = await _draft();
    final last = _lastTask == null ? null : await taskRepo.get(_lastTask!);
    // Only the user's own earlier words: assistant replies (old lists) never.
    final earlier = (await conversations.recent(id, n: 5))
        .where((m) => m.role == 'user')
        .map((m) => m.content.length > 120 ? m.content.substring(0, 120) : m.content)
        .toList();
    if (earlier.isNotEmpty) earlier.removeLast(); // this turn
    final p = Prompt(PromptKind.plan, text,
        now: clock(),
        tasks: open.isEmpty
            ? '(none)'
            : [
                for (final t in open.take(_taskCap)) _line(t),
                if (open.length > _taskCap) '(and ${open.length - _taskCap} more)',
              ].join('\n'),
        context: [
          if (last != null && !last.done) 'Last task mentioned: ${_line(last)}',
          for (final m in earlier.reversed.take(2).toList().reversed) 'Earlier user message: $m',
        ].join('\n'),
        pending: draft == null
            ? null
            : '${draft.tool == 'create_reminder' ? 'reminder' : 'task'} '
                '"${draft.title}" still needs a time',
        personalContext: buildPersonalContext(
            await profile.get() ?? const UserProfile(), const []));
    timing['context'] = ctx.elapsedMilliseconds;
    if (_cancelled) throw ToolError('cancelled');
    _diag['model'] = 'called';
    final Semantic s;
    try {
      // Greedy + grammar-constrained: a retry would repeat the same output.
      s = parseSemantic(await engine.complete(p));
    } on PlatformException catch (e) {
      if (e.code == 'llama_cancelled' || _cancelled) {
        _cancelled = true;
        throw ToolError('cancelled');
      }
      if (e.code == 'prompt_too_long') return _say(tooLongReply);
      lastFallbackReason = 'the local model failed (${e.code})';
      _diag['model'] = 'failed';
      return null;
    } on ToolError {
      lastFallbackReason = 'the model reply was not a valid plan';
      _diag['model'] = 'invalid';
      return null;
    } catch (_) {
      lastFallbackReason = 'the local model failed';
      _diag['model'] = 'failed';
      return null;
    }
    if (_cancelled) throw ToolError('cancelled');
    _diag['intent'] = s.intent;
    final c = await _act(s, text, open, draft);
    if (c == null) {
      lastFallbackReason ??= 'the model\'s reading (${s.intent}) did not fit your message';
    }
    return c;
  }

  /// "#3 buy milk (due tomorrow (Thu 15 Oct) at 9:00 AM)": dates from SQLite.
  String _line(Task t) =>
      '#${t.id} ${t.title}${t.dueAt == null ? '' : ' (due ${friendlyTime(t.dueAt!, clock())})'}';

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
      final standalone = c.tool == 'create_reminder' && tools.preferences == null;
      final same = standalone || link is int
          ? const <Task>[]
          : await taskRepo.byTitle(c.args['title'] as String);
      _lastTask = link is int ? link : same.length == 1 ? same.single.id : null;
    }
  }

  /// Commands the semantic schema has no intent for (rename, reminder
  /// edit/cancel/list): a plan can't stand in for them; the rules run them.
  static const _ruleOnly = {'edit_reminder', 'cancel_reminder', 'list_reminders'};

  /// The app's side of a semantic plan: every title/ref must come from the
  /// message, every date from the app's own parser, every id from SQLite.
  Future<ToolCall?> _act(
      Semantic s, String text, List<Task> open, ClarifyDraft? draft) async {
    final explicit = _fallback.fastRoute(text);
    final et = explicit?['type'] == 'tool' ? explicit!['tool'] as String : null;
    if (_ruleOnly.contains(et) ||
        (et == 'edit_task' && (explicit!['arguments'] as Map).containsKey('title'))) {
      return null;
    }
    // A clear command the model filed as chat/list/recall: the rules handle it.
    bool command() =>
        _fallback.parseCreate(text) != null || RuleEngine.doneRef(text) != null;
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
        if (dataQuestion) {
          _header = rangeLabel(_rangeIn(text) ?? 'all');
          return ToolCall('list_tasks', rangeArgs(_rangeIn(text) ?? 'all', clock()));
        }
        final r = s.reply;
        return r != null && !_groundless(r, open) ? _say(r) : null;
      case 'list':
        if (command()) return null;
        // The day the user said wins over a missing or different model range.
        final range = _rangeIn(text) ?? s.range ?? 'all';
        _header = rangeLabel(range);
        return ToolCall('list_tasks', rangeArgs(range, clock()));
      case 'recall':
        if (command()) return null;
        if (RuleEngine.isGeneralKnowledge(text)) {
          return _say("I can't look that up offline, and I'd rather not guess.");
        }
        return ToolCall('search_memory', {'query': s.title ?? text});
      case 'cancel_pending':
        if (draft == null) return null;
        await _clearDraft();
        return _say('Okay, I dropped "${draft.title}".');
      case 'answer_pending':
        if (draft == null) return null;
        final w = s.when;
        final r = _fallback.resolveClarify(
            draft, w != null && _mentioned(w, text) ? w : text);
        return await _answer(draft, r) ?? _say(draft.prompt);
      case 'create_task':
      case 'create_reminder':
        return _create(s, text);
      case 'complete':
      case 'delete':
      case 'postpone':
        return _change(s, text, open);
    }
    return null;
  }

  Future<ToolCall?> _create(Semantic s, String text) async {
    // Reminder vs silent task follows what the user said: "remind me…" always
    // notifies; a plain statement never gets an alarm it didn't ask for.
    final asked = _fallback.parseCreate(text)?.tool == 'create_reminder' ||
        RegExp(r'\b(?:remind|alert|notify|alarm)\b', caseSensitive: false).hasMatch(text);
    final reminder = asked;
    if (s.negated || RuleEngine.isNegated(text)) {
      return _say("Okay, I won't save that.");
    }
    if (RuleEngine.isQuestionOrNegated(text)) return null; // "How do I buy milk?"
    final title = RuleEngine.cleanTitle(s.title ?? '');
    // Every content word of the title as the user said it: no invented object.
    if (title.isEmpty || !_evidence(title, text, all: true)) return null;
    // Two commitments in the message: save both or neither, never a subset.
    if (RuleEngine.isMulti(title) || RuleEngine.isMulti(text)) {
      return _say(RuleEngine.multiReply(title));
    }
    // Overrides only when the message talks about them; explicit words win.
    final (mult, follow, _) = RuleEngine.extractFlags(text);
    final multiple = mult ??
        (RegExp(r'\b(?:multiple|several|times|alerts?|again)\b', caseSensitive: false)
                .hasMatch(text)
            ? s.multiple
            : null);
    final followUp = follow ??
        (RegExp(r'\bfollow', caseSensitive: false).hasMatch(text) ? s.followUp : null);
    final tool = reminder ? 'create_reminder' : 'create_task';
    DateTime? at;
    String? note;
    final w = s.when;
    if (w != null && _mentioned(w, text)) {
      final r = _fallback.resolveWhen(w);
      if (!r.ok) {
        // Words the app can't schedule: ask, keep the item, never guess.
        await _setDraft(ClarifyDraft(
            tool: tool, title: title, multiple: multiple, followUp: followUp));
        return _say('I couldn\'t read "$w" as a time. '
            '${(await _draft())!.prompt}');
      }
      at = r.at;
      note = r.note;
    }
    if (at == null) {
      // The model left out a time the user did say ("tomo"): the app finds it.
      final found = _fallback.findWhen(text);
      if (found.at != null) {
        at = found.at;
        note = found.note;
      } else if (RuleEngine.hasUnsupportedDate(text)) {
        await _setDraft(ClarifyDraft(
            tool: tool, title: title, multiple: multiple, followUp: followUp));
        return _say("I can't schedule that date yet. ${(await _draft())!.prompt}");
      }
    }
    if (at == null && !reminder) return ToolCall(tool, {'title': title});
    if (at == null || at.isBefore(clock())) {
      final d = ClarifyDraft(
          tool: tool,
          title: title,
          multiple: multiple,
          followUp: followUp,
          time: at == null || note != null ? null : RuleEngine.clockText(at));
      await _setDraft(d);
      return _say('${at == null ? '' : '${friendlyTime(at, clock())} has already passed. '}'
          '${d.prompt}');
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
    final tool = const {
      'complete': 'complete_task',
      'delete': 'delete_task',
      'postpone': 'edit_task'
    }[s.intent]!;
    final ref = s.ref ?? s.title;
    final id = ref == null ? null : RegExp(r'^#?(\d+)$').firstMatch(ref.trim());
    // A number must be typed by the user; words must come from the message.
    if (ref != null &&
        (id != null
            ? !RegExp('(?:#|\\b)${id.group(1)}\\b').hasMatch(text)
            : !_evidence(ref, text, all: true))) {
      return null;
    }
    Duration? shift;
    Map<String, Object?> args = const {};
    if (tool == 'edit_task') {
      final w = s.when;
      final d = w == null || !_mentioned(w, text) ? null : RuleEngine.parseDuration(w);
      final r = w == null || d != null || !_mentioned(w, text) ? null : _fallback.resolveWhen(w);
      if (d != null) {
        shift = d;
      } else if (r != null && r.ok && r.at!.isAfter(clock())) {
        args = {'due': r.at};
      } else {
        return _say('When should I move it to? Try "by 2 hours" or "tomorrow at 5pm".');
      }
    }
    final pronoun = ref != null &&
        RegExp(r'^(?:it|that|this|that one|this one|the last one|the same one)$',
                caseSensitive: false)
            .hasMatch(ref.trim());
    final last = pronoun ? open.where((t) => t.id == _lastTask).toList() : null;
    final l = last ?? (ref == null ? <Task>[] : await _matching(ref, open));
    if (l.length == 1) {
      return _withId((tool: tool, args: args, shift: shift, ids: [l.first.id]), l.first.id);
    }
    final choices = l.isEmpty ? open : l;
    if (choices.isEmpty) return _say("You don't have any pending tasks.");
    _pick = (tool: tool, args: args, shift: shift, ids: [for (final t in choices) t.id]);
    _lastTask = null;
    return _say('${l.isEmpty ? 'I couldn\'t find ${ref == null ? 'which task you mean' : 'a pending task matching "$ref"'}.' : 'Several tasks match "$ref":'}\n'
        '${choices.take(_taskCap).map((t) => '#${t.id} ${t.title}${t.dueAt == null ? '' : ' (${friendlyTime(t.dueAt!, clock())})'}').join('\n')}\n'
        'Which one? Say the number, e.g. #${choices.first.id}.');
  }

  static final _stop = {'the', 'my', 'a', 'an', 'to', 'of', 'for', 'with', 'task', 'i'};
  static Set<String> _words(String s) => {
        for (final w in normTitle(s).split(' '))
          if (w.isNotEmpty && !_stop.contains(w)) RuleEngine.stem(w)
      };

  /// At least half of [phrase]'s words occur in [text] (stems compared):
  /// the model may tidy wording, not invent it.
  /// References need every word ([all]): "bring milk" is not "buying milk".
  static bool _evidence(String phrase, String text, {bool all = false}) {
    final p = _words(phrase), t = _words(text);
    final hits = p.where(t.contains).length;
    return p.isNotEmpty && (all ? hits == p.length : hits * 2 >= p.length);
  }

  /// today/tomorrow named in the message itself (incl. "tomo"), else null.
  String? _rangeIn(String text) {
    if (RegExp(r'\boverdue\b', caseSensitive: false).hasMatch(text)) return 'overdue';
    final at = _fallback.parseWhen(text).$1;
    if (at == null) return null;
    final now = clock();
    final days = DateTime.utc(at.year, at.month, at.day)
        .difference(DateTime.utc(now.year, now.month, now.day))
        .inDays;
    return days == 0 ? 'today' : days == 1 ? 'tomorrow' : null;
  }

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
    if (id != null) return open.where((t) => t.id == int.parse(id.group(1)!)).toList();
    final exact = open.where((t) => normTitle(t.title) == normTitle(ref)).toList();
    if (exact.isNotEmpty) return exact;
    final want = _words(ref);
    if (want.isEmpty) return [];
    return open.where((t) => _words(t.title).containsAll(want)).toList();
  }

  /// A chat reply stating task facts (ids, due dates, titles) or claiming an
  /// action: only the database may answer those.
  static bool _groundless(String reply, List<Task> open) {
    if (_claim.hasMatch(reply) ||
        RegExp(r'#\d|\bdue\b|\d{4}-\d{2}-\d{2}|\breminders?\b|\btasks?\b|\btoday\b|\btomorrow\b|'
                r'\btonight\b|\bpending\b|\bnothing (?:left|due|planned)\b|\bschedule', caseSensitive: false)
            .hasMatch(reply)) {
      return true;
    }
    final r = ' ${normTitle(reply)} ';
    return open.any((t) => normTitle(t.title).length > 3 && r.contains(' ${normTitle(t.title)} '));
  }

  // ---- pending clarification (persisted per chat) ----

  Future<ClarifyDraft?> _draft() async {
    final repo = pending;
    final raw = repo == null ? _memDraft : await repo.get(id);
    if (raw == null) return null;
    try {
      return ClarifyDraft.fromJson(Map<String, Object?>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return null; // unreadable draft: treated as none
    }
  }

  Future<void> _setDraft(ClarifyDraft d) async {
    final old = await _draft();
    if (old != null && old.title != d.title) {
      _note = '(I replaced the unfinished "${old.title}" with this one.)';
    }
    final raw = jsonEncode(d.toJson());
    final repo = pending;
    if (repo == null) {
      _memDraft = raw;
    } else {
      await repo.put(id, raw);
    }
  }

  Future<void> _clearDraft() async {
    final repo = pending;
    if (repo == null) {
      _memDraft = null;
    } else {
      await repo.clear(id);
    }
  }

  // ---- rules fallback (no model, or no usable plan) ----

  Future<ToolCall?> _rules(String text) async {
    final draft = await _draft();
    if (draft != null && _fallback.parseCreate(text) == null) {
      final r = await _answer(draft, _fallback.resolveClarify(draft, text));
      if (r != null) return r;
    }

    final rp = RuleEngine.relativePostpone(text);
    if (rp != null) {
      final delta = RuleEngine.parseDuration(rp.$2);
      if (delta == null) {
        return _say('How long should I postpone it? Try "by 2 hours" or '
            '"postpone gym to tomorrow at 5".');
      }
      return await _byRef('edit_task', const {}, rp.$1, shift: delta) ??
          _say('I couldn\'t find a pending task called "${rp.$1}".');
    }

    final done = RuleEngine.doneRef(text);
    if (done != null) {
      final c = await _byRef('complete_task', const {}, done.first, also: done.skip(1));
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
      _pick = (tool: 'complete_task', args: const {}, shift: null,
          ids: [for (final t in open) t.id]);
      return _say('I couldn\'t find a pending task called "${done.first}". '
          'Which one did you finish?\n'
          '${open.take(10).map((t) => '#${t.id} ${t.title}').join('\n')}\n'
          'Say the number, e.g. #${open.first.id}.');
    }

    final ask = _fallback.maybeClarify(text);
    if (ask != null) {
      await _setDraft(ask);
      return _say('${_fallback.clarifyReason(text)}${ask.prompt}');
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
    final n = RegExp(r'^(?:task )?#?(\d+)$', caseSensitive: false).firstMatch(ref);
    final List<Task> l;
    if (n != null) {
      final t = await taskRepo.get(int.parse(n.group(1)!));
      l = [if (t != null && !t.done) t];
    } else {
      final seen = <int>{};
      l = [
        for (final v in [ref, ...also]) ...await taskRepo.byTitle(v)
      ].where((t) => seen.add(t.id)).toList();
    }
    if (l.isEmpty) return null;
    final pick = (tool: tool, args: args, shift: shift, ids: [for (final t in l) t.id]);
    if (l.length == 1) return _withId(pick, l.first.id);
    _pick = pick;
    return _say('Several tasks match "$ref":\n'
        '${l.map((t) => '#${t.id} ${t.title}${t.dueAt == null ? '' : ' (${friendlyTime(t.dueAt!, clock())})'}').join('\n')}\n'
        'Which one? Say the number, e.g. #${l.first.id}.');
  }

  Future<ToolCall> _withId(_Pick p, int id) async {
    final args = {...p.args, 'id': id};
    if (p.shift != null) {
      args['due'] = ((await taskRepo.get(id))?.dueAt ?? clock()).add(p.shift!);
    }
    return ToolCall(p.tool, args);
  }

  /// Deterministic, incremental memory: explicit "remember ..." requests and
  /// clear personal facts are stored as they are said (no model, no close-time pass).
  Future<String?> _remember(String text, bool explicit) async {
    final j = _fallback.extractMemory(text);
    final m = j['memory'];
    if (j['remember'] != true || m is! String) return null;
    if (m.trim().isEmpty || m.length > 300) return null;
    if (!explicit && !isUsefulPersonalMemory(m)) return null;
    await memory.add(m, category: j['category'] as String? ?? 'fact');
    _saved.add(m);
    return m;
  }

  static const tooLongReply =
      "That message is too long for me to handle on this device. Please try a shorter message.";

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

typedef _Pick = ({String tool, Map<String, Object?> args, Duration? shift, List<int> ids});

/// A model reply saying it did something; only tools do things.
final _claim = RegExp(
    r"^(?:(?:ok(?:ay)?|sure|done|great)[,!.]?\s*)?(?:i(?:'ve| have|'ll| will)?\s+)?(?:set|added|created|scheduled|saved|deleted|removed|completed|marked|cancell?ed|updated|reminded|postponed)\b",
    caseSensitive: false);
