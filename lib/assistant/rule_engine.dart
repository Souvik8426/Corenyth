import 'dart:convert';

import 'engine.dart';

/// Deterministic offline "model": regex intent parsing that emits the same JSON
/// the LLM is asked to emit, so everything downstream (validation, execution)
/// is identical. Used as the text-first core and as fallback when the LLM
/// output is malformed or unavailable.
class RuleEngine implements LlmEngine {
  final DateTime Function() clock;
  RuleEngine({DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  @override
  String get name => 'rules';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async {}

  @override
  Future<String> complete(Prompt p) async =>
      jsonEncode(p.kind == PromptKind.memory ? extractMemory(p.user) : plan(p.user));

  static Map<String, Object?> _tool(String t, Map<String, Object?> a) =>
      {'type': 'tool', 'tool': t, 'arguments': a};
  static Map<String, Object?> _say(String s) => {'type': 'respond', 'text': s};

  static final _clockRe =
      RegExp(r'\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b|\bat\s+(\d{1,2})(?::(\d{2}))?\b');
  static final _inRe = RegExp(r'\bin\s+(\d+)\s*(minute|min|hour|hr|day)s?\b');

  /// Finds a date/time phrase; returns it plus the text with the phrase removed.
  (DateTime?, String) _when(String text) {
    final now = clock();
    var day = DateTime(now.year, now.month, now.day);
    var rest = text;
    final rel = _inRe.firstMatch(rest);
    if (rel != null) {
      final n = int.parse(rel.group(1)!);
      final u = rel.group(2)!;
      final d = u.startsWith('min')
          ? Duration(minutes: n)
          : u.startsWith('h')
              ? Duration(hours: n)
              : Duration(days: n);
      return (now.add(d), rest.replaceFirst(rel.group(0)!, '').trim());
    }
    var hasDay = false, partOfDay = -1;
    for (final w in {'tomorrow': 1, 'today': 0, 'tonight': 0}.entries) {
      if (RegExp('\\b${w.key}\\b').hasMatch(rest)) {
        day = day.add(Duration(days: w.value));
        rest = rest.replaceFirst(RegExp('\\b${w.key}\\b'), '');
        hasDay = true;
        if (w.key == 'tonight') partOfDay = 20;
      }
    }
    for (final e in {'morning': 9, 'afternoon': 15, 'evening': 19}.entries) {
      final re = RegExp('\\b(?:in the )?${e.key}\\b');
      if (re.hasMatch(rest)) {
        partOfDay = e.value;
        rest = rest.replaceFirst(re, '');
      }
    }
    final m = _clockRe.firstMatch(rest);
    int? h, min;
    if (m != null) {
      if (m.group(1) != null) {
        h = int.parse(m.group(1)!) % 12 + (m.group(3) == 'pm' ? 12 : 0);
        min = int.parse(m.group(2) ?? '0');
      } else {
        h = int.parse(m.group(4)!);
        min = int.parse(m.group(5) ?? '0');
        // bare "at 7": assume the next occurrence (7 -> 19 if 07:00 already passed)
        if (h < 12 && day.add(Duration(hours: h, minutes: min)).isBefore(now)) h += 12;
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

  Map<String, Object?> plan(String raw) {
    final text = raw.trim().replaceAll(RegExp(r'[.!?]+$'), '');
    final t = text.toLowerCase();
    RegExpMatch? m;

    m = RegExp(r'^remind me\s+(.*)$').firstMatch(t);
    if (m != null) {
      final (at, rest) = _when(m.group(1)!);
      final title = rest.replaceFirst(RegExp(r'^(to|about|that)\s+'), '').replaceFirst(RegExp(r'\s+(to|at|on)$'), '');
      if (at == null || title.isEmpty) {
        return _say('When should I remind you, and about what?');
      }
      return _tool('create_reminder', {'title': title, 'at': at.toIso8601String()});
    }
    m = RegExp(r'^(?:add|create|new)\s+(?:a\s+)?task:?\s+(.+)$').firstMatch(t);
    if (m != null) {
      final (at, rest) = _when(m.group(1)!);
      final title = rest.replaceFirst(RegExp(r'^to\s+'), '');
      return _tool('create_task', {
        'title': title.isEmpty ? m.group(1)! : title,
        if (at != null) 'due': at.toIso8601String(),
      });
    }
    m = RegExp(r'\b(complete|finish|done with|mark)\s+task\s+#?(\d+)').firstMatch(t);
    if (m != null) return _tool('complete_task', {'id': int.parse(m.group(2)!)});
    m = RegExp(r'\b(?:delete|remove)\s+task\s+#?(\d+)').firstMatch(t);
    if (m != null) return _tool('delete_task', {'id': int.parse(m.group(1)!)});
    m = RegExp(r'\bcancel\s+reminder\s+#?(\d+)').firstMatch(t);
    if (m != null) return _tool('cancel_reminder', {'id': int.parse(m.group(1)!)});

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
      });
    }

    if (RegExp(r'^(what|when|who|where|how).*\b(did i tell you|do you know|do you remember|normally|usually|about)\b')
        .hasMatch(t)) {
      return _tool('search_memory', {'query': text});
    }
    if (t.startsWith('remember')) return _say("Okay, I'll remember that.");
    return _say('I can manage tasks and reminders and remember things for you.');
  }

  static final _fact = RegExp(
      r"^i\s+(?:(?:usually|normally|always|never|really)\s+)?(?:am|'m|work|live|prefer|like|love|hate|dislike|need|use|go|have|study)\b");

  Map<String, Object?> extractMemory(String raw) {
    final text = raw.trim().replaceAll(RegExp(r'[.!?]+$'), '');
    final t = text.toLowerCase();
    final r = RegExp(r'^(?:please\s+)?remember(?:\s+that)?\s+(.+)$').firstMatch(text);
    if (r != null) {
      return {'remember': true, 'memory': r.group(1)!, 'category': 'fact'};
    }
    if (_fact.hasMatch(t)) {
      final rest = text.substring(2).trim().replaceFirst(RegExp(r"^('m|am)\b"), 'is');
      return {
        'remember': true,
        'memory': 'User $rest',
        'category': RegExp(r'prefer|like|love|hate|usually|normally|always|never').hasMatch(t)
            ? 'preference'
            : 'fact',
      };
    }
    return {'remember': false};
  }
}
