/// Conversation-local scope policy. Uncertain requests remain available to the
/// interpreter; only clearly unrelated requests receive the scope response.
class CorePolicy {
  static const refusal =
      "That's not in my core functionality. I can help with: reminders, alarms, tasks, notes, your schedule, and facts you've saved.";
  Set<String>? _refused;
  bool repeated = false;

  /// Applied only to conversational prose, never execution receipts or lists.
  String concise(String reply, String request) {
    if (repeated ||
        RegExp(r'\b(explain|in detail|tell me more|detailed)\b',
                caseSensitive: false)
            .hasMatch(request)) return reply;
    if (reply.length <= 360) return reply;
    final prefix = reply.substring(0, 360);
    final sentence = prefix.lastIndexOf(RegExp(r'[.!?](?:\s|$)'));
    if (sentence > 0) return prefix.substring(0, sentence + 1);
    final space = prefix.lastIndexOf(' ');
    return '${prefix.substring(0, space > 0 ? space : prefix.length).trimRight()}…';
  }

  static final _core = RegExp(
      r'\b(remind|reminder|alarm|timer|task|note|schedule|calendar|remember|forget|saved|my day)\b',
      caseSensitive: false);
  static final _outside = RegExp(
      r'^(?:please\s+)?(?:explain\s+(?:this|the)\s+code|(?:write|draft)\s+(?:me\s+)?(?:an?\s+)?(?:essay|article)|brainstorm\b|ideate\b|what is\b|who is\b|how does\b)',
      caseSensitive: false);
  bool refuse(String text) {
    repeated = false;
    final normalized =
        text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    if (_core.hasMatch(text) ||
        RegExp(r'\bmy (?:name|birthday|occupation|preferences?|profile)\b',
                caseSensitive: false)
            .hasMatch(text) ||
        !_outside.hasMatch(text.trim())) {
      _refused = null;
      return false;
    }
    final words = normalized
        .split(RegExp(r'\s+'))
        .where((w) =>
            w.length > 2 &&
            !{
              'please',
              'explain',
              'this',
              'the',
              'what',
              'does',
              'how',
              'write',
              'draft'
            }.contains(w))
        .toSet();
    final prior = _refused;
    if (prior != null &&
        (prior.intersection(words).length / prior.union(words).length >= 0.6 ||
            prior.isEmpty && words.isEmpty)) {
      repeated = true;
      _refused = words;
      return false;
    }
    _refused = words;
    return true;
  }
}
