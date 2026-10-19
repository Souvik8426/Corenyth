/// Whether a message authorizes an action, read by the app (never taken
/// from a model's confidence). One reader for every route and interpreter:
///
/// - request: asks the assistant to act, including polite questions
///   ("Can you remind me…?", "Could u add milk?") and time-first or trailing
///   "…, remind me" forms.
/// - statement: tells a plan, fact or report ("I have a meeting at 3", "the
///   meeting is over", "Aditya hasn't replied", a bare "5pm" or "#3").
/// - question: asks for information only ("How do reminders work?", "Has
///   Aditya replied?", "Can reminders repeat?").
/// - hypothetical: supposes or is undecided ("What if…", "Maybe I should…",
///   "Should I remind myself…?").
/// - negated: tells the assistant not to act ("Don't remind me…", "I don't
///   want a reminder").
///
/// A question mark alone never decides: "tomorrow?" answering a time
/// question is a statement, and a polite request ending in "?" is a request.
library;

enum Authorization { request, statement, question, hypothetical, negated }

class AuthorizationReading {
  final Authorization kind;

  /// The words that decided it (diagnostics code material; no raw text is
  /// logged, only [kind]).
  final String cue;
  const AuthorizationReading(this.kind, this.cue);

  /// Creates and changes (tasks, reminders, completion, deletion, moves).
  bool get permitsWrite =>
      kind == Authorization.request || kind == Authorization.statement;

  /// Reports about existing work (outcomes, meeting details, progress,
  /// personal facts): their content may contain a negation ("it didn't go
  /// well"), but questions and suppositions report nothing.
  bool get permitsReport =>
      kind != Authorization.question && kind != Authorization.hypothetical;

  @override
  String toString() => kind.name;
}

RegExp _ci(String p) => RegExp(p, caseSensitive: false);

const _actionVerb =
    r'(?:remind|add|create|set|make|schedule|put|mark|complete|finish|delete|'
    r'remove|cancel|move|postpone|push|delay|rename|change|edit|note|save|'
    r'remember|list|show|tell|give|alert|notify|book|log|track|ping|nudge|'
    r'brief|update|reschedule)';

final _lead = _ci(
    r"^(?:(?:ok(?:ay)?|so|well|alright|yes|yeah|yep|nope|hey|hi|hello|hiya|btw|oh)\b[\s,!.]+)+");

final _negatedRequest = _ci(
    r"(?:^|\b)(?:please\s+)?(?:don'?t|dont|do not|never|no need to|stop|quit)\s+"
    r"(?:\w+\s+){0,2}?(?:remind|add|create|set|schedule|save|alert|notify|mark|"
    r"complete|delete|remove|cancel|move|postpone|ping|bother|nudge|book)\w*\b|"
    r"\bi (?:don'?t|do not|no longer) (?:want|need) (?:a |an |any |the |to )?"
    r"(?:reminders?|alarms?|alerts?|tasks?|notifications?|nudges?|remind|be reminded)\b|"
    r"\b(?:you )?(?:don'?t|do not) (?:have|need) to (?:remind|add|set|save)\b");

final _hypothetical = _ci(
    r"^(?:what if|what about if|suppose|supposing|imagine|if|in case|assuming)\b|"
    r"\b(?:maybe|perhaps|might|possibly|probably)\b|"
    r"^(?:should|shall|would) (?:i|we)\b|"
    r"\b(?:thinking (?:about|of)|wondering|not sure (?:if|whether)|undecided)\b|"
    r"^i (?:may|could|might)\b");

/// "Can you remind me…", "could u please add…", "would you mind setting…".
final _polite = _ci(
    r"^(?:please\s+)?(?:can|could|would|will|wud|cud|cn)\s*(?:you|u|ya)\b"
    r"(?:\s+(?:please|pls|plz|kindly|just|also|quickly))*\s+(?:mind\s+)?"
    "(?:help me\\s+)?$_actionVerb|"
    r"^(?:can|could|may) i (?:get|have|set) (?:a|an|one) (?:reminder|alarm|alert|task|timer)\b");

/// A polite form that only asks to be told something ("can you tell me how…").
final _politeInfo = _ci(
    r"^(?:please\s+)?(?:can|could|would|will)\s*(?:you|u)\s+(?:please\s+)?"
    r"(?:tell|show|explain)(?: me)?\s+(?:how|what|why|when|whether|if|which)\b");

final _interrogative = _ci(
    r"^(?:how|why|what|when|where|which|who|whom|whose|is|are|am|was|were|do|"
    r"does|did|has|have|had|can|could|would|will|should|shall|may|isn'?t|"
    r"aren'?t|doesn'?t|don'?t you|didn'?t|hasn'?t|haven'?t|won'?t|explain)\b");

final _imperative =
    _ci('^(?:please\\s+|pls\\s+|plz\\s+|kindly\\s+)?$_actionVerb\\b');
final _remindMe =
    _ci(r'\bremind me\b|\bset (?:an? )?(?:alarm|reminder|timer)\b');

/// Reads [text]'s authorization (see the library comment).
AuthorizationReading readAuthorization(String text) {
  var t = text.replaceAll('’', "'").trim();
  t = t.replaceFirst(_lead, '').trim();
  if (t.isEmpty) return const AuthorizationReading(Authorization.statement, '');
  final neg = _negatedRequest.firstMatch(t);
  if (neg != null) {
    return AuthorizationReading(Authorization.negated, neg.group(0)!.trim());
  }
  final hypo = _hypothetical.firstMatch(t);
  if (hypo != null) {
    return AuthorizationReading(
        Authorization.hypothetical, hypo.group(0)!.trim());
  }
  if (_politeInfo.hasMatch(t)) {
    return const AuthorizationReading(Authorization.question, 'tell me how');
  }
  final polite = _polite.firstMatch(t);
  if (polite != null) {
    return AuthorizationReading(Authorization.request, polite.group(0)!.trim());
  }
  final q = _interrogative.firstMatch(t);
  if (q != null) {
    return AuthorizationReading(Authorization.question, q.group(0)!.trim());
  }
  if (_imperative.hasMatch(t) || _remindMe.hasMatch(t)) {
    return const AuthorizationReading(Authorization.request, 'imperative');
  }
  return const AuthorizationReading(Authorization.statement, '');
}
