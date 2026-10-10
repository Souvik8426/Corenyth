import 'dart:async';

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
  SessionState.initializing: {SessionState.listening, SessionState.shuttingDown},
  SessionState.listening: {
    SessionState.transcribing, SessionState.processing, SessionState.shuttingDown
  },
  SessionState.transcribing: {
    SessionState.processing, SessionState.listening, SessionState.shuttingDown
  },
  SessionState.processing: {
    SessionState.executing, SessionState.speaking, SessionState.listening,
    SessionState.shuttingDown
  },
  SessionState.executing: {
    SessionState.speaking, SessionState.listening, SessionState.shuttingDown
  },
  SessionState.speaking: {SessionState.listening, SessionState.shuttingDown},
  SessionState.shuttingDown: {SessionState.idle},
};

/// One conversation = one session. Heavy resources (LLM; later ASR/TTS) live
/// only between [start] and [close]. All inference/action flow goes through
/// the explicit state machine above.
class AssistantSession {
  final LlmEngine engine;
  final RuleEngine _fallback;
  final ToolExecutor tools;
  final MemoryRepo memory;
  final TaskRepo taskRepo;
  final ConversationRepo conversations;
  final Duration idleTimeout;
  final void Function()? onIdleTimeout;

  /// TTS extension point: called in SPEAKING state; await playback completion.
  final Future<void> Function(String text)? speak;

  final String id = DateTime.now().microsecondsSinceEpoch.toString();
  final state = StreamController<SessionState>.broadcast();
  SessionState _s = SessionState.idle;
  SessionState get current => _s;
  Timer? _idle;
  String engineInUse = '';

  AssistantSession({
    required this.engine,
    required this.tools,
    required this.memory,
    required this.taskRepo,
    required this.conversations,
    DateTime Function()? clock,
    this.idleTimeout = const Duration(seconds: 60),
    this.onIdleTimeout,
    this.speak,
  }) : _fallback = RuleEngine(clock: clock);

  void _go(SessionState n) {
    if (!_allowed[_s]!.contains(n)) throw StateError('illegal transition $_s -> $n');
    _s = n;
    state.add(n);
  }

  Future<void> start() async {
    _go(SessionState.initializing);
    // ponytail: load is awaited here; start it concurrently with mic/ASR once those exist.
    engineInUse = (await engine.load()) ? engine.name : _fallback.name;
    _go(SessionState.listening);
    _armIdle();
  }

  void _armIdle() {
    _idle?.cancel();
    _idle = Timer(idleTimeout, () => onIdleTimeout?.call());
  }

  /// Handles one finalized utterance (typed now, ASR transcript later).
  Future<String> handle(String text) async {
    text = text.trim();
    if (text.isEmpty) return '';
    _idle?.cancel();
    _go(SessionState.processing);
    String reply;
    try {
      await conversations.add(id, 'user', text);
      final call = await _plan(text);
      if (call.tool != 'respond') _go(SessionState.executing);
      try {
        reply = await tools.execute(call);
      } on ToolError catch (e) {
        reply = e.message;
      }
      await conversations.add(id, 'assistant', reply);
      _go(SessionState.speaking);
      await speak?.call(reply);
    } finally {
      if (_s != SessionState.shuttingDown) {
        _go(SessionState.listening);
        _armIdle();
      }
    }
    return reply;
  }

  /// Deterministic context router: only fetch what the request needs.
  Future<Prompt> _prompt(String text) async {
    final t = text.toLowerCase();
    final mems = (await memory.search(text)).map((m) => m.content).toList();
    String? tasks;
    if (RegExp(r'\b(task|tasks|todo|to-do|today|tomorrow|due|task #?\d+)\b').hasMatch(t)) {
      final l = await taskRepo.list();
      tasks = l.isEmpty ? '(none)' : l.take(10).join('\n');
    }
    // history excludes the current user turn (already persisted just before).
    final hist = (await conversations.recent(id, n: 9));
    if (hist.isNotEmpty && hist.last.role == 'user') hist.removeLast();
    return Prompt(PromptKind.action, text, memories: mems, tasks: tasks, history: hist);
  }

  Future<ToolCall> _plan(String text) async {
    final p = await _prompt(text);
    if (engineInUse == engine.name && engine != _fallback) {
      // No retry: decoding is greedy + grammar-constrained, so a retry repeats the same output.
      try {
        return parseToolCall(await engine.complete(p));
      } catch (_) {
        // invalid output (never executed) or native failure -> rules
      }
    }
    return parseToolCall(await _fallback.complete(p));
  }

  /// Ends the session: extracts memories from the user's turns, then frees
  /// the model. Safe to call from any state; idempotent.
  Future<List<String>> close() async {
    if (_s == SessionState.idle || _s == SessionState.shuttingDown) return [];
    _idle?.cancel();
    // A close during an in-flight handle() is rare in text mode; wait for listening.
    _go(SessionState.shuttingDown);
    final saved = <String>[];
    try {
      final users = (await conversations.recent(id, n: 30)).where((m) => m.role == 'user');
      for (final m in users.take(10)) {
        final mem = await _extract(m.content);
        if (mem != null) saved.add(mem);
      }
    } finally {
      await engine.unload();
      _go(SessionState.idle);
    }
    return saved;
  }

  Future<String?> _extract(String text) async {
    final p = Prompt(PromptKind.memory, text);
    for (final e in [if (engineInUse == engine.name) engine, _fallback]) {
      try {
        final j = extractJsonObject(await e.complete(p));
        if (j['remember'] != true) return null;
        final m = j['memory'];
        if (m is! String || m.trim().isEmpty || m.length > 300) return null;
        final cat = j['category'];
        await memory.add(m,
            category: cat is String && cat.length < 20 ? cat : 'fact');
        return m;
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}
