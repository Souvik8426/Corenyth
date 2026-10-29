import '../data/repos.dart';
import 'rule_engine.dart';
import 'temporal.dart';
import 'tools.dart' show friendlyTime, fullDate;

/// Pure readers for the event lifecycle (meeting details, completion, outcome,
/// progress updates) and database-derived briefings. They only interpret
/// text; [AssistantSession] decides and the repos write.

RegExp _ci(String p) => RegExp(p, caseSensitive: false);

final _eventNoun = _ci(
    r"\b(?:meeting|meet-?up|appointment|appt|interview|stand-?up|sync|demo|"
    r'presentation|webinar|seminar|conference|consultation|check-?up|session|class|lecture|'
    r'call with|dentist|doctor|hearing|viva|exam)s?\b');

/// Titles about doing something for an event, not attending it: "arrange
/// the meeting" stays a separate errand from "meeting with Aditya".
final _errand = _ci(
    r'^(?:(?:i|we)\s+(?:need|have|must|should|got)\s+to\s+)?(?:to\s+)?'
    r'(?:arrange|schedule|set|setup|organi[sz]e|plan|prepare|prep|book|confirm|reschedule|'
    r'ask|call|phone|ring|email|text|message|remind|invite|send|follow|cancel|find|fix|review|'
    r'read|write|buy|get|print|finish|update|check(?!-)|tell|share|move|postpone|pay|draft|make)\b');

/// An appointment the user attends ("client meeting", "meet Aditya",
/// "dentist"), so it gets alerts, a details question and an outcome check.
bool isEventTitle(String title) {
  final t = title.trim();
  if (_ci(r'^meet\s+(?:with\s+)?\S').hasMatch(t)) return true;
  return _eventNoun.hasMatch(t) && !_errand.hasMatch(t);
}

/// Setting an event up (see [_errand]), e.g. "arrange meeting with Aditya".
bool isArrangement(String title) =>
    _eventNoun.hasMatch(title) && _errand.hasMatch(title.trim());

final _question = _ci(
    r'^\W*(?:how|why|what|when|where|which|who|whom|whose|should|shall|is|are|'
    r'does|do|did|can|could|would|will|if|suppose|imagine|maybe|perhaps)\b');

/// Questions and hypotheticals describe nothing that happened.
bool isQuestionLike(String text) =>
    text.contains('?') ||
    _question.hasMatch(text) ||
    _ci(r"\b(?:what if|if|suppose|might|maybe|perhaps|probably)\b")
        .hasMatch(text);

/// Words that would be data commands; such a message is never a mere update.
final _command = _ci(
    r'\b(?:remind|add|create|delete|remove|cancel|complete|mark|rename|edit|'
    r'list|show|postpone|reschedule|move|schedule|set)\b');

/// Contains a data-command verb (see [_command]).
bool hasCommandWord(String text) => _command.hasMatch(text);

final _sep = _ci(
    r"\s*(?:[,;!—–]|:(?!\d)|\.\s|\s-\s)\s*|\s+and\s+(?=(?:it|we|they|he|she|i|everything|all)\b)");
final _notRe = _ci(
    r"n't\b|\b(?:isnt|wasnt|arent|werent|hasnt|havent|didnt|not|never|no|yet)\b");
String _trimEnd(String s) => s.trim().replaceAll(RegExp(r'[\s.!,;]+$'), '');
final _doneA = _ci(
    r'^(?:the |my |our |that |this )?(.+?)\s+(?:(?:is|was|has|got|just|already)\s+)*'
    r'(?:done|over|finished|ended|wrapped up|complete|completed)(?:\s+(?:early|already|now|just now|finally))?$');
final _doneB = _ci(
    r'^(?:i |we )?(?:just |already |finally )?(?:finished|ended|wrapped up|completed|had|'
    r'attended|got out of|left) (?:the |my |our |that )?(.+)$');
final _doneC = _ci(
    r"^(?:i'?m |i am |we'?re |we are )?(?:all )?(?:done|finished) with (?:the |my |our |that )?(.+)$");

