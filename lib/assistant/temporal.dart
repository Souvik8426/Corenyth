/// The one place user time words become times. Rules, semantic plans and
/// clarification answers all resolve through [Temporal.read] against a single
/// instant captured when the turn was submitted, so "in 10 mins" means the
/// same thing however long inference took.
library;

/// What a time phrase is about. A reminder fires at [eventStart] or [alert];
/// a [deadline] is when something must be done by, never an event start.
enum TemporalRole { eventStart, alert, deadline, eventEnd, recurrence }

/// How the words relate the time to the submission instant or the event:
/// "in/after 10 min" and "10 min from now" ([offset]), "within 10 min"
/// ([within]), "5 min before" ([before]: an early alert, or a deadline when
/// followed by a clock/day), "by 5pm" ([by]), "for 30 min" ([lasting]),
/// "every 2 hours" ([every]) and named days/clock times ([calendar]).
enum TemporalRelation { offset, within, before, by, lasting, every, calendar }

class TemporalSpan {
  /// The user's own words, as typed.
  final String text;
  final TemporalRelation relation;
  final TemporalRole role;
  final Duration? amount;
  const TemporalSpan(this.text, this.relation, this.role, [this.amount]);
}

enum TemporalStatus { none, resolved, conflict, unsupported }

/// Everything [Temporal.read] found in one piece of text.
class TemporalReading {
  final TemporalStatus status;

  /// When the reminder/task is: the event start, alert time or deadline
  /// ([role] says which). Null unless [status] is resolved. May be past.
  final DateTime? at;
  final TemporalRole role;

  /// The text with every understood time phrase removed (title candidate).
  final String rest;

  /// Disclosure of a default or interpretation used, or null.
  final String? note;

  /// A day / a time of day was given (offsets count as both).
  final bool dated, timed;
  final List<TemporalSpan> spans;

  /// "5 minutes before": an early alert relative to [at].
  final Duration? lead;

  /// "for 30 minutes": how long the event lasts (see [end]).
  final Duration? length;

  const TemporalReading._(this.status,
      {this.at,
      this.role = TemporalRole.eventStart,
      required this.rest,
      this.note,
      this.dated = false,
      this.timed = false,
      this.spans = const [],
      this.lead,
      this.length});

  bool get conflict => status == TemporalStatus.conflict;
  bool get unsupported => status == TemporalStatus.unsupported;

  /// The event's end, when its length was given with its start.
  DateTime? get end => at == null || length == null ? null : at!.add(length!);

  /// Phrases that place the event/alert (not a lead time or a length).
  Iterable<TemporalSpan> get _anchors => spans.where((s) =>
      s.relation != TemporalRelation.lasting &&
      !(s.relation == TemporalRelation.before && s.amount != null));

  /// The time phrase that set [at] ("within 10 mins"), or null.
  TemporalSpan? get anchor => _anchors.firstOrNull;

  /// Phrases that disagree, quoted: "in 10 minutes" and "at 9".
  String get conflictText => _anchors.map((s) => '"${s.text}"').join(' and ');
}

RegExp _ci(String p) => RegExp(p, caseSensitive: false);

class Temporal {
  Temporal._();

  // ---- durations ----

  static const _numWord =
      r'(?:an?|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|'
      r'thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|'
      r'(?:twenty|thirty|forty|fifty)(?:[\s-](?:one|two|three|four|five|six|seven|eight|nine))?|'
      r'sixty|ninety|(?:a\s+)?couple(?:\s+of)?)';
  static const _num = '(?:\\d+(?:\\.\\d+)?|$_numWord)';
  static const _unit = r'(?:minutes?|mins?|hours?|hrs?|hr|days?)';

  /// One amount: "10 mins", "ten minutes", "an hour", "2h", "30m".
  static const _piece =
      '(?:$_num\\s*$_unit(?![a-z])|\\d+(?:\\.\\d+)?[mhd](?![a-z\\d]))';

