import 'dart:convert';

import 'engine.dart';

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

  static final _clockRe = RegExp(
      r'\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b|\bat\s+(\d{1,2})(?::(\d{2}))?\b',
      caseSensitive: false);
  static final _inRe = RegExp(r'\bin\s+(\d+)\s*(minute|min|hour|hr|day)s?\b',
      caseSensitive: false);

  /// Finds a date/time phrase; returns it plus the text with the phrase removed.
  (DateTime?, String) _when(String text) {
    final now = clock();
    var day = DateTime(now.year, now.month, now.day);
    var rest = text;
    final rel = _inRe.firstMatch(rest);
    if (rel != null) {
      final n = int.parse(rel.group(1)!);
      final u = rel.group(2)!.toLowerCase();
      final d = u.startsWith('min')
          ? Duration(minutes: n)
          : u.startsWith('h')
              ? Duration(hours: n)
              : Duration(days: n);
      return (now.add(d), rest.replaceFirst(rel.group(0)!, '').trim());
    }
    var hasDay = false, partOfDay = -1;
    for (final w in {'tomorrow': 1, 'today': 0, 'tonight': 0}.entries) {
      final re = _ci('\\b${w.key}\\b');
      if (re.hasMatch(rest)) {
        day = day.add(Duration(days: w.value));
        rest = rest.replaceFirst(re, '');
        hasDay = true;
        if (w.key == 'tonight') partOfDay = 20;
      }
    }
    for (final e in {'morning': 9, 'afternoon': 15, 'evening': 19}.entries) {
      final re = _ci('\\b(?:in the )?${e.key}\\b');
      if (re.hasMatch(rest)) {
        partOfDay = e.value;
        rest = rest.replaceFirst(re, '');
      }
    }
    final m = _clockRe.firstMatch(rest);
    int? h, min;
    if (m != null) {
      if (m.group(1) != null) {
        h = int.parse(m.group(1)!) % 12 + (m.group(3)!.toLowerCase() == 'pm' ? 12 : 0);
        min = int.parse(m.group(2) ?? '0');
      } else {
        h = int.parse(m.group(4)!);
        min = int.parse(m.group(5) ?? '0');
        // bare "at 7": assume the next occurrence (7 -> 19 if 07:00 already passed)
        if (h < 12 && day.add(Duration(hours: h, minutes: min)).isBefore(now))
          h += 12;
      }
      if (h > 23 || min > 59) return (null, text);
      rest = rest.replaceFirst(m.group(0)!, '');
    }
    if (h == null && partOfDay >= 0) h = partOfDay;
    if (h == null && !hasDay) return (null, text);
    var t = day.add(Duration(hours: h ?? 9, minutes: min ?? 0));
    if (!hasDay && t.isBefore(now)) t = t.add(const Duration(days: 1));
    return (t, rest.replaceAll(RegExp(r'\s+'), ' ').trim());
  }

  /// Date/time phrases [_when] does not understand. Left in a title they mean
  /// "ask / let the model try", never "store it in the title" or "guess a date".
  static final _unsupportedDate = RegExp(
      r'\b(?:mon|tues|wednes|thurs|fri|satur|sun)day\b|'
      r'\b(?:january|february|march|april|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)\b|'
      r'\b(?:next|this|last) (?:week|weekend|month|year)\b|\bweekend\b|'
      r'\bday after\b|\bnoon\b|\bmidnight\b|\btomorrow\b|\btoday\b|\btonight\b|'
      r'\b\d{1,2}(?:st|nd|rd|th)\b|\b\d{1,4}[/.-]\d{1,2}(?:[/.-]\d{1,4})?\b|'
      r'\bin (?:a|an|\d+) (?:weeks?|months?|years?)\b|\bat \d|\b\d{1,2}(?::\d{2})? ?(?:am|pm)\b',
      caseSensitive: false);

  /// Trimmed, end punctuation dropped, whitespace collapsed. Casing is kept so
  /// titles are stored as typed; every fast-route pattern is case-insensitive.
  static String _norm(String raw) => raw
      .trim()
      .replaceAll(RegExp(r'[.!?]+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ');

  static RegExp _ci(String p) => RegExp(p, caseSensitive: false);

  /// Negations and chained/alternative requests: never act on these directly.
  static final _unsafe = _ci(
      r"\b(?:not|don'?t|do not|never|no|isn'?t|wasn'?t|or|unless|but|instead)\b|"
      r'\b(?:and|then|also|after that|plus)\s+(?:then\s+|also\s+)?'
      r'(?:add|create|remind|delete|remove|complete|finish|mark|cancel|list|show|edit|rename|move)\b|[;?]');

  static final _greetRe = _ci(
      r"^(?:hi|hello|hey|hiya|yo|good (?:morning|afternoon|evening)|thanks|thank you|thx)(?: there| corenyth)?$");

  static final _listRe = RegExp(
      r'^(?:(?:what|which) (?:are )?(?:my )?(?:tasks|to-?dos)(?: do i have)?|'
      r'(?:list|show)(?: me)?(?: my| all)? (?:tasks|to-?dos)|(?:my )?(?:tasks|to-?dos))'
      r'(?: (?:for |due )?(today|tomorrow))?$',
      caseSensitive: false);

  /// Strict deterministic route: only complete, anchored, unambiguous commands.
  /// Returns the tool-call map, or null so the text goes to the model.
  Map<String, Object?>? fastRoute(String raw) {
    final t = _norm(raw);
    RegExpMatch? m;
    if ((m = _greetRe.firstMatch(t)) != null) {
      return _say(RegExp(r'^th', caseSensitive: false).hasMatch(t)
          ? "You're welcome! Anything else I can help with?"
          : 'Hi! How can I help?');
    }
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
    if (_unsafe.hasMatch(t)) return null;
    if ((m = _ci(r'^remind me (.+)$').firstMatch(t)) != null) {
      final (at, rest) = _when(m!.group(1)!);
      final title = rest
          .replaceFirst(_ci(r'^(to|about|that)\s+'), '')
          .replaceFirst(_ci(r'\s+(to|at|on)$'), '');
      if (at == null || title.isEmpty || _unsupportedDate.hasMatch(title)) {
        return null;
      }
      return _tool(
          'create_reminder', {'title': title, 'at': at.toIso8601String()});
    }
    if ((m = _ci(r'^(?:add|create|new) (?:a )?task:? (.+)$').firstMatch(t)) !=
        null) {
      final (at, rest) = _when(m!.group(1)!);
      final title = rest.replaceFirst(_ci(r'^to\s+'), '');
      if (title.isEmpty || _unsupportedDate.hasMatch(title)) return null;
      return _tool('create_task',
          {'title': title, if (at != null) 'due': at.toIso8601String()});
    }
    if ((m = _ci(
                r'^(?:complete|finish|mark)(?: the)? task (.+?)(?: as)?(?: done| complete| completed)?$')
            .firstMatch(t)) !=
        null) {
      return _ref('complete_task', m!.group(1)!);
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
    if ((m = _ci(r'^(?:move|reschedule|change)(?: the| my)? reminder (.+?) to (.+)$')
            .firstMatch(t)) !=
        null) {
      final (at, rest) = _when(m!.group(2)!);
      if (at == null || rest.isNotEmpty) return null;
      return _tool('edit_reminder',
          {..._sel(m.group(1)!, 'target_title'), 'at': at.toIso8601String()});
    }
    return null;
  }

  /// `#3` / `3` -> id, anything else -> exact title (resolved against the DB later).
  static Map<String, Object?> _ref(String tool, String s) =>
      _tool(tool, _sel(s, 'title'));

  static Map<String, Object?> _sel(String s, String titleKey) {
    final id = RegExp(r'^#?(\d+)$').firstMatch(s);
    return id != null ? {'id': int.parse(id.group(1)!)} : {titleKey: s};
  }

  /// Rule "model": [fastRoute] plus loose fallbacks for when the LLM is
  /// unavailable or produced invalid output.
  Map<String, Object?> plan(String raw) {
    final fast = fastRoute(raw);
    if (fast != null) return fast;
    final text = raw.trim().replaceAll(RegExp(r'[.!?]+$'), '');
    final t = text.toLowerCase();
    if (t.startsWith('remind me')) {
      return _say(
          "I couldn't work out when, or what about. Try e.g. \"remind me tomorrow at 8 to call Mom\".");
    }
    if (RegExp(r'^(?:add|create|new)\s+(?:a\s+)?task\b').hasMatch(t)) {
      return _say(
          "I didn't add that: I couldn't understand the task or its date. I understand today, tomorrow, tonight, \"in 3 days\" and times like 5pm.");
    }
    if (RegExp(r'\b(tasks?|to-?dos?|to do)\b').hasMatch(t) &&
        RegExp(r'^(what|which|list|show|do i|any)').hasMatch(t)) {
      final now = clock();
      final today = DateTime(now.year, now.month, now.day);
      DateTime? from, to;
      if (t.contains('tomorrow')) {
        from = today.add(const Duration(days: 1));
        to = today.add(const Duration(days: 2));
      } else if (t.contains('today')) {
        from = today;
        to = today.add(const Duration(days: 1));
      }
      return _tool('list_tasks', {
        if (from != null) 'from': from.toIso8601String(),
        if (to != null) 'to': to.toIso8601String(),
        if (from == null && to == null) 'include_done': true,
      });
    }

    if (RegExp(
            r'^(what|when|who|where|how).*\b(did i tell you|do you know|do you remember|normally|usually|about)\b')
        .hasMatch(t)) {
      return _tool('search_memory', {'query': text});
    }
    // Only the strict fastRoute above may emit mutations; past here the rules
    // answer read-only questions or explain, never act on unanchored text.
    if (RegExp(r'\b(?:complete|finish|mark|delete|remove|cancel|edit|rename|change|move)\b')
        .hasMatch(t)) {
      return _say(
          "I didn't change anything: I couldn't tell exactly what you meant. Try e.g. \"delete task 3\" or \"complete task buy milk\".");
    }
    if (isExplicitRemember(t)) return _say("Okay, I'll remember that.");
    return _say(
        'I can manage tasks and reminders and remember things for you.');
  }

  static final _fact = RegExp(
      r"^i\s+(?:(?:usually|normally|always|never|really)\s+)?(?:am|'m|work|live|prefer|like|love|hate|dislike|need|use|go|have|study)\b");

  /// "remember (that) X" — but not "remember to X", which is a task/reminder.
  static bool isExplicitRemember(String text) =>
      RegExp(r'^(?:please\s+)?remember(?:\s+that)?\s+(?!to\b)\S',
              caseSensitive: false)
          .hasMatch(text.trim());

  Map<String, Object?> extractMemory(String raw) {
    final text = raw.trim().replaceAll(RegExp(r'[.!?]+$'), '');
    final t = text.toLowerCase();
    final r = RegExp(r'^(?:please\s+)?remember(?:\s+that)?\s+(.+)$',
            caseSensitive: false)
        .firstMatch(text);
    if (r != null) {
      final inner = extractMemory(r.group(1)!); // "remember I like tea" -> "User likes tea"
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