/// "The meeting with Aditya is over, it went well": the event it names and
/// the outcome already given (null = not given). Null when [text] does not
/// report an event as finished (negated, a question, or not an event).
({String ref, String? outcome})? eventDone(String text) {
  if (isQuestionLike(text)) return null;
  final t = text.trim().replaceAll('’', "'").replaceFirst(
      _ci(r'^(?:ok(?:ay)?|so|well|alright|update|fyi|btw)\b[,!.:\s]*'), '');
  final cut = _sep.firstMatch(t);
  final head = _trimEnd(cut == null ? t : t.substring(0, cut.start));
  final tail = cut == null ? '' : _trimEnd(t.substring(cut.end));
  if (RuleEngine.isNegated(head) || _notRe.hasMatch(head)) return null;
  final m = _doneA.firstMatch(head) ??
      _doneC.firstMatch(head) ??
      _doneB.firstMatch(head);
  if (m == null) return null;
  final ref = m
      .group(1)!
      .replaceFirst(
          _ci(r'\s+(?:early|already|now|just now|today|finally)$'), '')
      .trim();
  // "I had a meeting tomorrow at 3pm" plans one; it reports nothing finished.
  if (!isEventTitle(ref) || RuleEngine.hasUnsupportedDate(ref)) return null;
  return (ref: ref, outcome: tail.isEmpty ? null : tail);
}

final _endRe = _ci(
    r'\b(?:ends?|ending|until|till|til|finish(?:es)?|over|wraps? up|done|runs? (?:until|till|to))'
    r'\s+(?:at\s+|by\s+|around\s+)?(?:(\d{1,2})(?::(\d{2}))?\s*(am|pm)?|(noon))\b');
final _lastsRe = _ci(
    r'\b(?:lasts?|takes?|runs? for|for)\s+(?:about\s+|around\s+)?'
    r'(\d{1,3}|an?|one|two|three|four|five|six)\s*(hours?|hrs?|h|minutes?|mins?|m)\b');
final _subjectRe = _ci(
    r"\b(?:about|regarding|to discuss|discussing|subject(?:\s+is)?:?|topic(?:\s+is)?:?)\s+(.+)$");

/// Optional meeting details in a reply: an end ("ends at 4:30pm", "until 5",
/// "lasts an hour") resolved against [start], and/or a subject ("about the
/// budget"). [note] discloses an AM/PM choice. Null = neither was given.
({DateTime? end, String? subject, String? note})? eventDetails(
    String text, DateTime start) {
  var rest = text.replaceAll('’', "'");
  DateTime? end;
  String? note;
  final e = _endRe.firstMatch(rest);
  if (e != null) {
    final noon = e.group(4) != null;
    final h = noon ? 12 : int.parse(e.group(1)!),
        min = int.parse(e.group(2) ?? '0');
    final ap = e.group(3)?.toLowerCase();
    DateTime at(int hh) =>
        DateTime(start.year, start.month, start.day, hh, min);
    if (min < 60) {
      if (noon) {
        end = at(12);
      } else if (ap != null) {
        if (h >= 1 && h <= 12) end = at(h % 12 + (ap == 'pm' ? 12 : 0));
      } else if (h <= 23) {
        end = at(h);
        if (!end.isAfter(start) && h < 12 && at(h + 12).isAfter(start)) {
          end = at(h + 12);
          note = 'I took that as ${RuleEngine.clockText(end)}.';
        }
      }
    }
    rest = rest.replaceRange(e.start, e.end, ' ');
  }
  final d = end == null ? _lastsRe.firstMatch(rest) : null;
  if (d != null) {
    final len = RuleEngine.parseDuration('${d.group(1)} ${d.group(2)}');
    if (len != null &&
        len > Duration.zero &&
        len <= const Duration(hours: 24)) {
      end = start.add(len);
      rest = rest.replaceRange(d.start, d.end, ' ');
    }
  }
  final s = _subjectRe.firstMatch(rest)?.group(1);
  final subject = s == null
      ? null
      : _trimEnd(s.replaceFirst(_ci(r'[\s,]+(?:and|but|then)?[\s,]*$'), ''));
  final subj = subject == null || subject.isEmpty
      ? null
      : subject.length > 200
          ? subject.substring(0, 200)
          : subject;
  if (end == null && subj == null) return null;
  return (end: end, subject: subj, note: note);
}