  /// A duration phrase: "half an hour", "one and a half hours", "1h30",
  /// "an hour and a half", "1 hour 30 minutes". [parseDuration] values it.
  static const durationSource =
      '(?:half\\s+(?:an\\s+)?hour|half-hour|(?:an?\\s+)?quarter\\s+(?:of\\s+an\\s+)?hour|'
      'three\\s+quarters\\s+of\\s+an\\s+hour|'
      '$_num\\s+and\\s+a\\s+half\\s+$_unit(?![a-z])|'
      '\\d+\\s*h\\s*\\d{1,2}(?:\\s*(?:m|mins?|minutes?))?(?![a-z\\d])|'
      '$_piece(?:\\s+and\\s+a\\s+half)?(?:\\s+(?:and\\s+)?$_piece)?|'
      // "within the next hour": one of the unit.
      '(?<=\\bnext\\s{1,3})(?:hour|day|minute)(?![a-z]))';
  static final _durRe = _ci('\\b$durationSource');
  static final _pieceRe = _ci('\\b$_piece');

  static const _words = {
    'a': 1,
    'an': 1,
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
    'five': 5,
    'six': 6,
    'seven': 7,
    'eight': 8,
    'nine': 9,
    'ten': 10,
    'eleven': 11,
    'twelve': 12,
    'thirteen': 13,
    'fourteen': 14,
    'fifteen': 15,
    'sixteen': 16,
    'seventeen': 17,
    'eighteen': 18,
    'nineteen': 19,
    'twenty': 20,
    'thirty': 30,
    'forty': 40,
    'fifty': 50,
    'sixty': 60,
    'ninety': 90,
  };

  static double? _number(String s) {
    final t = s.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');
    final n = double.tryParse(t);
    if (n != null) return n;
    if (t.contains('couple')) return 2;
    final parts = t.split(RegExp(r'[\s-]'));
    var sum = 0;
    for (final p in parts) {
      final v = _words[p];
      if (v == null) return null;
      sum += v;
    }
    return sum.toDouble();
  }

  static int _rank(String unit) {
    final u = unit.toLowerCase();
    return u.startsWith('d')
        ? 3
        : u.startsWith('h')
            ? 2
            : 1;
  }

  static Duration _of(double n, String unit) {
    final minutes = switch (_rank(unit)) { 3 => 1440, 2 => 60, _ => 1 };
    return Duration(seconds: (n * minutes * 60).round());
  }

  /// "10 mins", "an hour and a half", "2h", "1h30", "half an hour"; an
  /// optional leading "by"/"for" ("postpone by 2h"). Null unless all of
  /// [raw] is one duration.
  static Duration? parseDuration(String raw) {
    final t = raw
        .trim()
        .replaceAll(RegExp(r'[.!?]+$'), '')
        .replaceFirst(_ci(r'^(?:by|for)\s*'), '');
    final m = _ci('^$durationSource\$').firstMatch(t);
    return m == null ? null : _value(m.group(0)!);
  }

