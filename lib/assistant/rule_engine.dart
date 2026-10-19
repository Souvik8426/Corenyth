import 'dart:convert';

import '../data/repos.dart' show normTitle;
import 'calculator.dart';
import 'engine.dart';
import 'temporal.dart';
import 'tools.dart' show friendlyTime;

/// A create request still missing a usable time, persisted per chat as JSON
/// (PendingRepo) until answered, cancelled or replaced.
class ClarifyDraft {
  final String tool; // create_reminder | create_task
  final String title;
  final bool? multiple;
  final bool? followUp;

  /// Explicit clock time the user gave ("8:10 AM") whose day still needs
  /// asking; a day-only reply ("tomorrow") is combined with it.
  final String? time;
  const ClarifyDraft(
      {required this.tool,
      required this.title,
      this.multiple,
      this.followUp,
      this.time});

  String get prompt {
    final flags = [
      if (time != null) 'at $time',
      if (multiple != null) multiple! ? 'multiple alerts' : 'one alert',
      if (followUp != null) followUp! ? 'follow-up' : 'no follow-up',
    ];
    final what = tool == 'create_reminder'
        ? 'remind you about "$title"'
        : 'schedule "$title"';
    return 'When should I $what${flags.isEmpty ? '' : ' (${flags.join(', ')})'}?';
  }

  Map<String, Object?> toJson() => {
        'tool': tool,
        'title': title,
        if (multiple != null) 'multiple': multiple,
        if (followUp != null) 'follow_up': followUp,
        if (time != null) 'time': time,
      };

  /// Null for anything that isn't a well-typed draft (old/corrupt rows).
  static ClarifyDraft? fromJson(Map<String, Object?> j) {
    final tool = j['tool'], title = j['title'];
    final m = j['multiple'], f = j['follow_up'], t = j['time'];
    if ((tool != 'create_task' && tool != 'create_reminder') ||
        title is! String ||
        title.trim().isEmpty ||
        (m != null && m is! bool) ||
        (f != null && f is! bool) ||
        (t != null &&
            (t is! String ||
                !RegExp(r'^\d{1,2}(?::\d{2})? [AP]M$').hasMatch(t)))) {
      return null;
    }
    return ClarifyDraft(
        tool: tool as String,
        title: title,
        multiple: m as bool?,
        followUp: f as bool?,
        time: t as String?);
  }
}

/// A repeating time of day from [RuleEngine.parseDaily], all local time.
class DailySchedule {
  final int hour, minute;

  /// First occurrence: today, or tomorrow once today's time has passed.
  final DateTime first;

  /// Last occurrence (inclusive), at [hour]:[minute] on the end date; null =
  /// until the task is done.
  final DateTime? until;

  /// The text with the schedule words removed (title candidate).
  final String rest;

  /// Disclosure of a default used (e.g. "I took that as 7 PM."), or null.
  final String? note;
  const DailySchedule(
      {required this.hour,
      required this.minute,
      required this.first,
      this.until,
      this.rest = '',
      this.note});
}

/// A create request parsed from plain language; [at] null = no time given.
typedef Create = ({
  String tool,
  String title,
  DateTime? at,
  String? note,
  bool? multiple,
  bool? followUp,
  bool unsupported,
  bool multi,

  /// What the shared resolver read (roles, spans, conflicts).
  TemporalReading reading,
});