/// "skip", "not sure": the user declines the optional details question.
bool declinesDetails(String text) =>
    _ci(r"^\W*(?:skip|no idea|not sure|dunno|i don'?t know|"
            r"doesn'?t matter|no details|never ?mind)\W*$")
        .hasMatch(text);

final _progress = _ci(
    r"\b(?:has(?:n'?t| not)|have(?:n'?t| not)|did(?:n'?t| not)|is(?:n'?t| not)|"
    r'replied|responded|answered|got back|gotten back|confirmed|agreed|declined|refused|said|says|'
    r'told me|waiting (?:on|for)|no (?:reply|response|answer|word)|busy|unavailable|out of office|'
    r"on leave|sick|cancell?ed|postponed|rescheduled|delayed|still|halfway|couldn'?t make it|missed)\b");

/// "Aditya hasn't replied": news about existing work, not a new commitment
/// and not a question. The session links it to a task or asks which one.
bool isProgressUpdate(String text) =>
    !isQuestionLike(text) &&
    !_command.hasMatch(text) &&
    _progress.hasMatch(text);

final _outcomeCue = _ci(
    r"\b(?:went|was|were|agreed|decided|discussed|said|told|wants?|asked|approved|"
    r'rejected|signed|closed|good|great|well|fine|bad|badly|okay|ok|productive|useful|awesome|'
    r"terrible|cancell?ed|postponed|moved|rescheduled|didn'?t happen|no-?show|next steps?|outcome|"
    r'got|offered|hired|passed|failed|need to|have to)\b');

/// A reply that tells how something went ("It went well, we agreed on X").
bool looksLikeOutcome(String text) =>
    !isQuestionLike(text) && _outcomeCue.hasMatch(text);

/// "…, remind me to send the deck tomorrow at 10": (outcome, request) split
/// at "remind me"; request null when there is none.
({String outcome, String? request}) splitRequest(String text) {
  final i = text.toLowerCase().indexOf('remind me');
  if (i < 0) return (outcome: text.trim(), request: null);
  return (
    outcome: _trimEnd(text
        .substring(0, i)
        .replaceFirst(_ci(r'[\s,]*(?:and|so|please|pls)?[\s,]*$'), '')),
    request: text.substring(i).trim(),
  );
}

const _keyStop = {
  'the',
  'and',
  'but',
  'not',
  'has',
  'have',
  'had',
  'hasn',
  'haven',
  'didn',
  'did',
  'isn',
  'yet',
  'still',
  'was',
  'were',
  'are',
  'been',
  'about',
  'with',
  'from',
  'that',
  'this',
  'they',
  'them',
  'she',
  'her',
  'him',
  'his',
  'our',
  'you',
  'your',
  'went',
  'well',
  'good',
  'great',
  'just',
  'now',
  'today',
  'tomorrow',
  'ends',
  'end',
  'until',
  'till',
  'its',
  'said',
  'says',
  'told',
  'replied',
  'responded',
  'answered',
  'back',
  'got',
  'gotten',
  'get',
  'confirmed',
  'agreed',
  'declined',
  'for',
  'any',
  'all',
  'too',
  'also',
  'who',
  'what',
  'when',
  'will',
  'can',
  'one',
  'out',
  'reply',
  'response',
  'word',
  'waiting',
  'busy',
  'yes',
  'okay',
  'over',
  'done',
  'finished',
  'early',
  'already',
  'some',
  'very',
  'really',
  'there',
  'their',
  'then',
  'than',
  'into',
  'onto',
  'need',
};

/// Content words used to tell which task a message names (stemmed, >= 3
/// letters, without filler and update vocabulary).
Set<String> keyWords(String s) => {
      for (final w in normTitle(s).split(' '))
        if (w.length >= 3 && !_keyStop.contains(w)) RuleEngine.stem(w)
    };

/// Tasks from [candidates] whose title or subject shares a [keyWords] word
/// with [text]. Several = ask which; never a similarity guess.
List<Task> named(Iterable<Task> candidates, String text) {
  final k = keyWords(text);
  if (k.isEmpty) return [];
  final matches = [
    for (final t in candidates)
      (
        task: t,
        score: keyWords('${t.title} ${t.subject ?? ''}').intersection(k).length
      )
  ];
  var best = 0;
  for (final match in matches) {
    if (match.score > best) best = match.score;
  }
  return [
    for (final match in matches)
      if (best > 0 && match.score == best) match.task
  ];
}