  /// Value of a [durationSource] match; null for a compound whose units do
  /// not shrink ("10 minutes and 5 minutes" is two amounts, not one).
  static Duration? _value(String s) {
    final t = s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (RegExp(r'^half(?:-| (?:an )?)hour$').hasMatch(t)) {
      return const Duration(minutes: 30);
    }
    if (RegExp(r'^three quarters').hasMatch(t)) {
      return const Duration(minutes: 45);
    }
    if (t.contains('quarter')) return const Duration(minutes: 15);
    if (RegExp(r'^(?:hour|day|minute)$').hasMatch(t)) return _of(1, t);
    final hm = RegExp(r'^(\d+) ?h ?(\d{1,2})(?: ?(?:m|mins?|minutes?))?$')
        .firstMatch(t);
    if (hm != null) {
      final m = int.parse(hm.group(2)!);
      if (m > 59) return null;
      return Duration(hours: int.parse(hm.group(1)!), minutes: m);
    }
    final pre = _ci('^($_num) and a half ($_unit)\$').firstMatch(t);
    if (pre != null) {
      final n = _number(pre.group(1)!);
      return n == null ? null : _of(n + 0.5, pre.group(2)!);
    }
    final pieces = _pieceRe.allMatches(t).toList();
    if (pieces.isEmpty || pieces.length > 2) return null;
    var total = Duration.zero;
    int? last;
    for (final p in pieces) {
      final m = _ci(
              '^(?:($_num)\\s*($_unit)|(\\d+(?:\\.\\d+)?)([mhd]))\$')
          .firstMatch(p.group(0)!)!;
      final n = _number(m.group(1) ?? m.group(3)!);
      final unit = m.group(2) ?? m.group(4)!;
      if (n == null) return null;
      final r = _rank(unit);
      if (last != null && r >= last) return null;
      last = r;
      total += _of(n, unit);
      if (identical(p, pieces.first) &&
          t.substring(p.end).trimLeft().startsWith('and a half')) {
        total += _of(0.5, unit);
      }
    }
    return total;
  }

  /// "10 minutes", "1 hour 30 minutes", "2 days".
  static String describe(Duration d) {
    String n(int v, String u) => '$v $u${v == 1 ? '' : 's'}';
    if (d.inMinutes % 1440 == 0 && d.inMinutes >= 1440) {
      return n(d.inDays, 'day');
    }
    final h = d.inHours, m = d.inMinutes % 60;
    return [if (h > 0) n(h, 'hour'), if (m > 0 || h == 0) n(m, 'minute')]
        .join(' ');
  }

  // ---- relations around a duration ----

  static final _prefixRe = _ci(
      r'\b(in|within|after)(\s+the\s+next)?(?:\s+(?:about|around|roughly|approximately|approx|like|just|another))?\s*$');
  static final _suffixTimeRe = _ci(r"^(?:'s|s'|')?\s+time\b");
  static final _suffixNowRe =
      _ci(r'^\s+(?:from\s+now|later|from\s+here|hence)\b');
  static final _leadSuffixRe = _ci(
      r'^\s+(?:before(?:hand)?|ahead|early|earlier|prior)\b(?:\s+(?:it|that|the start))?');
  static final _lastingPrefixRe = _ci(
      r'\b(?:for|lasts?|lasting|takes?|runs?\s+for)(?:\s+(?:about|around))?\s*$');
  static final _everyPrefixRe = _ci(r'\bevery(?:\s+other)?\s*$');

  /// Deadline wording: "finish this within 10 minutes", "sometime within the
  /// next hour". Without it, "within" is the event being that close.
  static final _deadlineCue = _ci(
      r'\b(?:finish(?:ed)?|complete|submit|deliver|done|hand\s+in|turn\s+in|wrap(?:\s+(?:it|this|that))?\s+up)\b');
  static final _windowCue = _ci(
      r'\b(?:sometime|some\s+time|anytime|any\s+time|at\s+some\s+point|whenever)\b');

  /// Amounts in units the app doesn't schedule ("in 2 weeks", "in 30
  /// seconds", "3 months from now").
  static final _unsupportedUnitRe = _ci(
      '\\b(?:(?:in|within|after|every)(?:\\s+the\\s+next)?'
      '(?:\\s+(?:about|around|another|a\\s+few|a\\s+couple\\s+of|few|several))?'
      '\\s+(?:$_num\\s*(?:weeks?|wks?|fortnights?|months?|years?|yrs?|seconds?|secs?)|'
      '(?:weeks|months|years|seconds|a\\s+fortnight))\\b|'
      '$_num\\s*(?:weeks?|wks?|fortnights?|months?|years?|yrs?|seconds?|secs?)'
      "(?:'s)?\\s+(?:from\\s+now|later|time)\\b)");