/// Deterministic offline "model": regex intent parsing that emits the same JSON
/// the LLM is asked to emit, so everything downstream (validation, execution)
/// is identical. Used as the text-first core and as fallback when the LLM
/// output is malformed or unavailable.
class RuleEngine extends LlmEngine {
  final DateTime Function() clock;
  RuleEngine({DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  @override
  String get name => 'rules';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}

  @override
  Future<String> complete(Prompt p) async => jsonEncode(
      p.kind == PromptKind.memory ? extractMemory(p.user) : plan(p.user));

  static Map<String, Object?> _tool(String t, Map<String, Object?> a) =>
      {'type': 'tool', 'tool': t, 'arguments': a};
  static Map<String, Object?> _say(String s) => {'type': 'respond', 'text': s};

  static const supportedWhen =
      'I understand today, tomorrow, tonight, weekdays like Monday, dates like '
      '5 November or 2026-11-05, morning/afternoon/evening '
      '(9 AM / 3 PM / 7 PM), noon, "in 20 minutes", and times like 5pm.';

  static final _clockRe = Temporal.clockRe;

  /// Finds a date/time phrase; returns it plus the text with the phrase removed.
  (DateTime?, String) parseWhen(String text) {
    final (at, rest, _) = _when(text);
    return (at, rest);
  }

  /// (time, text without the phrase, disclosure of any default used). The
  /// time may already be past: callers ask instead of silently moving it.
  (DateTime?, String, String?) _when(String text) {
    final w = _parse(text);
    return (w.at, w.rest, w.note);
  }

  /// Every time phrase in [text] read by the shared resolver against this
  /// engine's clock (the session's captured turn time).
  TemporalReading readWhen(String text) => Temporal.read(text, clock());

  /// [_when] plus whether a day (dated) or a time of day (timed) was given.
  /// Conflicting phrases come back as [conflict] in note, with no time.
  ({DateTime? at, String rest, String? note, bool dated, bool timed}) _parse(
      String text) {
    final r = readWhen(text);
    if (r.conflict) {
      return (at: null, rest: text, note: conflict, dated: false, timed: false);
    }
    return (
      at: r.at,
      rest: r.rest,
      note: r.note,
      dated: r.dated,
      timed: r.timed
    );
  }

  static final _dailyRe = _ci(r'\b(?:daily|every ?day|each day)\b');
  static final _untilDoneRe = _ci(
      r"\b(?:until|till|til)\s+(?:it'?s\s+|i'?m\s+|i\s+am\s+)?(?:done|complete|completed|finished)\b");

  /// For callers that store a repeating reminder: "daily at 8:46 AM until
  /// 5 November", "every day 7pm till done". Null when [text] has no
  /// daily/every-day words. Otherwise exactly one of schedule / problem
  /// (a question to ask the user; nothing should be saved). The time of day
  /// is required; an end date is optional (null = until the task is done).
  /// Nothing is scheduled here.
  ({DailySchedule? schedule, String? problem})? parseDaily(String text) {
    var t = _norm(text);
    final m = _dailyRe.firstMatch(t);
    if (m == null) return null;
    ({DailySchedule? schedule, String? problem}) ask(String p) =>
        (schedule: null, problem: p);
    t = t.replaceFirst(m.group(0)!, ' ').replaceAll(_untilDoneRe, ' ');
    final now = clock();
    DateTime? last;
    final cutoff = _ci(Temporal.untilLead).firstMatch(t);
    if (cutoff != null) {
      // A cutoff's clock must never become the daily reminder time.
      if (_clockRe.hasMatch(t.substring(cutoff.end))) {
        return ask(
            'Please give the daily reminder time and an end date without a separate end time.');
      }
      final end = Temporal.dateIn(t, now, Temporal.untilLead);
      if (end == null || end.date == null || end.tonight) {
        return ask(
            "I couldn't read that end date. Which date should it run until, "
            'e.g. "until 5 November"?');
      }
      (last, t) = (end.date, end.rest);
    }
    final w = _parse(_squash(t));
    if (w.note == conflict || w.at == null || !w.timed) {
      return ask('What time each day should I remind you?');
    }
    if (w.dated) {
      return ask('Should it start on that day, or run every day? Say e.g. '
          '"daily at 8:46 AM until 5 November".');
    }
    final at = w.at!;
    final first = at.isBefore(now)
        ? DateTime(at.year, at.month, at.day + 1, at.hour, at.minute)
        : at;
    final until = last == null
        ? null
        : DateTime(last.year, last.month, last.day, at.hour, at.minute);
    if (until != null && until.isBefore(first)) {
      return ask(
          'That end date is already past, so there would be no reminders. '
          'Which date should it run until?');
    }
    return (
      schedule: DailySchedule(
          hour: at.hour,
          minute: at.minute,
          first: first,
          until: until,
          rest: w.rest,
          note: w.note),
      problem: null
    );
  }

  /// Resolves the user's own time words (as a model copied them). ok = they
  /// fully parsed (nothing unknown left over, no conflicting parts).
  ({DateTime? at, String? note, bool ok}) resolveWhen(String words) {
    final (at, rest, note) = _when(_norm(words));
    final ok = at != null && note != conflict && _extra(rest).isEmpty;
    return (at: ok ? at : null, note: ok ? note : null, ok: ok);
  }

  /// A date/time anywhere in the user's message (incl. "tomo"), with the
  /// disclosure note of any default used; null at when there is none.
  ({DateTime? at, String? note}) findWhen(String text) {
    final (at, _, note) = _when(_req(text));
    return note == conflict ? (at: null, note: null) : (at: at, note: note);
  }

  /// Display form of a clock time, as stored in [ClarifyDraft.time].
  static String clockText(DateTime t) => _clock(t.hour, t.minute);

  /// "don't…", "not…": never a write, whatever the model read.
  static bool isNegated(String raw) => _negRe.hasMatch(_req(raw));
  static final _negRe =
      _ci(r"\b(?:not|don'?t|do not|never|haven'?t|hasn'?t|won'?t|no longer)\b");

  /// Questions, hypotheticals and negations never change data.
  static bool isQuestionOrNegated(String raw) {
    final t = _req(raw);
    // "Can you remind me…?" is a polite request, not a question.
    final polite =
        _ci(r'^\W*(?:(?:hi|hello|hey)\W+)?(?:can|could|would|will) ?(?:you|u)\b')
            .hasMatch(raw.trim());
    return (raw.contains('?') && !polite) ||
        _question.hasMatch(t) ||
        _ci(r"\b(?:not|don'?t|do not|never|haven'?t|hasn'?t|won'?t|no longer)\b")
            .hasMatch(t);
  }

  /// Model-extracted title tidied: filler ("too", "also", "pls") and a leading
  /// "to"/"I have to" removed.
  static String cleanTitle(String s) => _cleanTitle(s
      .replaceAll(_ci(r'[\s,]+(?:too|also|as well|pls|please|plz)[\s.!]*$'), '')
      .replaceFirst(_ci(r'^(?:pls|please|plz)\s+'), ''));

  /// Word stem for loose reference matching ("buying"/"bought" -> "buy").
  static String stem(String w) => _verbs[w] ?? w;

  /// [_when]'s note when a part of day and a clock time disagree.
  static const conflict = 'conflict';

  static String _clock(int h, int m) => Temporal.clockLabel(h, m);

  static String _squash(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Date/time phrases [_when] does not understand. Left in a title they mean
  /// "ask / let the model try", never "store it in the title" or "guess a date".
  /// Repeats ("daily … until …") go through [parseDaily], never a one-off.
  static final _unsupportedDate = RegExp(
      r'\b(?:daily|every ?day|each day|until|till)\b|\b\d{1,2}(?:st|nd|rd|th)?(?: of)? may\b|\bmay \d{1,2}\b|'
      r'\b(?:mon|tues|wednes|thurs|fri|satur|sun)day\b|'
      r'\b(?:january|february|march|april|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\b|'
      r'\b(?:next|this|last) (?:week|weekend|month|year)\b|\bweekend\b|'
      r'\bday after\b|\bnoon\b|\bmidnight\b|\btomorrow\b|\btoday\b|\btonight\b|'
      r'\b\d{1,2}(?:st|nd|rd|th)\b|\b\d{1,4}[/.-]\d{1,2}(?:[/.-]\d{1,4})?\b|'
      r'\bin (?:a|an|\d+|one|two|three|four|five|six|ten) (?:weeks?|months?|years?)\b|\bat \d|\b\d{1,2}:\d{2}\b|\b\d{1,2}(?::\d{2})? ?(?:am|pm)\b|'
      r'\bevery (?:other )?(?:\d+ ?|an? |few |couple of )?(?:minutes?|mins?|hours?|hrs?|days?)\b|'
      r'\b(?:in|within|after) (?:a )?(?:few|several|some) (?:more )?(?:minutes?|mins?|hours?|hrs?|days?)\b',
      caseSensitive: false);

  /// Whether [raw] still names a date/time the app does not schedule blindly.
  static bool hasUnsupportedDate(String raw) => _unsupportedDate.hasMatch(raw);

  /// Trimmed, end punctuation dropped, whitespace collapsed. Casing is kept so
  /// titles are stored as typed; every fast-route pattern is case-insensitive.
  static String _norm(String raw) => raw
      .replaceAll('’', "'")
      .trim()
      .replaceAll(RegExp(r'[.!?]+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ');

  /// Greeting / politeness lead-in: "Hello canu remind me…" -> "remind me…".
  static final _lead = _ci(
      r'^(?:(?:ok(?:ay)?|alright|so|yes|yeah)\b[\s,!]*)?(?:(?:hi|hello|hey|hiya)\b[\s,!]*)?(?:(?:can|could|would|will) ?(?:you|u)\s+|pls\s+|please\s+)?');

  /// The request part of [raw] (see [_lead]).
  static String _req(String raw) {
    final t = _norm(raw);
    var r = t
        .replaceFirst(_lead, '')
        .replaceAll(RegExp(r'\bhv\b'), 'have')
        .replaceAll(RegExp(r'\btomo\b'), 'tomorrow');
    if (r.isEmpty) return t;
    // "Morning 8:10 am remind me X" -> "remind me X Morning 8:10 am"
    // Split at the marker, then check the prefix word by word (linear; no
    // nested-repetition regex to backtrack on).
    final i = r.toLowerCase().indexOf('remind me');
    if (i > 0) {
      final words = r.substring(0, i).split(RegExp(r'[\s,]+'))
        ..removeWhere((w) => w.isEmpty);
      if (words.isNotEmpty && words.every(_timeWord.hasMatch)) {
        r = '${r.substring(i)} ${words.join(' ')}';
      }
    }
    return r;
  }

  /// One word of a leading when-phrase ("Morning", "8:10", "8:10am", "am", "in", "20", "minutes").
  static final _timeWord = _ci(
      r'^(?:today|tomorrow|tonight|this|next|week|in|within|after|the|morning|afternoon|evening|noon|at|on|'
      r'(?:mon|tues|wednes|thurs|fri|satur|sun)day|minutes?|mins?|hours?|hrs?|hr|am|pm|of|'
      r'an?|and|half|quarter|from|now|later|about|around|'
      r'one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|fifteen|twenty|thirty|forty|fifty|'
      r'\d+(?:\.\d+)?(?:m|h|mins?|hrs?)|'
      r'january|february|march|april|may|june|july|august|september|october|november|december|'
      r'jan|feb|mar|apr|jun|jul|aug|sept?|oct|nov|dec|\d{1,2}(?:st|nd|rd|th)|\d{4}(?:-\d{2}-\d{2})?|'
      r'\d{1,2}(?::\d{2})?(?:am|pm)?)$');

  static RegExp _ci(String p) => RegExp(p, caseSensitive: false);

  /// Negations and chained/alternative requests: never act on these directly.
  static final unsafe = _ci(
      r"\b(?:not|don'?t|do not|never|no|isn'?t|wasn'?t|or|unless|but|instead)\b|"
      r'\b(?:and|then|also|after that|plus)\s+(?:then\s+|also\s+)?'
      r'(?:add|create|remind|delete|remove|complete|finish|mark|cancel|list|show|edit|rename|move|postpone|delay)\b|[;?]');

  /// Two separate commitments in one title ("buy eggs and call Mum").
  static final _multiRe = _ci(
      r'\b(?:and|then|also|plus)\s+(?:then\s+|also\s+)?(?:i\s+(?:also\s+)?(?:need|have)\s+to\s+)?'
      r'(?:buy|call|email|text|pay|book|send|pick up|clean|submit|visit|meet|go|finish|write|cook|wash)\b');

  static final _greetRe = _ci(
      r"^(?:hi|hello|hey|hiya|yo|good (?:morning|afternoon|evening)|thanks|thank you|thx)(?: there| corenyth)?$");

  static final _listRe = RegExp(
      r'^(?:(?:what|which) (?:are )?(?:my )?(?:tasks|to-?dos)(?: do i have)?|'
      r'(?:list|show)(?: me)?(?: my| all)? (?:tasks|to-?dos)|(?:my )?(?:tasks|to-?dos))'
      r'(?: (?:for |due )?(today|tomorrow))?$',
      caseSensitive: false);

  static final _listRemindersRe = _ci(
      r'^(?:(?:what|which) (?:are )?(?:my )?(?:reminders|alarms)(?: do i have)?|'
      r'(?:list|show)(?: me)?(?: my| all)? (?:reminders|alarms)|'
      r'(?:my )?(?:reminders|alarms))$');

  /// Catch-up / "remind me what…" is retrieval, never an alarm. Needs a
  /// commitment cue: "what do I need to cook pasta" is a general question.
  static final _catchUpRe = _ci(
      r"\bcatch(?:ing)? (?:up|on)\b|\bwhat(?:'s| is) (?:left|pending|on my plate)\b|"
      r'\bwhat am i missing\b|\bdid i miss\b|\bwhat (?:do|should) i (?:still )?(?:need|have) to do\b');
  static final _remindQueryRe =
      _ci(r'^remind me (?:what|when|which|of what|about what)\b');

  static final _postponeAbsRe = _ci(
      r'^(?:postpone|delay|push(?: back)?|move|reschedule|change)(?: the| my)? (.+?) to (.+)$');

  /// "done with buying milk", "I bought milk": candidate task titles, most
  /// literal first ("buying milk" -> also "buy milk"; "milk" -> also "buy
  /// milk"). Resolved by the session against pending titles only; never fuzzy.
  static final _doneRefRe = _ci(
      r"^(?:i(?:'m| am) )?(?:all )?(?:done|finished) with (.+)$|"
      r"^i(?:'ve| have)? (?:just )?(?:finished|completed|done) (.+)$|"
      r"^(?:i(?:'ve| have)? )?(?:just )?(bought|picked up|called|paid|sent|emailed|booked|cleaned) (.+)$");
  static const _verbs = {
    'buying': 'buy',
    'bought': 'buy',
    'calling': 'call',
    'called': 'call',
    'paying': 'pay',
    'paid': 'pay',
    'sending': 'send',
    'sent': 'send',
    'emailing': 'email',
    'emailed': 'email',
    'booking': 'book',
    'booked': 'book',
    'cleaning': 'clean',
    'cleaned': 'clean',
    'picking up': 'pick up',
    'picked up': 'pick up',
    // "done with the meeting with ceo" names "schedule a meet with ceo"
    'meeting': 'meet',
    'meetings': 'meet',
    'met': 'meet',
  };
  static List<String>? doneRef(String raw) {
    if (raw.contains('?')) return null; // "am I done with…?" is a question
    final t = _req(raw);
    if (unsafe.hasMatch(t)) return null;
    final m = _doneRefRe.firstMatch(t);
    if (m == null) return null;
    final verb = m.group(3)?.toLowerCase();
    final obj = (m.group(1) ?? m.group(2) ?? m.group(4))!
        .replaceFirst(_ci(r'^(?:the|my) '), '')
        .split(RegExp(r'[,;]'))
        .first
        .replaceFirst(_ci(r'\s+(?:finally|already|at last)$'), '')
        .trim();
    if (verb != null) return ['${_verbs[verb]} $obj'];
    final g =
        _ci(r'^(buying|calling|paying|sending|emailing|booking|cleaning|picking up) (.+)$')
            .firstMatch(obj);
    return [
      obj,
      if (g != null)
        '${_verbs[g.group(1)!.toLowerCase()]} ${g.group(2)}'
      else
        'buy $obj',
    ];
  }

  /// "postpone gym by 2h": (reference, raw amount), or null.
  static (String, String)? relativePostpone(String raw) {
    final m =
        _ci(r'^(?:postpone|delay|push(?: back)?|move)(?: the| my)? (.+?) (?:by|for) (.+)$')
            .firstMatch(_req(raw));
    return m == null ? null : (m.group(1)!.trim(), m.group(2)!);
  }

  /// Notification preference phrases stripped from titles; returns overrides.
  /// Disables are stripped first so "no follow-up" never reads as "follow-up";
  /// whatever negation is left afterwards is a real one.
  static (bool? multiple, bool? followUp, String text) extractFlags(
      String raw) {
    var t = raw;
    bool? multiple, followUp;
    bool take(RegExp re) {
      if (!re.hasMatch(t)) return false;
      t = t.replaceAll(re, ' ');
      return true;
    }

    if (take(_ci(
        r"\b(?:with |and )?(?:no|without) follow-?ups?\b|\b(?:and )?don'?t follow(?: me)? up\b"))) {
      followUp = false;
    }
    if (take(_ci(
        r'\b(?:just )?once\b|\bno multiple (?:reminders|alerts|times)\b|\b(?:a |one |with a )?single (?:reminder|alert)\b'))) {
      multiple = false;
    }
    if (take(_ci(r'\b(?:(?:do|please|and)\s+)*(?:remind me )?multiple times\b|'
        r'\bwith multiple (?:reminders|alerts|notifications)\b'))) {
      multiple = true;
    }
    if (take(_ci(
        r'\b(?:with (?:a )?)?follow-?ups?\b|\b(?:and |do |please )?follow(?: me)? up\b'))) {
      followUp = true;
    }
    t = t.replaceAll(_ci(r'\b(?:(?:do|please)\s+)+remind me\b'), ' ');
    return (multiple, followUp, _squash(t).replaceAll(RegExp(r'[\s,]+$'), ''));
  }

  static final _captureRe = _ci(
      r'^(?:i\s+)?(?:(?:also|still|really)\s+)*(?:have to|need to|must|gotta|got to|remember to)\s+(.+)$');
  static final _haveRe = _ci(r"^i(?:'ve| have)(?: got)? (?:a|an) (.+)$");

  static String _cleanTitle(String s) => _squash(s
      .replaceFirst(_ci(r'^(?:to|about|that)\s+'), '')
      .replaceFirst(
          _ci(r"^i(?:'ve| have| need| must| got)(?: got)?(?: to)? (?:(?:a|an) )?"),
          '')
      .replaceFirst(_ci(r'[\s,]+(?:to|at|on|by|in|for|before)?[\s,]*$'), '')
      .replaceFirst(_ci(r'\s+(?:too|finally|as well)$'), '')
      .replaceFirst(_ci(r'\s+next(?:\s+[a-z]+){0,2}\s+moon$'), ''));

  /// Undecided or hypothetical: "maybe I should…", "I might…". Talked
  /// about, never saved.
  static bool isTentative(String raw) => _tentativeRe.hasMatch(_req(raw));
  static final _tentativeRe = _ci(
      r"\b(?:maybe|perhaps|might|probably|possibly|thinking (?:about|of)|wondering|not sure (?:if|whether)|if|whether)\b");

  static final _alarmRe = _ci(
      r'^(?:set|create|add|make|start) (?:an? |me an? )?(?:alarm|reminder|timer)(?: for)? (.+)$');
  static final _trailingRemindRe = _ci(
      r'^(.+?)[\s,]+(?:and |so )?(?:pls |please )?remind me(?: (?:about|of) (?:it|that))?$');

  /// Plain-language create: "remind me…", "add task…", "I need to…",
  /// "I have a meeting tomorrow at 12pm", "meeting at 3, remind me", "set
  /// an alarm for half an hour from now". Null when [raw] isn't one, or is
  /// negated/tentative/ambiguous.
  Create? parseCreate(String raw) {
    final t = _req(raw);
    if (_remindQueryRe.hasMatch(t) || _catchUpRe.hasMatch(t)) return null;
    if (_tentativeRe.hasMatch(t)) return null;
    String tool = 'create_task', body;
    bool? multiple, followUp;
    var needsWhen = false;
    RegExpMatch? m;
    if ((m = _ci(r'^remind me (.+)$').firstMatch(t)) != null) {
      tool = 'create_reminder';
      (multiple, followUp, body) = extractFlags(m!.group(1)!);
    } else if ((m = _alarmRe.firstMatch(t)) != null) {
      tool = 'create_reminder';
      (multiple, followUp, body) = extractFlags(m!.group(1)!);
      // "a timer for 10 minutes": the amount alone is how long from now.
      final lead =
          _ci('^(?:${Temporal.durationSource})(?=\\s|\$)').firstMatch(body);
      if (lead != null && !readWhen(body).spans.any((s) => s.amount != null)) {
        body = 'in $body';
      }
    } else if ((m = _trailingRemindRe.firstMatch(t)) != null &&
        !_ci(r'\bremind me\b').hasMatch(m!.group(1)!)) {
      tool = 'create_reminder';
      (multiple, followUp, body) = extractFlags(m.group(1)!);
      needsWhen = true; // "meeting, remind me" with no time: not a request yet
    } else if ((m = _ci(r'^(?:add|create|new) (?:a )?task:? (.+)$')
                .firstMatch(t)) !=
            null ||
        (m = _captureRe.firstMatch(t)) != null) {
      body = m!.group(1)!;
    } else if ((m = _haveRe.firstMatch(t)) != null ||
        (m = _ci(r'^i want to (.+)$').firstMatch(t)) != null) {
      body = m!.group(1)!;
      needsWhen = true; // Untimed facts and wishes are not commitments.
    } else {
      return null;
    }
    if (unsafe.hasMatch(body)) return null;
    final r = readWhen(body);
    final (at, rest, note) = r.conflict
        ? (null, body, conflict)
        : r.at == null
            ? (null, body, null)
            : (r.at, r.rest, r.note);
    final title = _cleanTitle(r.conflict ? _stripTimes(body) : rest);
    final unsupported =
        _unsupportedDate.hasMatch(title) || note == conflict || r.unsupported;
    if (needsWhen && at == null && !unsupported) return null;
    return (
      tool: tool,
      title: title,
      at: at,
      note: note,
      multiple: multiple,
      followUp: followUp,
      unsupported: unsupported,
      multi: _multiRe.hasMatch(title),
      reading: r,
    );
  }

  /// [text] without any time words (each phrase read alone), for the title
  /// of a request whose times disagree.
  String _stripTimes(String text) {
    var t = text;
    for (final s in readWhen(text).spans) {
      t = t.replaceFirst(s.text, ' ');
    }
    return _squash(t.replaceAll(_ci(r'\b(?:at|on|in|by)\s*(?=,|$)'), ' '));
  }

  /// Why [c]'s time can't be used as said, as a lead-in to the time question,
  /// or null: "in 10 minutes" and "at 9" disagree, or "before 5 PM" is a
  /// deadline rather than a time to remind.
  static String? timeProblem(TemporalReading r, bool reminder, DateTime now) {
    if (r.conflict) {
      return '${r.conflictText} disagree, so I saved nothing yet.';
    }
    final a = r.anchor;
    if (reminder &&
        r.at != null &&
        a != null &&
        a.relation == TemporalRelation.before &&
        r.role == TemporalRole.deadline) {
      return '${_cap(a.text)} ${friendlyTime(r.at!, now)} is the deadline.';
    }
    return null;
  }

  static String _cap(String s) =>
      s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

  static bool isMulti(String title) => _multiRe.hasMatch(title);

  static String multiReply(String title) => _multiReply(title);

  static String _multiReply(String title) =>
      'That sounds like more than one thing ("$title"). Send them one at a time '
      "so I don't save only part of it.";

  /// If [raw] is a clear create that still needs a time from the user (a
  /// reminder without one, a time that already passed today, two times that
  /// disagree, or a deadline given where an alert time is needed), the draft.
  ClarifyDraft? maybeClarify(String raw) {
    final c = parseCreate(raw);
    if (c == null || c.multi || c.title.isEmpty) return null;
    final problem =
        timeProblem(c.reading, c.tool == 'create_reminder', clock()) != null;
    if (c.unsupported) return null; // conflicts: see [conflictDraft]
    if (!problem &&
        (c.at == null
            ? c.tool != 'create_reminder'
            : !c.at!.isBefore(clock()))) {
      return null;
    }
    return ClarifyDraft(
        tool: c.tool,
        title: c.title,
        multiple: c.multiple,
        followUp: c.followUp,
        time: c.at == null || c.note != null || problem
            ? null
            : _clock(c.at!.hour, c.at!.minute));
  }

  /// A day-only reply ("tomorrow") takes the draft's explicit clock time.
  String _withTime(ClarifyDraft d, String t) => d.time == null ||
          _clockRe.hasMatch(t) ||
          readWhen(t).spans.any((s) => s.amount != null) ||
          _when(t).$1 == null
      ? t
      : '$t at ${d.time}';

  /// Reply to the question for [maybeClarify]'s draft. [maybeClarify] states why
  /// it asks when the time had passed. `keep` = still waiting (the reply repeats
  /// the question). Null: [raw] is a new request; route it normally.
  ({Map<String, Object?> call, bool keep})? resolveClarify(
      ClarifyDraft d, String raw) {
    final t = _req(raw);
    ({Map<String, Object?> call, bool keep}) ask(String why) =>
        (call: _say('$why ${d.prompt}'), keep: true);
    if (_cancelRe.hasMatch(t)) {
      return (call: _say('Okay, I dropped "${d.title}".'), keep: false);
    }
    final (at, rest, note) = _when(_withTime(d, t));
    final extra = _extra(rest);
    if (at == null) {
      if (_unsupportedDate.hasMatch(t) && t.split(' ').length <= 4) {
        return ask("I can't schedule that kind of date yet.");
      }
      return null;
    }
    if (extra.isNotEmpty) {
      return ask(
          'I\'m not sure if "$raw" is the time for "${d.title}" or a new '
          'request, so I did nothing. Reply with just the time, or "cancel".');
    }
    if (at.isBefore(clock())) {
      return ask('${friendlyTime(at, clock())} has already passed.');
    }
    final args = d.tool == 'create_reminder'
        ? _reminderArgs(d.title, at, multiple: d.multiple, followUp: d.followUp)
        : {'title': d.title, 'due': at.toIso8601String()};
    return (
      call: {..._tool(d.tool, args), if (note != null) 'note': note},
      keep: false
    );
  }

  /// A reply that only answers [d]'s question (a time, or cancel): settled
  /// without the model. Anything longer may be a new request.
  bool isTimeAnswer(ClarifyDraft d, String raw) {
    final t = _req(raw);
    if (_cancelRe.hasMatch(t)) return true;
    final (at, rest, _) = _when(_withTime(d, t));
    if (at != null) return _extra(rest).isEmpty;
    return _unsupportedDate.hasMatch(t) && t.split(' ').length <= 4;
  }

  static final _cancelRe =
      _ci(r'^(?:cancel|never ?mind|forget (?:it|about it)|stop|no)$');
  static String _extra(String rest) => rest
      .replaceAll(
          _ci(r'\b(?:ok(?:ay)?|please|pls|thanks|then|make it|at|on|by|yes|for|it)\b'),
          '')
      .replaceAll(RegExp(r'[\s,.!]+'), '');

  /// A clear create whose time phrases disagree ("in 10 minutes at 9"): the
  /// draft that keeps its title while asking which time, or null.
  ClarifyDraft? conflictDraft(String raw) {
    final c = parseCreate(raw);
    if (c == null || !c.reading.conflict || c.multi || c.title.isEmpty) {
      return null;
    }
    if (_unsupportedDate.hasMatch(c.title)) return null;
    return ClarifyDraft(
        tool: c.tool,
        title: c.title,
        multiple: c.multiple,
        followUp: c.followUp);
  }

  /// Lead-in for a draft parked by [maybeClarify] or [conflictDraft] (the past time, the
  /// disagreeing times, the deadline), or ''.
  String clarifyReason(String raw) {
    final c = parseCreate(raw);
    if (c == null) return '';
    final problem =
        timeProblem(c.reading, c.tool == 'create_reminder', clock());
    if (problem != null) return '$problem ';
    final at = c.at;
    return at == null
        ? ''
        : '${friendlyTime(at, clock())} has already passed. ';
  }

  static Map<String, Object?> _reminderArgs(String title, DateTime at,
          {bool? multiple, bool? followUp}) =>
      {
        'title': title,
        'at': at.toIso8601String(),
        if (multiple != null) 'multiple': multiple,
        if (followUp != null) 'follow_up': followUp,
      };

  /// Duration for "by 2h" / "for 30 minutes" postpone replies; null if unknown.
  static Duration? parseDuration(String raw) {
    final d = Temporal.parseDuration(_norm(raw));
    return d == null || d < const Duration(minutes: 1) ? null : d;
  }

  /// Strict deterministic route: only complete, anchored, unambiguous commands.
  /// Returns the tool-call map (with an optional top-level `note` disclosing a
  /// default), or null so the text goes to the model.
  Map<String, Object?>? fastRoute(String raw) {
    final calc = calculate(_norm(raw));
    if (calc != null) return _say(calc);
    if (_greetRe.hasMatch(_norm(raw))) {
      return _say(RegExp(r'^th', caseSensitive: false).hasMatch(_norm(raw))
          ? "You're welcome! Anything else I can help with?"
          : 'Hi! How can I help?');
    }
    final t = _req(raw);
    RegExpMatch? m;

    // Catch-up / reminder recall before any create_reminder path.
    if (_remindQueryRe.hasMatch(t) || _catchUpRe.hasMatch(t)) {
      if (_ci(r'\b(?:reminders?|alarms?)\b').hasMatch(t)) {
        return _tool('list_reminders', {});
      }
      if (!_ci(r'\btomorrow\b').hasMatch(t)) {
        return _tool(
            'list_tasks', {}); // everything pending: undated + overdue too
      }
      final now = clock();
      return _tool('list_tasks', {
        'from': DateTime(now.year, now.month, now.day + 1).toIso8601String(),
        'to': DateTime(now.year, now.month, now.day + 2).toIso8601String(),
      });
    }
    if (_listRemindersRe.hasMatch(t)) return _tool('list_reminders', {});
    if ((m = _listRe.firstMatch(t)) != null) {
      final day = m!.group(1)?.toLowerCase();
      final now = clock();
      final from =
          DateTime(now.year, now.month, now.day + (day == 'tomorrow' ? 1 : 0));
      return _tool('list_tasks', {
        if (day != null) ...{
          'from': from.toIso8601String(),
          'to': DateTime(from.year, from.month, from.day + 1).toIso8601String(),
        }
      });
    }

    final safe =
        t.toLowerCase().startsWith('remind me ') ? extractFlags(t).$3 : t;
    if (unsafe.hasMatch(safe)) return null;

    if ((m = _ci(r'^(?:complete|finish|mark)(?: the)? task (.+?)(?: as)?(?: done| complete| completed)?$')
                .firstMatch(t)) !=
            null ||
        (m = _ci(r'^mark (.+?)(?: as)? (?:done|complete|completed)$')
                .firstMatch(t)) !=
            null) {
      return _ref('complete_task', m!.group(1)!);
    }
    if ((m = _ci(r'^(?:delete|remove)(?: the)? (.+?) (?:task|one)$')
            .firstMatch(t)) !=
        null) {
      return _ref('delete_task', m!.group(1)!);
    }
    if ((m = _ci(r'^(?:delete|remove)(?: the)? task (.+)$').firstMatch(t)) !=
        null) {
      return _ref('delete_task', m!.group(1)!);
    }
    if ((m = _ci(r'^cancel(?: the| my)? reminder (.+)$').firstMatch(t)) !=
        null) {
      return _ref('cancel_reminder', m!.group(1)!);
    }
    if ((m = _ci(r'^rename(?: the)? task (.+?) to (.+)$').firstMatch(t)) !=
        null) {
      return _tool('edit_task',
          {..._sel(m!.group(1)!, 'target_title'), 'title': m.group(2)!});
    }
    if ((m =
            _ci(r'^(?:move|reschedule|change)(?: the| my)? reminder (.+?) to (.+)$')
                .firstMatch(t)) !=
        null) {
      final (at, rest, _) = _when(m!.group(2)!);
      if (at == null || rest.isNotEmpty || at.isBefore(clock())) return null;
      return _tool('edit_reminder',
          {..._sel(m.group(1)!, 'target_title'), 'at': at.toIso8601String()});
    }
    if ((m = _postponeAbsRe.firstMatch(t)) != null) {
      final (at, rest, note) = _when(m!.group(2)!);
      if (at == null || rest.isNotEmpty || at.isBefore(clock())) return null;
      return {
        ..._tool('edit_task', {
          ..._sel(m.group(1)!, 'target_title'),
          'due': at.toIso8601String()
        }),
        if (note != null) 'note': note,
      };
    }
    // Plain shopping / errand capture without the word "task".
    if ((m =
            _ci(r'^(?:add|put) (.+?) (?:to|on) (?:my |the )?(?:shopping(?: list)?|groceries)$')
                .firstMatch(t)) !=
        null) {
      return _tool('create_task', {'title': 'buy ${m!.group(1)!.trim()}'});
    }

    final c = parseCreate(t);
    if (c == null || c.unsupported || c.title.isEmpty) return null;
    if (c.multi) return _say(_multiReply(c.title));
    if (timeProblem(c.reading, c.tool == 'create_reminder', clock()) != null) {
      return null; // maybeClarify asks
    }
    final at = c.at;
    if (at == null) {
      return c.tool == 'create_task'
          ? _tool('create_task', {'title': c.title})
          : null;
    }
    if (at.isBefore(clock())) return null; // maybeClarify asks
    return {
      ..._tool(
          c.tool,
          c.tool == 'create_reminder'
              ? _reminderArgs(c.title, at,
                  multiple: c.multiple, followUp: c.followUp)
              : {'title': c.title, 'due': at.toIso8601String()}),
      if (c.note != null) 'note': c.note,
    };
  }

  /// `#3` / `3` -> id, anything else -> exact title (resolved against the DB later).
  static Map<String, Object?> _ref(String tool, String s) =>
      _tool(tool, _sel(s, 'title'));

  static Map<String, Object?> _sel(String s, String titleKey) {
    final id = RegExp(r'^#?(\d+)$').firstMatch(s);
    return id != null ? {'id': int.parse(id.group(1)!)} : {titleKey: s};
  }

  static final _mutateVerbs = _ci(
      r'\b(?:add|create|new|remind|complete|finish|mark|delete|remove|cancel|edit|rename|change|move|postpone|delay|push)\b');

  /// Questions about how things work are not commands ("explain how to delete tasks").
  static final _question = _ci(
      r'^(?:how|why|what|when|where|which|who|explain|tell me|should|is|are|does|do i|am i|can i|could i|if|suppose|what if)\b');

  static final _personalCue =
      _ci(r"\b(?:i|me|my|mine|we|our|remember|prefer|usually|normally)\b");
  static final _generalRe = _ci(
      r'^(?:who|what|when|where|why|how)\s+(?:is|are|was|were|do|does|did|can|could|should)\b');

  /// A general-knowledge question: never answered from personal memories.
  static bool isGeneralKnowledge(String raw) {
    final t = _req(raw);
    return _generalRe.hasMatch(t) && !_personalCue.hasMatch(t);
  }

  /// True when a model mutation is grounded in [user]: the request is a
  /// command (not a question/negation), names the same item (title words or
  /// the id), and any date equals what the app itself parses from the text.
  bool justifiedMutation(String tool, String user, Map<String, Object?> args) {
    if (tool == 'respond') return true;
    if (tool == 'list_tasks' ||
        tool == 'list_reminders' ||
        tool == 'search_memory') {
      // A read only answers a question/lookup, never stands in for a create
      // or completion the user clearly asked for.
      if (parseCreate(user) != null || doneRef(user) != null) return false;
      return tool == 'search_memory'
          ? !isGeneralKnowledge(user)
          : _ci(r'\b(?:what|which|list|show|any|anything|plate|tasks?|reminders?|alarms?|to-?dos?|plan|agenda|left|pending|catch|due|upcoming)\b')
              .hasMatch(_req(user));
    }
    final t = _req(user);
    if (unsafe.hasMatch(extractFlags(t).$3) || _question.hasMatch(t))
      return false;
    final words = ' ${normTitle(t)} ';
    bool mentions(Object? s) =>
        s is String &&
        normTitle(s).isNotEmpty &&
        words.contains(' ${normTitle(s)} ');
    bool refOk() => args['id'] != null
        ? RegExp('(?:#|\\b)${args['id']}\\b').hasMatch(t)
        : mentions(args['title'] ?? args['target_title']);
    bool sameWhen(Object? d) => d == null || _when(t).$1 == d;
    bool cue(String re) => _ci(re).hasMatch(t);
    switch (tool) {
      case 'create_task':
        return cue(
                r'\b(?:add|create|new|put|task|to-?do|need to|have to|must|shopping)\b') &&
            mentions(args['title']) &&
            sameWhen(args['due']);
      case 'create_reminder':
        return cue(r'^remind me\b') &&
            !_remindQueryRe.hasMatch(t) &&
            !_catchUpRe.hasMatch(t) &&
            mentions(args['title']) &&
            sameWhen(args['at']) &&
            // overrides only as the user stated them; omitted = saved preferences
            args['multiple'] == extractFlags(t).$1 &&
            args['follow_up'] == extractFlags(t).$2 &&
            (args['task_id'] == null ||
                _ci('\\btask\\s*(?:#|id\\s*|number\\s*)?${args['task_id']}\\b')
                    .hasMatch(t));
      case 'complete_task':
        // Only an explicit command, or a completion statement doneRef accepts
        // (it rejects questions, "if…", negations), naming that same task.
        if (fastRoute(user)?['tool'] == 'complete_task') return refOk();
        final refs = doneRef(user);
        return refs != null &&
            (args['id'] != null
                ? refOk()
                : refs
                    .any((r) => normTitle(r) == normTitle('${args['title']}')));
      case 'delete_task':
        return cue(r'\b(?:delete|remove)\b') && refOk();
      case 'cancel_reminder':
        return cue(r'\bcancel\b') && refOk();
      case 'edit_task':
      case 'edit_reminder':
        return cue(
                r'\b(?:edit|rename|change|move|reschedule|postpone|delay|push)\b') &&
            refOk() &&
            (args['title'] == null || mentions(args['title'])) &&
            sameWhen(args['due'] ?? args['at']);
    }
    return false;
  }

  /// Rule "model": [fastRoute] plus honest read-only fallbacks for when the
  /// LLM is unavailable or produced invalid/unjustified output.
  Map<String, Object?> plan(String raw) {
    final fast = fastRoute(raw);
    if (fast != null) return fast;
    final text = _req(raw);
    final t = text.toLowerCase();

    if (unsafe.hasMatch(extractFlags(text).$3) && _mutateVerbs.hasMatch(t)) {
      return _say(
          "I didn't change anything: that request is negated, ambiguous, or combines several actions. "
          'Please send one clear request at a time.');
    }
    if (_tentativeRe.hasMatch(text) &&
        _ci(r'\b(?:remind|meet|call|task)').hasMatch(t)) {
      return _say("I haven't set anything since that sounds undecided. "
          'If you want a reminder, tell me what and when.');
    }
    final c = parseCreate(text);
    if (c != null && c.note == conflict) {
      final r = readWhen(text);
      return _say(
          "I didn't save that: ${r.spans.isEmpty ? 'those times' : r.conflictText} disagree. "
          'Which time did you mean?');
    }
    if (c != null && c.unsupported) {
      return _say(c.tool == 'create_reminder'
          ? "I didn't set a reminder: I don't schedule that kind of date yet. $supportedWhen"
          : "I didn't add that: I don't understand that date yet. $supportedWhen");
    }
    if (t.startsWith('remind me')) {
      return _say("What should I remind you about? "
          'Try e.g. "remind me tomorrow at 8 to call Mom".');
    }
    if (RegExp(r'^(?:add|create|new)\s+(?:a\s+)?task\b').hasMatch(t)) {
      return _say(
          "I didn't add that: I couldn't understand the task or its date. $supportedWhen");
    }
    if (RegExp(r'\b(tasks?|to-?dos?|to do)\b').hasMatch(t) &&
        RegExp(r'^(what|which|list|show|do i|any)').hasMatch(t)) {
      final now = clock();
      final today = DateTime(now.year, now.month, now.day);
      DateTime? from, to;
      if (t.contains('tomorrow')) {
        from = DateTime(today.year, today.month, today.day + 1);
        to = DateTime(today.year, today.month, today.day + 2);
      } else if (t.contains('today')) {
        from = today;
        to = DateTime(today.year, today.month, today.day + 1);
      }
      return _tool('list_tasks', {
        if (from != null) 'from': from.toIso8601String(),
        if (to != null) 'to': to.toIso8601String(),
        if (from == null && to == null) 'include_done': true,
      });
    }
    if (_personalCue.hasMatch(t) &&
        RegExp(r'^(what|when|who|where|how).*\b(did i tell you|do you know|do you remember|normally|usually|about)\b')
            .hasMatch(t)) {
      return _tool('search_memory', {'query': text});
    }
    // Only the strict fastRoute above may emit mutations; past here the rules
    // answer read-only questions or explain, never act on unanchored text.
    if (RegExp(
            r'\b(?:complete|finish|mark|delete|remove|cancel|edit|rename|change|move|postpone|delay)\b')
        .hasMatch(t)) {
      return _say(
          "I didn't change anything: I couldn't tell exactly what you meant. "
          'Try e.g. "delete task 3", "complete task buy milk", or "postpone gym to tomorrow at 5".');
    }
    if (isExplicitRemember(t)) return _say("Okay, I'll remember that.");
    if (RegExp(
            r"^(?:how are you|how's it going|how is it going|what'?s up|sup|you there)\b")
        .hasMatch(t)) {
      return _say(
          "I'm doing well, thanks! Want to go over what's on your plate?");
    }
    if (isGeneralKnowledge(text)) {
      return _say("I can't look that up offline, and I'd rather not guess. "
          'I can help with your tasks, reminders, and quick calculations.');
    }
    return _say(
        "I'm not sure what you'd like me to do with that. I can add tasks, set reminders, "
        "tell you what's on your plate, or do quick calculations.");
  }

  static final _fact = RegExp(
      r"^i\s+(?:(?:usually|normally|always|never|really)\s+)?(?:am|'m|work|live|prefer|like|love|hate|dislike|need|use|go|have|study)\b");

  /// Short-lived plans and obligations: never stored as personal memory.
  /// Habits ("I usually have meetings on Monday") still count as durable.
  static final _temporary = _ci(
      r'\b(?:today|tomorrow|tonight|this (?:morning|afternoon|evening|week)|next (?:week|month)|'
      r'(?:mon|tues|wednes|thurs|fri|satur|sun)day|at \d|\d\s*(?:am|pm)|in \d+\s*(?:min|minute|hour|day)s?|'
      r'(?:have|need|got) to|gotta|must|remind)\b');
  static final _durable = _ci(
      r'\b(?:usually|normally|always|never|every|prefer|prefers|like|likes|love|hate)\b');
  static bool isTemporary(String text) =>
      _temporary.hasMatch(text) && !_durable.hasMatch(text);

  /// "remember (that) X" — but not "remember to X", which is a task/reminder.
  static bool isExplicitRemember(String text) =>
      RegExp(r'^(?:please\s+)?remember(?:\s+that)?\s+(?!to\b)\S',
              caseSensitive: false)
          .hasMatch(text.trim());

  Map<String, Object?> extractMemory(String raw) {
    final text = raw
        .trim()
        .replaceFirst(RegExp(r'^actually[, ]+', caseSensitive: false), '')
        .replaceFirst(RegExp(r'\s+now[.!?]*$', caseSensitive: false), '')
        .replaceAll(RegExp(r'[.!?]+$'), '');
    final t = text.toLowerCase();
    if (isTemporary(t)) return {'remember': false};
    final r = RegExp(r'^(?:please\s+)?remember(?:\s+that)?\s+(.+)$',
            caseSensitive: false)
        .firstMatch(text);
    if (r != null) {
      final inner = extractMemory(
          r.group(1)!); // "remember I like tea" -> "User likes tea"
      return inner['remember'] == true
          ? inner
          : {'remember': true, 'memory': r.group(1)!, 'category': 'fact'};
    }
    if (_fact.hasMatch(t)) {
      var rest = text.substring(1).trim();
      final verb = RegExp(
              r"^('m|am|work|live|prefer|like|love|hate|dislike|use|go|have|study)\b",
              caseSensitive: false)
          .firstMatch(rest);
      if (verb != null) {
        const forms = {
          "'m": 'is',
          'am': 'is',
          'work': 'works',
          'live': 'lives',
          'prefer': 'prefers',
          'like': 'likes',
          'love': 'loves',
          'hate': 'hates',
          'dislike': 'dislikes',
          'use': 'uses',
          'go': 'goes',
          'have': 'has',
          'study': 'studies',
        };
        final word = verb.group(1)!.toLowerCase();
        rest = '${forms[word]}${rest.substring(verb.end)}';
      }
      return {
        'remember': true,
        'memory': 'User $rest',
        'category':
            RegExp(r'prefer|like|love|hate|usually|normally|always|never')
                    .hasMatch(t)
                ? 'preference'
                : 'fact',
      };
    }
    return {'remember': false};
  }
}