/// "remind me 15 minutes before …", "half an hour before": a one-item
/// early-alert offset that never touches the saved preferences, as the
/// shared resolver reads it. [text] is returned without it.
({int minutes, String text})? leadOverride(String text, DateTime now) {
  if (!_ci(r'\bremind\b').hasMatch(text)) return null;
  final r = Temporal.read(text, now);
  final s = r.spans
      .where((s) => s.relation == TemporalRelation.before && s.amount != null)
      .firstOrNull;
  final d = s?.amount;
  if (s == null || d == null || d.inMinutes < 1 || d.inMinutes > 1440) {
    return null;
  }
  final i = text.indexOf(s.text);
  if (i < 0) return null;
  final rest = text
      .replaceRange(i, i + s.text.length, ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'[\s,.!]+$'), '')
      .trim();
  return (minutes: d.inMinutes, text: rest);
}

final _briefRe = _ci(
    r"\b(?:brief(?:ing)?|rundown|run-down|overview|my day|today'?s plan|plan for today|"
    r'day look like|agenda for today)\b');

/// "Brief me", "what does my day look like".
bool isBriefingRequest(String text) =>
    _briefRe.hasMatch(text) &&
    !_otherDay.hasMatch(text) &&
    !_command.hasMatch(text) &&
    !RuleEngine.isNegated(text);

/// A briefing covers today; "a rundown of tomorrow" is a list of that day.
final _otherDay = _ci(r'\b(?:tomorrow|tmrw|tmrow|tmr|tomo|2moro)\b');

String _line(Task t, DateTime now) => '#${t.id} ${t.title}'
    '${t.dueAt == null ? '' : ' (${friendlyTime(t.dueAt!, now)})'}'
    '${t.dailyMinute == null ? '' : ', daily'}'
    '${t.deadlineAt == null ? '' : ', until ${fullDate(t.deadlineAt!)}'}';

List<String> _capped(List<Task> l, DateTime now, [int cap = 5]) => [
      for (final t in l.take(cap)) _line(t, now),
      if (l.length > cap) '(and ${l.length - cap} more)',
    ];

/// Overdue / today / coming up / undated pending work and the next alert,
/// all from current rows (never from chat history).
String briefingText(List<Task> pending, List<Reminder> upcoming, DateTime now) {
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  final overdue = [
    for (final t in pending)
      if (t.dueAt != null && t.dueAt!.isBefore(now)) t
  ];
  final today = [
    for (final t in pending)
      if (t.dueAt != null &&
          !t.dueAt!.isBefore(now) &&
          t.dueAt!.isBefore(tomorrow))
        t
  ];
  final later = [
    for (final t in pending)
      if (t.dueAt != null && !t.dueAt!.isBefore(tomorrow)) t
  ];
  final undated = [
    for (final t in pending)
      if (t.dueAt == null) t
  ];
  final next = ([
    for (final r in upcoming)
      if (r.enabled && r.triggerAt.isAfter(now)) r
  ]..sort((a, b) => a.triggerAt.compareTo(b.triggerAt)))
      .firstOrNull;
  if (pending.isEmpty) return "You're all clear: nothing pending.";
  return [
    if (overdue.isNotEmpty) ...['Overdue:', ..._capped(overdue, now, 10)],
    if (today.isNotEmpty) ...['Today:', ..._capped(today, now, 10)],
    if (later.isNotEmpty) ...['Coming up:', ..._capped(later, now)],
    if (undated.isNotEmpty) ...['No date yet:', ..._capped(undated, now)],
    if (next != null)
      'Next alert: ${next.title}, ${friendlyTime(next.triggerAt, now)}'
          '${switch (next.kind) {
        'pre' => ' (early alert)',
        'follow_up' => ' (check-in)',
        _ => ''
      }}.',
  ].join('\n');
}