  /// Repeats other than "daily"/"every day" (see RuleEngine.parseDaily):
  /// never a one-off at the first occurrence.
  static final _repeatRe = _ci(
      r'\bevery\s+(?:other\s+)?(?:week|weekday|weekend|month|year|morning|'
      r'afternoon|evening|night|hour|minute|other\s+day|'
      r'(?:mon|tues|wednes|thurs|fri|satur|sun)day)s?\b|'
      r'\b(?:weekly|monthly|yearly|annually|hourly|fortnightly|biweekly)\b');

  /// "before 5pm", "before Friday": the time is a deadline.
  static final _beforeAnchor = _ci(
      r'\bbefore\s+(?=(?:\d|noon\b|midnight\b|tonight\b|tomorrow\b|today\b|the\s+\d|'
      r'(?:mon|tues|wednes|thurs|fri|satur|sun)day\b|'
      r'(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b))');
  static final _byAnchor = _ci(
      r'\bby\s+(?=(?:\d{1,2}(?::\d{2})?\s*(?:am|pm)\b|noon\b|tonight\b|tomorrow\b|today\b|'
      r'(?:mon|tues|wednes|thurs|fri|satur|sun)day\b))');

  /// Every time phrase in [text], resolved against [now] (the turn's
  /// submission instant). Two phrases naming different times are a
  /// conflict, never "the first one wins". [text] keeps its casing in rest.
  static TemporalReading read(String text, DateTime now) {
    if (_unsupportedUnitRe.hasMatch(text) || _repeatRe.hasMatch(text)) {
      // "in 2 weeks at 5pm", "every week at 5pm": never just the clock part.
      return TemporalReading._(TemporalStatus.unsupported, rest: text);
    }
    var rest = text;
    final spans = <TemporalSpan>[];
    final offsets = <({Duration d, bool days, TemporalSpan span})>[];
    Duration? lead, length;
    var lastingAt = -1, lastingEnd = -1;
    var recurring = false;

    // Durations, right to left so earlier indices stay valid while cutting.
    final found =
        <({int start, int end, Duration d, bool days, bool offset})>[];
    bool isDays(int start, int end) =>
        RegExp(r'\bdays?\b|\dd\b', caseSensitive: false)
            .hasMatch(text.substring(start, end));
    for (final m in _durRe.allMatches(text)) {
      final d = _value(m.group(0)!);
      if (d != null) {
        found.add((
          start: m.start,
          end: m.end,
          d: d,
          days: isDays(m.start, m.end),
          offset: false
        ));
        continue;
      }
      // "in 1 hour and 2 hours": two amounts, never only the first. Both
      // are times from now when the phrase is, so they disagree (below).
      final timed = _prefixRe.hasMatch(text.substring(0, m.start)) ||
          _suffixNowRe.hasMatch(text.substring(m.end));
      for (final p in _pieceRe.allMatches(text.substring(0, m.end), m.start)) {
        final v = _value(p.group(0)!);
        if (v == null) continue;
        found.add((
          start: p.start,
          end: p.end,
          d: v,
          days: isDays(p.start, p.end),
          offset: timed
        ));
      }
    }
    for (final f in found.reversed) {
      final before = text.substring(0, f.start);
      var after = text.substring(f.end);
      var end = f.end;
      final t = _suffixTimeRe.firstMatch(after);
      if (t != null) {
        end += t.end;
        after = after.substring(t.end);
      }
      final pre = _prefixRe.firstMatch(before);
      final now0 = _suffixNowRe.firstMatch(after);
      final leadM = _leadSuffixRe.firstMatch(after);
      if (pre != null || now0 != null || f.offset) {
        final start = pre?.start ?? f.start;
        if (now0 != null) end += now0.end;
        final words = text.substring(start, end).trim();
        final within = pre != null &&
            (pre.group(1)!.toLowerCase() == 'within' || pre.group(2) != null);
        final deadline =
            within && (_deadlineCue.hasMatch(text) || _windowCue.hasMatch(text));
        final span = TemporalSpan(
            words,
            within ? TemporalRelation.within : TemporalRelation.offset,
            deadline ? TemporalRole.deadline : TemporalRole.eventStart,
            f.d);
        offsets.insert(0, (d: f.d, days: f.days, span: span));
        spans.insert(0, span);
        rest = rest.replaceRange(start, end, ' ');
      } else if (leadM != null) {
        end += leadM.end;
        lead = f.d;
        spans.insert(
            0,
            TemporalSpan(text.substring(f.start, end).trim(),
                TemporalRelation.before, TemporalRole.alert, f.d));
        rest = rest.replaceRange(f.start, end, ' ');
      } else if (_everyPrefixRe.hasMatch(before)) {
        recurring = true;
        spans.insert(
            0,
            TemporalSpan(text.substring(f.start, end).trim(),
                TemporalRelation.every, TemporalRole.recurrence, f.d));
      } else {
        final l = _lastingPrefixRe.firstMatch(before);
        if (l != null && length == null) {
          // Only an event length when the start is also given (below).
          length = f.d;
          lastingAt = l.start;
          lastingEnd = end;
        }
      }
    }
    if (offsets.any((o) => o.span.role == TemporalRole.deadline)) {
      rest = rest.replaceFirst(_windowCue, ' '); // "sometime within…"
    }
    if (recurring) {
      // "every 2 hours" repeats: never a one-off at the first interval.
      return TemporalReading._(TemporalStatus.unsupported,
          rest: text, spans: spans);
    }

    var role = TemporalRole.eventStart;
    TemporalRelation? anchorRel;
    final b = _beforeAnchor.firstMatch(rest);
    if (b != null) {
      rest = rest.replaceRange(b.start, b.end, ' ');
      role = TemporalRole.deadline;
      anchorRel = TemporalRelation.before;
    } else if (_byAnchor.hasMatch(rest)) {
      role = TemporalRole.deadline;
      anchorRel = TemporalRelation.by;
    }
    final cal = _calendar(rest, now);
    if (cal.invalid) {
      // "on 30 February", "at 13pm": never the other, valid part alone.
      return TemporalReading._(TemporalStatus.unsupported,
          rest: text, spans: spans, lead: lead);
    }
    final calFound = cal.conflict || cal.at != null;
    if (calFound) {
      for (final w in cal.words) {
        spans.add(
            TemporalSpan(w, anchorRel ?? TemporalRelation.calendar, role));
      }
    }
    TemporalReading clash() => TemporalReading._(TemporalStatus.conflict,
        rest: text, spans: spans, lead: lead);

    if (offsets.length > 1) return clash();
    if (cal.conflict) return clash();
    DateTime? at;
    String? note;
    var dated = cal.dated, timed = cal.timed;
    if (offsets.length == 1) {
      final o = offsets.single;
      role = o.span.role;
      final today = DateTime(now.year, now.month, now.day);
      if (!calFound) {
        at = now.add(o.d);
      } else if (o.days && cal.timed && !cal.dated) {
        // "in 2 days at 5pm": the day from the offset, the time as said.
        final day = today.add(Duration(days: o.d.inDays));
        at = DateTime(
            day.year, day.month, day.day, cal.at!.hour, cal.at!.minute);
        note = cal.note;
      } else if (cal.dated && !cal.timed && cal.day == today && !o.days) {
        at = now.add(o.d); // "today in 2 hours"
      } else {
        return clash(); // "in 10 minutes at 9", "tomorrow in an hour"
      }
      rest = cal.at == null ? rest : cal.rest;
      dated = timed = true;
      if (o.span.relation == TemporalRelation.within &&
          role == TemporalRole.eventStart) {
        note = 'I read "${o.span.text}" as ${describe(o.d)} from now.';
      }
    } else if (calFound) {
      at = cal.at;
      note = cal.note;
      rest = cal.rest;
    }
    if (at == null) {
      return TemporalReading._(TemporalStatus.none,
          rest: text, spans: spans, lead: lead);
    }
    if (length != null && lastingAt >= 0) {
      // Cut from the result text only if those words are still in it.
      final words = text.substring(lastingAt, lastingEnd);
      final i = rest.indexOf(words);
      if (i >= 0) {
        rest = rest.replaceRange(i, i + words.length, ' ');
        spans.add(TemporalSpan(words.trim(), TemporalRelation.lasting,
            TemporalRole.eventEnd, length));
      } else {
        length = null;
      }
    } else {
      length = null;
    }
    return TemporalReading._(TemporalStatus.resolved,
        at: at,
        role: role,
        rest: _squash(rest),
        note: note,
        dated: dated,
        timed: timed,
        spans: spans,
        lead: lead,
        length: length);
  }

