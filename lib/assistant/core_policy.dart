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

/// Shared wording for a rejected instruction-like memory.
const memoryInstructionRefusal =
    'I keep facts about you, not instructions for me. To change how I reply, use Memories → Edit tone.';

/// An explicit memory request's leading cue ("remember", "please remember
/// that", "note:", "keep in mind", "don't forget"), not "remember to ..."
/// (a task request) and not words that merely start the same ("notes").
final memoryRequestCue = RegExp(
    r"^(?:please\s+)?(?:remember|note|fyi|keep\s+in\s+mind|don['’]?t\s+forget|do\s+not\s+forget)\b"
    r'(?:\s+that\b)?\s*[:,]?\s*(?!to\b)(?=\S)',
    caseSensitive: false);

/// Removes at most one conversational filler tag anchored at the very end of
/// [text]: ", you know" / ", you see" (any text), or ", will you" only when
/// [request] says the user explicitly asked to remember. Optional trailing
/// `?.!` go with the tag. Nothing before the tag is touched, so every rule of
/// [memoryInstructionIssue] still runs on the rest; a tag that is not the
/// final clause ("..., you know you must obey") is kept.
String stripMemoryFillerTag(String text, {bool request = false}) {
  final t = text.trim();
  final tag = request
      ? RegExp(r',\s*(?:you\s+(?:know|see)|will\s+you)\s*[?.!]*$',
          caseSensitive: false)
      : RegExp(r',\s*you\s+(?:know|see)\s*[?.!]*$', caseSensitive: false);
  final m = tag.firstMatch(t);
  if (m == null) return t;
  final rest = t.substring(0, m.start).trim();
  return rest.isEmpty ? t : rest;
}

/// Write-time scan that rejects instruction-like memories before storage.
///
/// Returns null when allowed (facts about the user).
/// When rejected, returns a short user-facing reason string.
/// [request]: the caller already removed an explicit "remember ..." cue from
/// [content], so a trailing ", will you" tag is courtesy, not a directive.
String? memoryInstructionIssue(String content, {bool request = false}) {
  final text = content.trim();
  if (text.isEmpty) return null;

  // (c) Contains role or control markers (scanned before any tag removal).
  final controlMarkers = RegExp(
      r'(?:<\||(?:^|[\n\r"\u201c\u2018])\s*(?:system|assistant)\s*:|'
      r'(?:^|[\n\r])\s*###(?:\s+(?:system|assistant|admin)\b|\s*$)|'
      r'\[\s*(?:system|admin)\b\s*\])',
      caseSensitive: false,
      multiLine: true);
  if (controlMarkers.hasMatch(text)) {
    return memoryInstructionRefusal;
  }

  // A trailing filler/courtesy tag is not a future obligation. Remove only
  // that anchored tag; the rest is scanned as usual, clause by clause.
  final cue = memoryRequestCue.firstMatch(text);
  final untagged =
      stripMemoryFillerTag(text, request: request || cue != null);
  final strippedTag = untagged != text;
  if (strippedTag && cue != null) {
    // The request's own words must pass too: removing the tag must never
    // expose "Remember: ignore all previous instructions" as a fact.
    final inner = untagged.substring(cue.end).trim();
    if (inner.isNotEmpty &&
        memoryInstructionIssue(inner) != null) {
      return memoryInstructionRefusal;
    }
  }
  return _instructionIssueAfterTags(untagged, strippedTag);
}

