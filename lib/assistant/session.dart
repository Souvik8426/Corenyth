import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/repos.dart';
import 'engine.dart';
import 'rule_engine.dart';
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
  })  : id = conversationId ?? ConversationRepo.newChatId(),
        clock = clock ?? DateTime.now,
        _fallback = RuleEngine(clock: clock);

  void _go(SessionState n) {
    if (!_allowed[_s]!.contains(n))
      throw StateError('illegal transition $_s -> $n');
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
        final ToolCall call;
        final route = Stopwatch()..start();
        if (explicit) {
          call = ToolCall('respond', {
            'text': saved != null
                ? "Okay, I'll remember that."
                : "That's too long for me to remember; try a shorter sentence."
          });
        } else {
          final fast = _fallback.fastRoute(text);
          timing['route'] = route.elapsedMilliseconds;
          call = fast != null
              ? parseToolCall(jsonEncode(fast))
              : await _plan(text, onText, timing);
        }
        timing['route'] ??= route.elapsedMilliseconds;
        if (_cancelled) return '';
        if (call.tool != 'respond') _go(SessionState.executing);
        final exec = Stopwatch()..start();
        try {
          reply = await tools.execute(call);
        } finally {
          timing['execution'] = exec.elapsedMilliseconds;
        }
      } on ToolError catch (e) {
        if (_cancelled) return '';
        reply = e.message;
      }
      await conversations.add(id, 'assistant', reply);
      onText?.call(reply);
      _go(SessionState.speaking);
      if (!_cancelled) await speak?.call(reply);
      return reply;
    } finally {
      timing['total'] = total.elapsedMilliseconds;
      lastTiming = Map.unmodifiable(timing);
      debugPrint('turn timing ms: $lastTiming');
      if (_s != SessionState.listening) _go(SessionState.listening);
      if (!_closeRequested) _armIdle();
    }
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

  /// Deterministic context router: only fetch what the request needs.
  Future<Prompt> _prompt(String text) async {
    final t = text.toLowerCase();
    final mems = (await memory.search(text))
        .map((m) => m.content)
        .where(isUsefulPersonalMemory)
        .toList();
    final userProfile = await profile.get() ?? const UserProfile();
    final important = (await memory.important()).map((m) => m.content).toList();
    final context = buildPersonalContext(userProfile, important);
    String? tasks;
    final planning = RegExp(r'\b(plan|planning|schedule|agenda)\b').hasMatch(t);
    if (planning ||
        RegExp(r'\b(task|tasks|todo|to-do|today|tomorrow|due|task #?\d+)\b')
            .hasMatch(t)) {
      final now = clock();
      final day = DateTime(now.year, now.month,
          now.day + (RegExp(r'\btomorrow\b').hasMatch(t) ? 1 : 0));
      final end = DateTime(day.year, day.month, day.day + 1);
      final List<Task> l;
      if (planning) {
        // Day plan: overdue + that day's + undated pending tasks.
        l = (await taskRepo.list())
            .where((x) => x.dueAt == null || x.dueAt!.isBefore(end))
            .toList();
      } else if (RegExp(r'\b(today|tonight|this day|tomorrow)\b').hasMatch(t)) {
        l = await taskRepo.list(from: day, to: end);
      } else {
        l = await taskRepo.list();
      }
      tasks = l.isEmpty
          ? '(none)'
          : [
              for (final x in l.take(_taskCap))
                '$x${x.priority == 2 ? ' [high priority]' : ''}',
              if (l.length > _taskCap)
                '(partial: showing $_taskCap of ${l.length} tasks)',
            ].join('\n');
    }
    String? reminders;
    if (RegExp(r'\b(remind|reminders?|alarm)\b').hasMatch(t)) {
      final l = await tools.reminders.upcoming();
      reminders = l.isEmpty
          ? '(none)'
          : [
              for (final r in l.take(_taskCap)) '$r',
              if (l.length > _taskCap)
                '(partial: showing $_taskCap of ${l.length} reminders)',
            ].join('\n');
    }
    // history excludes the current user turn (already persisted just before).
    final hist = (await conversations.recent(id, n: 9));
    if (hist.isNotEmpty && hist.last.role == 'user') hist.removeLast();
    return Prompt(PromptKind.action, text,
        memories: mems,
        tasks: tasks,
        reminders: reminders,
        personalContext: context,
        history: hist);
  }

  static const tooLongReply =
      "That message is too long for me to handle on this device. Please try a shorter message.";

  Future<ToolCall> _plan(String text, void Function(String)? onText,
      Map<String, int> timing) async {
    if (engineInUse == engine.name && engine is! RuleEngine) {
      // Re-checks residency: the shared model may have been released since start.
      var loaded = true;
      if (loadEngine != null) {
        try {
          loaded = await loadEngine!();
        } catch (_) {
          loaded = false;
        }
      }
      if (_cancelled) throw ToolError('cancelled');
      if (loaded) {
        final ctx = Stopwatch()..start();
        final p = await _prompt(text);
        timing['context'] = ctx.elapsedMilliseconds;
        if (_cancelled) throw ToolError('cancelled');
        // No retry: decoding is greedy + grammar-constrained, so a retry repeats the same output.
        try {
          return parseToolCall(await engine.completeStreaming(p, onText: onText));
        } on PlatformException catch (e) {
          if (e.code == 'llama_cancelled' || _cancelled) {
            _cancelled = true;
            throw ToolError('cancelled');
          }
          // Never silently answer a different, truncated question.
          if (e.code == 'prompt_too_long') {
            return ToolCall('respond', {'text': tooLongReply});
          }
          lastFallbackReason = 'the local model failed (${e.code})';
        } on ToolError {
          lastFallbackReason = 'the model reply was not a valid command';
        } catch (_) {
          lastFallbackReason = 'the local model failed';
        }
        if (_cancelled) throw ToolError('cancelled');
      } else {
        lastFallbackReason = 'the local model is not loaded';
      }
    }
    return parseToolCall(jsonEncode(_fallback.plan(text)));
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