/// Factual evening review text for T4's delivery (works with the app
/// closed; no model). [ignored] = [ReviewRepo.ignoredCounts]. It moves
/// nothing and creates no alert.
String reviewText(ReviewAgenda a, DateTime now,
    {Map<int, int> ignored = const {}}) {
  if (a.unresolved.isEmpty && a.finished.isEmpty && a.tomorrow.isEmpty) {
    return "How was your day? Anything important you'd like to remember, and what's the plan for tomorrow?";
  }
  String outcome(Task t) {
    final o = t.outcome;
    if (o == null) return t.title;
    return '${t.title} (${o.length > 60 ? '${o.substring(0, 60)}…' : o})';
  }

  final outstanding = [
    for (final t in a.unresolved)
      if (t.dueAt == null || !t.dueAt!.isAfter(now)) t
  ];
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  final later = [
    for (final t in a.unresolved)
      if (t.dueAt != null &&
          t.dueAt!.isAfter(now) &&
          t.dueAt!.isBefore(tomorrow))
        t
  ];

  return [
    'How was your day?',
    if (a.finished.isNotEmpty)
      'Done today: ${a.finished.take(10).map(outcome).join('; ')}.',
    if (a.finished.length > 10)
      '(and ${a.finished.length - 10} more completed)',
    if (outstanding.isNotEmpty) ...[
      'Still open:',
      for (final t in outstanding.take(10))
        '${_line(t, now)}${(ignored[t.id] ?? 0) > 0 ? ' (still open since an earlier check-in)' : ''}',
      if (outstanding.length > 10) '(and ${outstanding.length - 10} more)',
    ],
    if (later.isNotEmpty) ...['Later today:', ..._capped(later, now, 10)],
    if (a.tomorrow.isNotEmpty) ...[
      'Tomorrow:',
      ..._capped(a.tomorrow, now, 10)
    ],
    if (outstanding.isNotEmpty)
      "How did these go? Tell me what's done or what should move, and I'll update it.",
    for (final t in a.finished.take(10))
      if (isEventTitle(t.title) && (t.outcome?.trim().isEmpty ?? true))
        'How did ${t.title} go? Anything important to remind you about later?',
    'Anything else from today worth remembering? What is the plan for tomorrow?',
  ].join('\n');
}

final _actionClaim = _ci(
    r"\b(?:i|we)(?:'ll| will)\s+(?:check|follow up|remind|notify|schedule|book|call|send)\b|"
    r"\bi(?:'ve| have|'ll| will| just| already)?\s+(?:already\s+|just\s+|now\s+|also\s+)?"
    r'(?:set|added|created|scheduled|saved|deleted|removed|completed|marked|cancell?ed|updated|'
    r'reminded|postponed|moved|rescheduled|sent|messaged|emailed|texted|called|contacted|told|'
    r'notified|booked|noted)\b|\b(?:reminders?|alerts?|alarms?|tasks?)\s+(?:is|are|has been|have been|was|were)\s+'
    r'(?:set|added|created|scheduled|saved|moved|updated|cancell?ed)\b');

/// The verbs whose appearance (in the contexts [_actionClaim] matches) turns a
/// reply into an action claim. Shared source for the claim regex above and the
/// streaming gate's holdback: a trailing word that could still grow into one
/// of these verbs is undecidable until the word completes.
const actionClaimVerbs = [
  // direct perfective/committed claims
  'set', 'added', 'created', 'scheduled', 'saved', 'deleted', 'removed',
  'completed', 'marked', 'canceled', 'cancelled', 'updated', 'reminded',
  'postponed', 'moved', 'rescheduled', 'sent', 'messaged', 'emailed',
  'texted', 'called', 'contacted', 'told', 'notified', 'booked', 'noted',
  // futures ("I'll check…") and passive rows ("tasks were set…")
  'check', 'follow', 'remind', 'notify', 'schedule',
];

final _claimVerbPrefixes = () {
  final prefixes = <String>{};
  for (final verb in actionClaimVerbs) {
    for (var i = 1; i < verb.length; i++) {
      prefixes.add(verb.substring(0, i));
    }
  }
  return prefixes;
}();

final _trailingWord = RegExp(r"[A-Za-z0-9']+$");