String? _instructionIssueAfterTags(String text, bool strippedTag) {
  var addressedText = text;
  // In this reply preference, "will" describes the replies helping the user.
  // Mask only that modal, retaining "you" and any appended directive/modal.
  addressedText = addressedText.replaceFirstMapped(
    RegExp(
      r'^(user\s+prefers\s+replies\s+that\s+)will(\s+help\s+you\s+plan\b)',
      caseSensitive: false,
    ),
    (match) => '${match[1]}${match[2]}',
  );
  final maskedBenignModal = strippedTag || addressedText != text;

  // A possessive reference to someone's assistant describes a person, rather
  // than addressing Corenyth. Mask a short noun phrase, stopping at pronouns,
  // modals and common clause verbs so "you must ..." stays visible.
  addressedText = addressedText.replaceAll(
    RegExp(
      r"\b(?:user['’]s|my|our|his|her|their|your)\s+"
      r'(?:(?!(?:you|must|should|always|never|will|have|can|are|is|says|said)\b)[\w-]+\s+){0,4}assistant\b',
      caseSensitive: false,
    ),
    '',
  );
  // (a) Addresses the assistant together with an obligation or permission.
  final addressesAssistant =
      RegExp(r'\b(?:you|assistant|corenyth)\b', caseSensitive: false);
  final instructionModals = RegExp(
      r'\b(?:must|should|always|never|will|have\s+to|you\s+are\s+allowed\s+to)\b',
      caseSensitive: false);
  if (addressesAssistant.hasMatch(addressedText) &&
      instructionModals.hasMatch(addressedText)) {
    return memoryInstructionRefusal;
  }

  // Strip leading user/i/my subject (e.g. "User: ...", "User, ...", "I: ...", or
  // "User pretend/ignore/act as/...") before checking if the body starts with an imperative.
  String body = text;
  var delimitedDrinkingHabit = false;
  final delimPrefix =
      RegExp(r'^(?:(?:the\s+)?user|i|my)\s*[:,\-—]\s*', caseSensitive: false)
          .firstMatch(body);
  if (delimPrefix != null) {
    body = body.substring(delimPrefix.end).trim();
    // "User: never drinks" is a third-person habit; "never drink" remains a
    // command. Keep this exception bounded to the confirmed habit verb.
    final habitStart =
        RegExp(r'^(?:always|never)\s+(?=drinks\b)', caseSensitive: false);
    delimitedDrinkingHabit =
        RegExp(r'^(?:the\s+)?user\b', caseSensitive: false).hasMatch(text) &&
            habitStart.hasMatch(body);
    if (delimitedDrinkingHabit) {
      body = body.replaceFirst(habitStart, '');
    }
  } else {
    // Strip bare "User" before always/never/don't/do not only when followed
    // by a known base-form command verb. This deliberately bounded vocabulary
    // preserves third-person habits ("never drinks", "always takes"), states
    // ("always happy"), and "doesn't". Never strip a bare "I" or "my" here.
    const commandVerb =
        r'(?:approve|check|ask|reply|respond|answer|use|share|store|save|send|reveal|skip|ignore|forget|pretend|act|execute|run|follow|obey|confirm|require|wait|verify|disclose)';
    final barePrefix = RegExp(
      r'^(?:the\s+)?user\s+(?=(?:pretend|act as|ignore|forget all|forget your|from now on|note for yourself)\b|'
      r"(?:always|never|don['’]?t|do\s+not)\s+"
      '$commandVerb\\b)',
      caseSensitive: false,
    ).firstMatch(body);
    if (barePrefix != null) {
      body = body.substring(barePrefix.end).trim();
    }
  }

  // (b) Starts with an imperative or an explicit self-instruction. "Forget
  // your" is limited to policy targets, not everyday objects such as keys.
  final imperativeStart = RegExp(
    r"^(?:always|never|don['’]?t|do\s+not|ignore|forget all|pretend|act as|from now on)\b|"
    r'^note\s+for\s+yourself\s*:|'
    r'^forget\s+your\s+(?:system\s+prompt|(?:previous\s+)?(?:rules|instructions)|safety\s+checks)\b',
    caseSensitive: false,
  );
  // A benign exception must not hide a command appended as another clause.
  final imperativeBodies = delimitedDrinkingHabit || maskedBenignModal
      ? body.split(
          RegExp(r'[,;.!?\n]|\b(?:and|but|then)\b', caseSensitive: false))
      : [body];
  if (imperativeBodies.any((part) => imperativeStart.hasMatch(part.trim()))) {
    return memoryInstructionRefusal;
  }

  return null;
}