  // ---- calendar days and clock times ----

  static final clockRe = RegExp(
      r'\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b|\b(?:at\s+|(?=\d{1,2}:\d{2}\b))(\d{1,2})(?::(\d{2}))?\b|\b(?:at\s+)?(noon)\b',
      caseSensitive: false);

  static String clockLabel(int h, int m) =>
      '${h % 12 == 0 ? 12 : h % 12}${m == 0 ? '' : ':${m.toString().padLeft(2, '0')}'} '
      '${h < 12 ? 'AM' : 'PM'}';

  static String _squash(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

  static final _slangDay =
      _ci(r'\b(?:tomo|tmrw|tmr|tmrrw|2moro|2mrw|tomorow|tommorow|tommorrow)\b');

  /// A named day and/or clock time (the original calendar parser).
  /// [words] are the phrases used, for questions about a conflict.
  static ({
    DateTime? at,
    String rest,
    String? note,
    bool dated,
    bool timed,
    bool conflict,
    DateTime? day,
    List<String> words,
    bool invalid
  }) _calendar(String text, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final none = (
      at: null,
      rest: text,
      note: null,
      dated: false,
      timed: false,
      conflict: false,
      day: null,
      words: const <String>[],
      invalid: false
    );
    final invalid = (
      at: null,
      rest: text,
      note: null,
      dated: false,
      timed: false,
      conflict: false,
      day: null,
      words: const <String>[],
      invalid: true
    );
    var rest = text.replaceAll(_slangDay, 'tomorrow');
    final used = <String>[];
    int? part;
    String? partName;
    final found = _dateIn(rest, now, onLead);
    // Impossible, out-of-range or ambiguous dates: unsupported, so callers
    // ask. Two named days that disagree ("tomorrow Friday"): a conflict.
    if (found.problem == _DateProblem.invalid) return invalid;
    if (found.problem == _DateProblem.conflict) {
      return (
        at: null,
        rest: text,
        note: null,
        dated: false,
        timed: false,
        conflict: true,
        day: null,
        words: found.days,
        invalid: false
      );
    }
    final date = found.date;
    if (found.words.isNotEmpty) used.add(found.words);
    rest = found.rest;
    if (found.tonight) (part, partName) = (20, 'tonight');
    for (final e in {'morning': 9, 'afternoon': 15, 'evening': 19}.entries) {
      final re = _ci('\\b(?:in (?:the )?|this )?${e.key}\\b');
      final pm = re.firstMatch(rest);
      if (pm != null) {
        (part, partName) = (e.value, e.key);
        used.add(pm.group(0)!.trim());
        rest = rest.replaceFirst(re, '');
      }
    }
    int? h, min;
    String? note;
    clash() => (
          at: null,
          rest: text,
          note: null,
          dated: false,
          timed: false,
          conflict: true,
          day: null,
          words: List.of(used),
          invalid: false
        );
    final m = clockRe.firstMatch(rest);
    if (m != null) {
      if (m.group(6) != null) {
        (h, min) = (12, 0);
      } else if (m.group(1) != null) {
        h = int.parse(m.group(1)!);
        min = int.parse(m.group(2) ?? '0');
        if (h < 1 || h > 12) return invalid; // 0am, 13pm
        h = h % 12 + (m.group(3)!.toLowerCase() == 'pm' ? 12 : 0);
      } else {
        h = int.parse(m.group(4)!);
        min = int.parse(m.group(5) ?? '0');
        // bare "at 7": afternoon/evening/tonight mean PM; with no part of
        // day, today after 7 AM passed means the evening one.
        if (h >= 1 &&
            h < 12 &&
            (part != null
                ? part >= 12
                : (date == null || date == today) &&
                    DateTime(now.year, now.month, now.day, h, min)
                        .isBefore(now))) {
          h += 12;
          if (part == null) note = 'I took that as ${clockLabel(h, min)}.';
        }
      }
      if (h > 23 || min > 59) return invalid;
      used.add(m.group(0)!.trim());
      // An explicit clock wins over the part-of-day default, but must agree.
      if (part != null &&
          (part == 9
              ? h >= 12
              : part == 15
                  ? h < 12 || h >= 18
                  : h < 17)) {
        return clash();
      }
      rest = rest.replaceFirst(m.group(0)!, '');
      // Two clock times ("8:10 … 9pm"): ask, never pick one.
      final second = clockRe.firstMatch(rest);
      if (second != null) {
        used.add(second.group(0)!.trim());
        return clash();
      }
    }
    if (h == null && part != null) {
      h = part;
      note = '${partName![0].toUpperCase()}${partName.substring(1)} means '
          '${clockLabel(part, 0)} unless you say otherwise.';
    }
    if (h == null && date == null) return none;
    final timed = h != null;
    final day = date ?? today;
    if (h == null) {
      // A day alone: 9 AM, or the next full hour when that already passed today.
      h = day == today && now.hour >= 9 ? now.hour + 1 : 9;
      if (h > 23) return none;
      note = "I used ${clockLabel(h, 0)} since you didn't give a time.";
    }
    return (
      at: DateTime(day.year, day.month, day.day, h, min ?? 0),
      rest: _squash(rest),
      note: note,
      dated: date != null,
      timed: timed,
      conflict: false,
      day: day,
      words: used,
      invalid: false
    );
  }

  static const _months = '(january|february|march|april|may|june|july|august|'
      'september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|'
      'sep|oct|nov|dec)';
  static const onLead = r'\b(?:on\s+)?';
  static const untilLead =
      r'\b(?:until|till|til|ending(?:\s+on)?)\s+(?:on\s+)?';
  static final _relWeekday = _ci(
      r'\b(?:next|last|coming)\s+(?:mon|tues|wednes|thurs|fri|satur|sun)day\b');

  /// The calendar day named in [text] after [lead]: today/tomorrow/tonight,
  /// a weekday (the next one, today included), "5 November"/"Nov 5th"
  /// (optionally with a year) or ISO 2026-11-05. A named date without a year
  /// is this year's, even if past (callers ask; never rolled into next year).
  /// Null when a date is impossible ("30 February"), its year is out of range,
  /// "Nov 5 Dec"-style ambiguous, or two named days disagree.
  static ({DateTime? date, String rest, bool tonight, String words})? dateIn(
      String text, DateTime now, String lead) {
    final r = _dateIn(text, now, lead);
    return r.problem != null
        ? null
        : (date: r.date, rest: r.rest, tonight: r.tonight, words: r.words);
  }

  static ({
    DateTime? date,
    String rest,
    bool tonight,
    String words,
    _DateProblem? problem,
    List<String> days
  }) _dateIn(String text, DateTime now, String lead) {
    ({
      DateTime? date,
      String rest,
      bool tonight,
      String words,
      _DateProblem? problem,
      List<String> days
    }) fail(_DateProblem p, [List<String> days = const []]) => (
          date: null,
          rest: text,
          tonight: false,
          words: '',
          problem: p,
          days: days
        );
    final today = DateTime(now.year, now.month, now.day);
    var rest = text;
    final days = <DateTime>[];
    final words = <String>[];
    var tonight = false;
    var bad = false;
    RegExpMatch? take(String p) {
      final m = _ci('$lead$p').firstMatch(rest);
      if (m != null) {
        rest = rest.replaceFirst(m.group(0)!, ' ');
        words.add(m.group(0)!.trim());
      }
      return m;
    }

    void add(int y, int mo, int d) {
      final day = DateTime(y, mo, d);
      // DateTime normalizes 30 Feb to 2 Mar: an impossible date is refused.
      if (y < now.year - 1 ||
          y > now.year + 100 ||
          day.month != mo ||
          day.day != d) {
        bad = true;
      } else {
        days.add(day);
      }
    }

    int month(String s) =>
        const [
          'jan',
          'feb',
          'mar',
          'apr',
          'may',
          'jun',
          'jul',
          'aug',
          'sep',
          'oct',
          'nov',
          'dec'
        ].indexOf(s.toLowerCase().substring(0, 3)) +
        1;
    int year(String? s) => s == null ? now.year : int.parse(s);

    final iso = take(r'(\d{4})-(\d{2})-(\d{2})\b');
    if (iso != null) {
      add(int.parse(iso.group(1)!), int.parse(iso.group(2)!),
          int.parse(iso.group(3)!));
    }
    const dmP =
        '(?:the\\s+)?(\\d{1,2})(?:st|nd|rd|th)?(?:\\s+of)?\\s+$_months\\b\\.?'
        '(?:,?\\s+(\\d{4})\\b)?';
    const mdP =
        '$_months\\.?\\s+(?:the\\s+)?(\\d{1,2})(?:st|nd|rd|th)?\\b(?:,?\\s+(\\d{4})\\b)?';
    // "10 Nov 5": which number is the day?
    if (_ci('$lead$dmP').hasMatch(rest) && _ci('$lead$mdP').hasMatch(rest)) {
      return fail(_DateProblem.invalid);
    }
    final dm = take(dmP);
    final md = take(mdP);
    if (dm != null) {
      add(year(dm.group(3)), month(dm.group(2)!), int.parse(dm.group(1)!));
    }
    if (md != null) {
      add(year(md.group(3)), month(md.group(1)!), int.parse(md.group(2)!));
    }
    for (final (word, offset) in [
      ('tomorrow', 1),
      ('today', 0),
      ('tonight', 0)
    ]) {
      if (take('$word\\b') != null) {
        days.add(DateTime(today.year, today.month, today.day + offset));
        if (word == 'tonight') tonight = true;
      }
    }
    // "next Friday" is left for the caller to ask about.
    final wd = _relWeekday.hasMatch(rest)
        ? null
        : take(r'(?:this\s+)?(mon|tues|wednes|thurs|fri|satur|sun)day\b');
    int? weekday;
    if (wd != null) {
      weekday = const ['mon', 'tues', 'wednes', 'thurs', 'fri', 'satur', 'sun']
              .indexOf(wd.group(1)!.toLowerCase()) +
          1;
      if (days.isEmpty) {
        days.add(DateTime(today.year, today.month,
            today.day + (weekday - today.weekday) % 7));
      }
    }
    if (bad) return fail(_DateProblem.invalid);
    if (days.any((d) => d != days.first) ||
        (weekday != null && days.first.weekday != weekday)) {
      return fail(_DateProblem.conflict, words);
    }
    return (
      date: days.isEmpty ? null : days.first,
      rest: rest,
      tonight: tonight,
      words: words.join(' '),
      problem: null,
      days: words
    );
  }
}

enum _DateProblem { invalid, conflict }
