import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/repos.dart';
import 'calculator.dart';
import 'engine.dart';
import 'follow_through.dart';
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

  /// Put before this turn's reply (an outcome noted alongside a new reminder).
  String? _prefix;

  /// This turn's own early-alert offset ("15 minutes before"), see [leadOverride].
  int? _leadMin;

  /// The message as typed (before any [leadOverride] stripping).
  String _said = '';

  /// Where the open clarification is stored; null keeps it in memory (tests).
  final PendingRepo? pending;

  /// Evening-review participation: a task the user talks about is answered.
  final ReviewRepo? review;
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
    this.review,
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
    _prefix = null;
    _leadMin = null;
    _said = text;
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
          final call = await _adjust(await _route(text, onText, timing));
          timing['route'] ??= route.elapsedMilliseconds;
          if (_cancelled) return '';
          if (call.tool != 'respond') _go(SessionState.executing);
          _diag['tool'] = call.tool;
          _diag['db'] = call.tool == 'respond' ? 'none' : 'error';
          final exec = Stopwatch()..start();
          try {
            final before = await _before(call);
            reply = await tools.execute(call);
            if (call.tool != 'respond') _diag['db'] = 'ok';
            await _rememberTask(call);
            reply = await _after(call, before, reply, text);
          } finally {
            timing['execution'] = exec.elapsedMilliseconds;
          }
        }
      } on ToolError catch (e) {
        if (_cancelled) return '';
        reply = e.message;
      }
      if (_header != null) reply = '$_header:\n$reply';
      if (_prefix != null) reply = '$_prefix $reply';
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

  Future<ToolCall> _route(String text, void Function(String)? onText,
      Map<String, int> timing) async {
    final route = Stopwatch()..start();
    final early = await _early(text);
    if (early != null) {
      timing['route'] = route.elapsedMilliseconds;
      return early;
    }
    final lead = leadOverride(text);
    if (lead != null) {
      _leadMin = lead.minutes;
      text = lead.text;
    }
    final follow = await _followThrough(text);
    timing['route'] = route.elapsedMilliseconds;
    if (follow != null) return follow;
    if (engineInUse == engine.name && engine is! RuleEngine) {
      final c = await _semantic(text, timing);
      if (c != null) return c;
    } else {
      _diag['model'] = 'unavailable';
    }
    return await _rules(text) ??
        parseToolCall(jsonEncode(_fallback.plan(text)));
  }

  static ToolCall _say(String s) => ToolCall('respond', {'text': s});

  /// Settled without the model: "#3" for this session's "which one?", a
  /// calculation, or a reply that only gives the pending question's time.
  Future<ToolCall?> _early(String text) async {
    final pick = _pick;
    _pick = null;
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
        _pick = pick;
        return _say('Which one? Please give the full name or task number.');
      }
    }
    if (pick != null && selected != null) {
      final id = selected;
      if (pick.ids.contains(id)) {
        final said = pick.args['text'];
        if (said is! String) return _withId(pick, id);
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
      _pick = pick;
      return _say(
          "That isn't one of ${pick.ids.map((i) => '#$i').join(', ')}. Which one?");
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

  // ---- follow-through: daily schedules, meeting details/outcomes, updates ----

  static final _createCue = RegExp(
      r'\b(?:remind|alert|notify|add|task|need to|have to|must)\b',
      caseSensitive: false);

  /// A clear command the rules would run; never read as an answer or an update.
  bool _isCommand(String text) =>
      _fallback.parseCreate(text) != null ||
      RuleEngine.doneRef(text) != null ||
      _fallback.fastRoute(text)?['type'] == 'tool';

  /// Settled from SQLite before any planning: a daily schedule, an answer to
  /// a task's open question (stored on the task, so any chat or a restart can
  /// answer it, and anything else simply routes on), a finished meeting, news
  /// about existing work, or a briefing. Null = route normally.
  Future<ToolCall?> _followThrough(String text) async {
    final draft = await _draft(); // "remind me to stretch" -> "daily at 8am"
    final daily = (_createCue.hasMatch(text) || draft != null) &&
            !RuleEngine.isQuestionOrNegated(text)
        ? _fallback.parseDaily(text)
        : null;
    if (daily != null) {
      if (daily.problem != null) return _say(daily.problem!);
      final s = daily.schedule!;
      var title = RuleEngine.cleanTitle(_fallback.parseCreate(s.rest)?.title ??
          s.rest.replaceFirst(
              RegExp(r'^\s*(?:please\s+)?(?:remind me|add (?:a )?task:?)\s*',
                  caseSensitive: false),
              ''));
      if (title.isEmpty && draft != null) {
        title = draft.title;
        await _clearDraft();
      }
      if (title.isEmpty)
        return _say('What should I remind you about every day?');
      if (RuleEngine.isMulti(title)) return _say(RuleEngine.multiReply(title));
      if (RuleEngine.hasUnsupportedDate(title)) {
        return _say("I couldn't read all of that schedule, so I saved nothing. "
            'Try e.g. "remind me daily at 8:46 AM until 5 November to take medicine".');
      }
      if (s.note != null) _note = s.note;
      return ToolCall('create_daily',
          {'title': title, 'minute': s.hour * 60 + s.minute, 'until': s.until});
    }
    final asked = await taskRepo.awaitingAnswers();
    final command = _isCommand(text);
    final details = [
      for (final t in asked)
        if (t.awaiting == TaskRepo.details && !t.done && t.dueAt != null) t
    ];
    if (details.isNotEmpty && !command) {
      final c = await _details(details, text);
      if (c != null) return c;
    }
    final done = eventDone(text);
    if (done != null) {
      final c = await _eventDone(done);
      if (c != null) return c;
    }
    final outcomes = [
      for (final t in asked)
        if (t.awaiting == TaskRepo.outcomeQuestion) t
    ];
    final said = splitRequest(text).outcome;
    if (outcomes.isNotEmpty &&
        said.isNotEmpty &&
        looksLikeOutcome(said) &&
        !_isCommand(said)) {
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
    }
    if (isProgressUpdate(text) && !command) {
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
      if (l.length > 1)
        return _ask('discuss', l, text, 'Which one do you mean?');
    }
    if (isBriefingRequest(text) && _fallback.parseCreate(text) == null) {
      return ToolCall('briefing', const {});
    }
    return null;
  }

  /// "Which one?" for a follow-through reply; a bare "#3" finishes it with [text].
  ToolCall _ask(String tool, List<Task> l, String text, String question) {
    _pick = (
      tool: tool,
      args: {'text': text},
      shift: null,
      ids: [for (final t in l) t.id]
    );
    _lastTask = null;
    return _say('$question\n${l.take(_taskCap).map(_line).join('\n')}\n'
        'Say the number, e.g. #${l.first.id}.');
  }

  /// The last assistant message here asked how something went (or, with
  /// [phrase], asked that question).
  Future<bool> _justAsked([String phrase = 'how did']) async {
    final last = (await conversations.recent(id, n: 3))
        .where((m) => m.role == 'assistant')
        .lastOrNull;
    return last != null &&
        ((phrase == 'how did' && last.kind == 'follow_up') ||
            last.content.toLowerCase().contains(phrase));
  }

  Future<ToolCall?> _details(List<Task> open, String text) async {
    const asked = 'what is it about';
    if (declinesDetails(text) && open.length == 1 && await _justAsked(asked)) {
      await taskRepo.setAwaiting(open.single.id, null);
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

  /// Saves end time/subject; a known end replaces the follow-up estimate.
  Future<ToolCall?> _applyDetails(Task t, String text) async {
    final start = t.dueAt;
    final d = start == null ? null : eventDetails(text, start);
    if (d == null) return null;
    try {
      if (!await taskRepo.setEventDetails(t.id,
          endsAt: d.end, subject: d.subject)) {
        return _say(
            'That task no longer exists, so I left everything as it was.');
      }
    } on ArgumentError {
      return _say("That end time isn't after ${t.title} starts "
          '(${friendlyTime(start!, clock())}). When does it end?');
    }
    _lastTask = t.id;
    await review?.answered(t.id);
    final sync = await tools.sync();
    final follow = (await tools.reminders.upcoming())
        .where((r) => r.taskId == t.id && r.kind == 'follow_up')
        .firstOrNull;
    return _say([
      'Got it: ${t.title}'
          '${d.end == null ? '' : ' ends ${friendlyTime(d.end!, clock())}'}'
          '${d.subject == null ? '' : '${d.end == null ? ' is' : ','} about ${d.subject}'}.',
      if (d.note != null) d.note!,
      if (follow != null)
        "I'll check in ${friendlyTime(follow.triggerAt, clock())} to ask how it went.",
      if (sync.isNotEmpty) sync.trim(),
    ].join(' '));
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
    if (l.length == 1)
      return ToolCall('complete_task', {...args, 'id': l.single.id});
    _pick = (
      tool: 'complete_task',
      args: args,
      shift: null,
      ids: [for (final t in l) t.id]
    );
    _lastTask = null;
    return _say(
        'Several tasks match "${done.ref}":\n${l.take(_taskCap).map(_line).join('\n')}\n'
        'Which one? Say the number, e.g. #${l.first.id}.');
  }

  /// Stores how [t] went; a "remind me…" part becomes this turn's request.
  Future<ToolCall> _recordOutcome(Task t, String text) async {
    final sp = splitRequest(text);
    if (sp.outcome.isNotEmpty) await taskRepo.setOutcome(t.id, sp.outcome);
    await review?.answered(t.id);
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
    await review?.answered(t.id);
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

  /// The user's own earlier messages from any chat sharing words with [text]
  /// (this turn excluded). Optional context: a failed read is just none.
  Future<List<Message>> _related(String text) async {
    try {
      return (await conversations.relevant(text, limit: 4))
          .where((m) =>
              m.content.trim() != _said && m.content.trim() != text.trim())
          .take(3)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// A short reply from the local model about facts the app read, in the
  /// user's tone. Only prose: anything claiming an action, carrying an
  /// ungrounded number, or not a plain reply falls back to [fallback].
  Future<String> _converse(
      String text, List<String> facts, String fallback, String goal) async {
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
        now: clock(),
        context: context,
        personalContext: buildPersonalContext(
            await profile.get() ?? const UserProfile(), const []));
    String? raw;
    try {
      raw = await engine.complete(p);
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
          safeReply(r, '$context\n$text')) {
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
    if (c.tool == 'create_task' &&
        tools.preferences != null &&
        due is DateTime &&
        due.isAfter(clock()) &&
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
  /// message already gave. Metadata only; a failure here never hides the
  /// write's own reply.
  Future<String> _after(ToolCall c, ({Task task, bool event})? before,
      String reply, String text) async {
    try {
      if (c.tool == 'create_reminder' && _lastTask != null) {
        final t = await taskRepo.get(_lastTask!);
        if (t == null || t.done || !isEventTitle(t.title)) return reply;
        final more = <String>[];
        if (t.awaiting == null && t.endsAt == null && t.subject == null) {
          await taskRepo.setAwaiting(t.id, TaskRepo.details);
          final follow = (await tools.reminders.upcoming())
              .any((r) => r.taskId == t.id && r.kind == 'follow_up');
          more.add(follow
              ? 'When does it end, and what is it about? Then I can check in right after it ends. (Optional.)'
              : 'Optional: when does it end, and what is it about?');
        }
        final k = keyWords(t.title).where((w) => !isEventTitle(w)).toSet();
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
      if (c.tool != 'complete_task' || before == null || !before.event)
        return reply;
      final t = before.task;
      await review?.answered(t.id);
      final outcome =
          (c.args['outcome'] as String?) ?? eventDone(text)?.outcome;
      if (outcome != null) {
        final sp = splitRequest(outcome);
        if (t.awaiting == TaskRepo.details)
          await taskRepo.setAwaiting(t.id, null);
        if (sp.outcome.isNotEmpty) await taskRepo.setOutcome(t.id, sp.outcome);
        final ack = sp.outcome.isEmpty
            ? ''
            : await _converse(
                sp.outcome,
                [_line(t)],
                'Thanks for telling me how it went; I noted it.',
                'The meeting is over and the user said how it went. Acknowledge that in one sentence; do not ask how it went.');
        return [
          reply,
          if (ack.isNotEmpty) ack,
          sp.request == null
              ? 'If anything from it needs a reminder, just tell me.'
              : 'To set a reminder from it, send it on its own, e.g. "${sp.request}".',
        ].join(' ');
      }
      if ((await tools.preferences?.get())?.followUp ?? false) {
        await taskRepo.setAwaiting(t.id, TaskRepo.outcomeQuestion);
        return '$reply How did it go? Anything from it you want me to remind you about later?';
      }
      if (t.awaiting == TaskRepo.details)
        await taskRepo.setAwaiting(t.id, null);
      return reply;
    } on ToolError {
      return reply; // cancelled mid-reply: the committed write still reports itself
    } catch (e) {
      debugPrint('follow-through metadata failed: $e');
      return reply;
    }
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
        .map((m) =>
            m.content.length > 120 ? m.content.substring(0, 120) : m.content)
        .toList();
    if (earlier.isNotEmpty) earlier.removeLast(); // this turn
    // Context is global: the user's related words from any chat.
    final related = (await _related(text))
        .map((m) =>
            m.content.length > 120 ? m.content.substring(0, 120) : m.content)
        .where((m) => !earlier.contains(m))
        .toList();
    final p = Prompt(PromptKind.plan, text,
        now: clock(),
        tasks: open.isEmpty
            ? '(none)'
            : [
                for (final t in open.take(_taskCap)) _line(t),
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
      lastFallbackReason ??=
          'the model\'s reading (${s.intent}) did not fit your message';
    }
    return c;
  }

  /// "#3 buy milk (due tomorrow (Thu 15 Oct) at 9:00 AM)": dates from SQLite.
  String _line(Task t) => '#${t.id} ${t.done ? '[done] ' : ''}${t.title}'
      '${t.dueAt == null ? '' : ' (due ${friendlyTime(t.dueAt!, clock())})'}'
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
          return ToolCall(
              'list_tasks', rangeArgs(_rangeIn(text) ?? 'all', clock()));
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
          return _say(
              "I can't look that up offline, and I'd rather not guess.");
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
        RegExp(r'\b(?:remind|alert|notify|alarm)\b', caseSensitive: false)
            .hasMatch(text);
    final reminder = asked;
    if (s.negated || RuleEngine.isNegated(text)) {
      return _say("Okay, I won't save that.");
    }
    if (RuleEngine.isQuestionOrNegated(text))
      return null; // "How do I buy milk?"
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
        return _say(
            "I can't schedule that date yet. ${(await _draft())!.prompt}");
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
      return _say(
          '${at == null ? '' : '${friendlyTime(at, clock())} has already passed. '}'
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
      final d = w == null || !_mentioned(w, text)
          ? null
          : RuleEngine.parseDuration(w);
      final r = w == null || d != null || !_mentioned(w, text)
          ? null
          : _fallback.resolveWhen(w);
      if (d != null) {
        shift = d;
      } else if (r != null && r.ok && r.at!.isAfter(clock())) {
        args = {'due': r.at};
      } else {
        return _say(
            'When should I move it to? Try "by 2 hours" or "tomorrow at 5pm".');
      }
    }
    final pronoun = ref != null &&
        RegExp(r'^(?:it|that|this|that one|this one|the last one|the same one)$',
                caseSensitive: false)
            .hasMatch(ref.trim());
    final last = pronoun ? open.where((t) => t.id == _lastTask).toList() : null;
    final l = last ?? (ref == null ? <Task>[] : await _matching(ref, open));
    if (l.length == 1) {
      return _withId((tool: tool, args: args, shift: shift, ids: [l.first.id]),
          l.first.id);
    }
    final choices = l.isEmpty ? open : l;
    if (choices.isEmpty) return _say("You don't have any pending tasks.");
    _pick = (
      tool: tool,
      args: args,
      shift: shift,
      ids: [for (final t in choices) t.id]
    );
    _lastTask = null;
    return _say(
        '${l.isEmpty ? 'I couldn\'t find ${ref == null ? 'which task you mean' : 'a pending task matching "$ref"'}.' : 'Several tasks match "$ref":'}\n'
        '${choices.take(_taskCap).map((t) => '#${t.id} ${t.title}${t.dueAt == null ? '' : ' (${friendlyTime(t.dueAt!, clock())})'}').join('\n')}\n'
        'Which one? Say the number, e.g. #${choices.first.id}.');
  }

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
  static bool _evidence(String phrase, String text, {bool all = false}) {
    final p = _words(phrase), t = _words(text);
    final hits = p.where(t.contains).length;
    return p.isNotEmpty && (all ? hits == p.length : hits * 2 >= p.length);
  }

  /// today/tomorrow named in the message itself (incl. "tomo"), else null.
  String? _rangeIn(String text) {
    if (RegExp(r'\boverdue\b', caseSensitive: false).hasMatch(text))
      return 'overdue';
    final at = _fallback.parseWhen(text).$1;
    if (at == null) return null;
    final now = clock();
    final days = DateTime.utc(at.year, at.month, at.day)
        .difference(DateTime.utc(now.year, now.month, now.day))
        .inDays;
    return days == 0
        ? 'today'
        : days == 1
            ? 'tomorrow'
            : null;
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

  // ---- global pending clarification; old per-chat rows remain readable ----

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
    final raw = jsonEncode(d.toJson());
    final repo = pending;
    if (repo == null) {
      _memDraft = raw;
    } else {
      await repo.put(ConversationRepo.mainChatId, raw);
    }
  }

  Future<void> _clearDraft() async {
    final repo = pending;
    if (repo == null) {
      _memDraft = null;
    } else {
      await repo.clear(ConversationRepo.mainChatId);
      if (id != ConversationRepo.mainChatId) await repo.clear(id);
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
      _pick = (
        tool: 'complete_task',
        args: const {},
        shift: null,
        ids: [for (final t in open) t.id]
      );
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
    final n =
        RegExp(r'^(?:task )?#?(\d+)$', caseSensitive: false).firstMatch(ref);
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
    final pick =
        (tool: tool, args: args, shift: shift, ids: [for (final t in l) t.id]);
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

typedef _Pick = ({
  String tool,
  Map<String, Object?> args,
  Duration? shift,
  List<int> ids
});

/// A model reply saying it did something; only tools do things.
final _claim = RegExp(
    r"^(?:(?:ok(?:ay)?|sure|done|great)[,!.]?\s*)?(?:i(?:'ve| have|'ll| will)?\s+)?(?:set|added|created|scheduled|saved|deleted|removed|completed|marked|cancell?ed|updated|reminded|postponed)\b",
    caseSensitive: false);
