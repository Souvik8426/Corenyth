import 'package:characters/characters.dart';

/// Typed scope decision for one newly submitted nonempty user turn.
enum ScopeDecision {
  /// In-core, pending answer, arithmetic, or unrelated uncertain input.
  core,

  /// First clearly-outside request: exact refusal, zero model calls.
  refuse,

  /// Immediate repeat of the refused topic: local chat answer only.
  persistedOutside,

  /// Not clearly outside; existing interpreter retains ownership.
  uncertain,
}

/// Per-conversation outside-topic record. Process-local; restart clears it.
class CorePolicyState {
  CorePolicyState({this.lastOutsideTopic, this.lastAllowedTurnOrdinal = 0});
  Set<String>? lastOutsideTopic;
  int lastAllowedTurnOrdinal;
}

/// Conversation-owned store. Recreating a session keeps the chat's state;
/// another chat starts independently; a new process starts empty.
class CorePolicyStore {
  final _states = <String, CorePolicyState>{};

  CorePolicyState forChat(String chatId) =>
      _states.putIfAbsent(chatId, CorePolicyState.new);

  void clear() => _states.clear();
}

/// Conversation-local scope and concise-output policy.
class CorePolicy {
  static const refusal =
      "That's not in my core functionality. I can help with: reminders, alarms, tasks, notes, your schedule, and facts you've saved.";

  static const _persistPhrases = {
    'please answer anyway',
    'answer anyway',
    'just answer',
    'answer it anyway',
  };

  CorePolicy({CorePolicyStore? store, String? chatId})
      : _store = store,
        _chatId = chatId;

  final CorePolicyStore? _store;
  final String? _chatId;
  final CorePolicyState _local = CorePolicyState();
  bool repeated = false;
  ScopeDecision lastDecision = ScopeDecision.uncertain;

  CorePolicyState get _state {
    final id = _chatId;
    final store = _store;
    if (id != null && store != null) return store.forChat(id);
    return _local;
  }

  /// Applied only to conversational prose, never execution receipts or lists.
  /// Counts Unicode grapheme clusters; the ellipsis is included in the limit.
  String concise(String reply, String request) {
    if (repeated ||
        lastDecision == ScopeDecision.persistedOutside ||
        RegExp(r'\b(explain|in detail|tell me more|detailed)\b',
                caseSensitive: false)
            .hasMatch(request)) {
      return reply;
    }
    final clusters = reply.characters;
    if (clusters.length <= 360) return reply;
    final prefix = clusters.take(360).toString();
    final sentence = prefix.lastIndexOf(RegExp(r'[.!?](?:\s|$)'));
    if (sentence > 0) return prefix.substring(0, sentence + 1);
    final space = prefix.lastIndexOf(' ');
    final cut = space > 0 ? prefix.substring(0, space).trimRight() : prefix;
    // Include the ellipsis inside the 360-cluster budget.
    final body = cut.characters.take(359).toString().trimRight();
    return '$body…';
  }

  static final _core = RegExp(
      r'\b(remind|reminder|alarm|timer|task|note|schedule|calendar|remember|forget|saved|my day|overdue|pending|to-?dos?|agenda|on my plate)\b',
      caseSensitive: false);
  static final _profile = RegExp(
      r'\bmy (?:name|birthday|occupation|preferences?|profile)\b',
      caseSensitive: false);
  static final _outside = RegExp(
      r'^(?:please\s+)?(?:explain\s+(?:this|the)\s+code|(?:write|draft)\s+(?:me\s+)?(?:an?\s+)?(?:essay|article)|brainstorm\b|ideate\b|what is\b|who is\b|how does\b)',
      caseSensitive: false);

  /// Evaluate once per newly submitted nonempty user turn. Pending answers and
  /// arithmetic clear outside topic. Replaying an operation must not call this.
  ScopeDecision evaluate(String text) {
    repeated = false;
    final state = _state;
    final trimmed = text.trim();
    final normalized = _normalize(trimmed);
    final persistAsk =
        _persistPhrases.contains(normalized) && state.lastOutsideTopic != null;

    if (_core.hasMatch(text) || _profile.hasMatch(text)) {
      state.lastOutsideTopic = null;
      return lastDecision = ScopeDecision.core;
    }
    if (!_outside.hasMatch(trimmed) && !persistAsk) {
      // Uncertain / arithmetic / pending-style short answers: clear outside.
      state.lastOutsideTopic = null;
      return lastDecision = ScopeDecision.uncertain;
    }

    final words = _topicTokens(normalized);
    final prior = state.lastOutsideTopic;
    if (persistAsk || _similar(prior, words)) {
      repeated = true;
      state.lastOutsideTopic = words.isEmpty ? prior : words;
      state.lastAllowedTurnOrdinal += 1;
      return lastDecision = ScopeDecision.persistedOutside;
    }
    state.lastOutsideTopic = words;
    state.lastAllowedTurnOrdinal = 0;
    return lastDecision = ScopeDecision.refuse;
  }

  /// Compatibility wrapper used by older call sites and tests.
  bool refuse(String text) => evaluate(text) == ScopeDecision.refuse;

  /// Pending answers, arithmetic and other in-route turns clear outside topic
  /// without classifying the text as outside.
  void noteCoreTurn() {
    repeated = false;
    _state.lastOutsideTopic = null;
    lastDecision = ScopeDecision.core;
  }

  static String _normalize(String text) {
    // Preserve Unicode letters; strip only punctuation/symbols for matching.
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static Set<String> _topicTokens(String normalized) => normalized
      .split(' ')
      .where((w) =>
          w.length > 2 &&
          !const {
            'please',
            'explain',
            'this',
            'the',
            'what',
            'does',
            'how',
            'write',
            'draft',
            'anyway',
            'just',
            'answer'
          }.contains(w))
      .toSet();

  /// Never treat two empty token sets as proof of topic similarity.
  static bool _similar(Set<String>? prior, Set<String> words) {
    if (prior == null || prior.isEmpty || words.isEmpty) return false;
    return prior.intersection(words).length / prior.union(words).length >= 0.6;
  }
}