/// The length of [text]'s trailing suffix that cannot be judged yet by the
/// reply checks ([safeReply] and friends): a number whose digits may still be
/// arriving (a partial `1` is not yet the grounded `12`), or a word that
/// could still complete into an action-claim verb (`crea` → `created`).
/// Streaming gates hold this suffix and revalidate as new output arrives;
/// once a word or number completes, the normal checks decide as before.
int undecidableSuffixLength(String text) {
  final m = _trailingWord.firstMatch(text);
  if (m == null) return 0;
  final word = m.group(0)!;
  if (word.contains(RegExp(r'\d'))) return word.length;
  if (_claimVerbPrefixes.contains(word.toLowerCase())) return word.length;
  return 0;
}

/// A model reply that may be shown: short prose, claims no action, and
/// every number in it occurs in [grounding] (the facts and the message).
bool safeReply(String reply, String grounding) {
  final t = reply.trim();
  if (t.isEmpty || t.length > 400 || t.contains('<|') || t.contains('{'))
    return false;
  if (_actionClaim.hasMatch(t)) return false;
  final known = {
    for (final m in RegExp(r'\d+').allMatches(grounding)) m.group(0)!
  };
  return RegExp(r'\d+').allMatches(t).every((m) => known.contains(m.group(0)));
}

final _whenWord = _ci(
    r'\b(?:today|tonight|tomorrow|tmrw|yesterday|morning|afternoon|evening|noon|midnight|'
    r'week|weekend|month|monday|tuesday|wednesday|thursday|friday|saturday|sunday|'
    r'[ap]\.?m\.?|o.?clock|minutes?|mins?|hours?|hrs?|time)\b');

/// The model's follow-up after the app's own confirmation (plan `reply`):
/// prose that adds warmth or a question, never a fact. The confirmation
/// already states the exact time, so any number or time word here could
/// only contradict it; claims of acting are the app's to make.
bool isSafeFollowUp(String line, String user) {
  final t = line.trim();
  if (t.length < 2 || t.length > 200) return false;
  if (!safeReply(t, '') || _whenWord.hasMatch(t)) return false;
  return !echoes(t, user);
}

List<String> _plainWords(String s) => s
    .toLowerCase()
    .replaceAll('’', "'")
    .split(RegExp(r"[^a-z0-9']+"))
    .where((w) => w.isNotEmpty)
    .toList();

/// A model reply that parrots the user's message back (a known small-model
/// failure): five or more of the user's words in a row, or a reply made
/// almost only of the user's own words.
bool echoes(String reply, String user) {
  final r = _plainWords(reply), u = _plainWords(user);
  if (r.isEmpty || u.isEmpty) return false;
  final grams = <String>{
    for (var i = 0; i + 5 <= u.length; i++) u.sublist(i, i + 5).join(' ')
  };
  for (var i = 0; i + 5 <= r.length; i++) {
    if (grams.contains(r.sublist(i, i + 5).join(' '))) return true;
  }
  final content = r.where((w) => w.length >= 3).toList();
  if (content.length < 3) return false;
  final said = u.toSet();
  return content.where(said.contains).length * 10 >= content.length * 7;
}

final _complaint = _ci(
    r"\b(?:that|this|you|u|ur|your (?:reply|answer|response))\s*(?:was|were|is|are|'s|r)\s+"
    r"(?:so\s+|really\s+|very\s+)?(?:dumb|stupid|useless|unhelpful|nonsense|not helpful)\b|"
    r"\b(?:just\s+)?(?:repeated|copied|echoed|replied|said)\s+(?:back\s+)?(?:what|whatever)\s+(?:i|me)\s+"
    r"(?:said|says|typed|wrote|prompted|asked|sent)\b|"
    r"\b(?:proper|real|actual|better)\s+(?:reply|answer|response)\b|"
    r"\b(?:answer|reply to|respond to)\s+(?:my\s+)?(?:previous|last|earlier)\s+(?:prompt|message|question|msg)\b|"
    r"\b(?:you|u)\s+(?:didn'?t|did not|never)\s+(?:answer|reply|respond|get it|understand)\b|"
    r"\bnot what i (?:asked|said|meant)\b");

/// The user says the assistant's last reply missed ("that was dumb, give a
/// proper reply"); such a turn re-answers their earlier message.
bool isComplaint(String text) => _complaint.hasMatch(text);
