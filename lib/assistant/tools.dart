import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/repos.dart';
import '../services/reminder_scheduler.dart';

class ToolError implements Exception {
  final String message;
  ToolError(this.message);
  @override
  String toString() => message;
}

class ToolCall {
  final String tool;
  final Map<String, Object?> args;
  ToolCall(this.tool, this.args);
}

/// Per-tool argument schema: name -> type char, trailing `!` = required.
/// s=string i=int d=ISO-8601 datetime b=bool
const toolSchemas = <String, Map<String, String>>{
  'create_task': {'title': 's!', 'notes': 's', 'due': 'd', 'priority': 'i'},
  // Exactly one selector: an id, or the exact current title (`target_title` for
  // edits, so it never mixes with the replacement `title`). See [_selector].
  'edit_task': {'id': 'i', 'target_title': 's', 'title': 's', 'notes': 's', 'due': 'd', 'priority': 'i'},
  'complete_task': {'id': 'i', 'title': 's'},
  'delete_task': {'id': 'i', 'title': 's'},
  'list_tasks': {'from': 'd', 'to': 'd', 'include_done': 'b'},
  'create_reminder': {'title': 's!', 'at': 'd!', 'task_id': 'i'},
  'edit_reminder': {'id': 'i', 'target_title': 's', 'title': 's', 'at': 'd'},
  'cancel_reminder': {'id': 'i', 'title': 's'},
  'search_memory': {'query': 's!'},
  'respond': {'text': 's!'},
};

/// GBNF: non-empty JSON string (no raw control chars, standard escapes).
const jsonStrRule = r'str ::= "\"" ([^"\\\x7F\x00-\x1F] | "\\" ["\\/bfnrt])+ "\""';

/// GBNF grammar (llama.cpp) generated from [toolSchemas]: the model can only emit
/// one JSON object with a known tool, its required args, and correctly typed values
/// (priority 0..2, ISO datetimes, positive ids). Validation still runs afterwards.
final String toolGrammar = () {
  String lit(String s) => '"${s.replaceAll('"', r'\"')}"';
  String kv(String key, String type) {
    final v = switch (type[0]) {
      'i' => key == 'priority' ? '[0-2]' : 'id',
      'd' => 'datetime',
      'b' => '("true" | "false")',
      _ => 'str',
    };
    return '${lit('"$key":')} $v';
  }

  final rules = <String>[];
  final alts = <String>[];
  for (final t in toolSchemas.entries.where((e) => e.key != 'respond')) {
    final req = [for (final e in t.value.entries) if (e.value.endsWith('!')) kv(e.key, e.value)];
    final opt = [for (final e in t.value.entries) if (!e.value.endsWith('!')) kv(e.key, e.value)];
    String args;
    if (req.isNotEmpty) {
      args = [req.join(' "," '), for (final o in opt) '("," $o)?'].join(' ');
    } else {
      // all optional: any subset in order, without a leading comma
      final starts = [
        for (var i = 0; i < opt.length; i++)
          [opt[i], for (final o in opt.skip(i + 1)) '("," $o)?'].join(' ')
      ];
      args = '(${starts.join(' | ')})?';
    }
    final name = 'tool-${t.key.replaceAll('_', '-')}';
    rules.add('$name ::= ${lit('"${t.key}","arguments":{')} $args "}"');
    alts.add(name);
  }
  return [
    'root ::= ${lit('{"type":"respond","text":')} str "}" | ${lit('{"type":"tool","tool":')} (${alts.join(' | ')}) "}"',
    ...rules,
    jsonStrRule,
    r'id ::= [1-9] [0-9]{0,6}',
    r'datetime ::= "\"" [0-9]{4} "-" [0-9]{2} "-" [0-9]{2} "T" [0-9]{2} ":" [0-9]{2} ":" [0-9]{2} "\""',
  ].join('\n');
}();

/// First balanced JSON object in raw model output (tolerates `<think>`
/// blocks, code fences and chatter). Throws [ToolError] if none/invalid.
Map<String, Object?> extractJsonObject(String raw) {
  raw = raw.replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '');
  final start = raw.indexOf('{');
  if (start < 0) throw ToolError('no JSON object in output');
  var depth = 0, inStr = false, esc = false, end = -1;
  for (var i = start; i < raw.length && end < 0; i++) {
    final c = raw[i];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (c == r'\') {
        esc = true;
      } else if (c == '"') {
        inStr = false;
      }
    } else if (c == '"') {
      inStr = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}' && --depth == 0) {
      end = i;
    }
  }
  if (end < 0) throw ToolError('unterminated JSON');
  try {
    final j = jsonDecode(raw.substring(start, end + 1));
    if (j is Map) return Map<String, Object?>.from(j);
  } on FormatException catch (e) {
    throw ToolError('invalid JSON: ${e.message}');
  }
  throw ToolError('JSON is not an object');
}

/// Parses + validates a tool call. Throws [ToolError] on anything malformed;
/// callers must NOT execute in that case.
ToolCall parseToolCall(String raw) {
  final j = extractJsonObject(raw);
  switch (j['type']) {
    case 'respond':
      return ToolCall('respond', _validate('respond', {'text': j['text']}));
    case 'tool':
      final tool = j['tool'], a = j['arguments'];
      if (tool is! String || tool == 'respond' || !toolSchemas.containsKey(tool)) {
        throw ToolError('unknown tool: $tool');
      }
      if (a is! Map) throw ToolError('$tool: "arguments" must be an object');
      return ToolCall(tool, _validate(tool, Map<String, Object?>.from(a)));
  }
  throw ToolError('"type" must be "tool" or "respond"');
}

/// Tool -> its title selector key; the call needs exactly one of `id` or it.
const _selector = {
  'complete_task': 'title',
  'delete_task': 'title',
  'cancel_reminder': 'title',
  'edit_task': 'target_title',
  'edit_reminder': 'target_title',
};
const _priorityWords = {'low': 0, 'normal': 1, 'medium': 1, 'high': 2};

final _isoRe = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.\d{1,6})?)?$');

/// Local `YYYY-MM-DDTHH:MM[:SS[.fff]]` that names a real calendar instant.
/// DateTime() silently normalizes (Feb 30 -> Mar 2, 25:00 -> next day), so the
/// fields are rebuilt and compared. Zone suffixes are rejected (times are local).
DateTime? parseLocalDateTime(String s) {
  final m = _isoRe.firstMatch(s.trim());
  if (m == null) return null;
  final f = [for (var i = 1; i <= 6; i++) int.parse(m.group(i) ?? '0')];
  final d = DateTime(f[0], f[1], f[2], f[3], f[4], f[5]);
  if (d.year != f[0] || d.month != f[1] || d.day != f[2] ||
      d.hour != f[3] || d.minute != f[4] || d.second != f[5]) {
    return null; // also catches DST-gap hours that don't exist locally
  }
  return d;
}

Map<String, Object?> _validate(String tool, Map<String, Object?> args) {
  final schema = toolSchemas[tool]!;
  final extra = args.keys.where((k) => !schema.containsKey(k));
  if (extra.isNotEmpty) throw ToolError('$tool: unknown argument "${extra.first}"');
  final sel = _selector[tool];
  if (sel != null && (args['id'] == null) == (args[sel] == null)) {
    throw ToolError('$tool: needs exactly one of "id" or "$sel"');
  }
  final out = <String, Object?>{};
  for (final e in schema.entries) {
    final required = e.value.endsWith('!');
    final v = args[e.key];
    if (v == null) {
      if (required) throw ToolError('$tool: missing "${e.key}"');
      continue;
    }
    switch (e.value[0]) {
      case 's':
        if (v is! String || v.trim().isEmpty || v.length > 500) {
          throw ToolError('$tool: bad "${e.key}"');
        }
        out[e.key] = v.trim();
      case 'i':
        final n = v is int
            ? v
            : v is String
                ? int.tryParse(v) ?? (e.key == 'priority' ? _priorityWords[v.toLowerCase()] : null)
                : null;
        if (n == null) throw ToolError('$tool: "${e.key}" must be an integer');
        if (e.key == 'priority' && (n < 0 || n > 2)) {
          throw ToolError('$tool: priority must be 0..2');
        }
        if (e.key != 'priority' && n <= 0) {
          throw ToolError('$tool: "${e.key}" must be a positive id');
        }
        out[e.key] = n;
      case 'd':
        final d = v is String ? parseLocalDateTime(v) : null;
        if (d == null) {
          throw ToolError('$tool: "${e.key}" must be a real local date-time');
        }
        out[e.key] = d;
      case 'b':
        if (v is! bool) throw ToolError('$tool: "${e.key}" must be bool');
        out[e.key] = v;
    }
  }
  return out;
}

/// Executes validated tool calls against the local repos. This is the only
/// place the assistant mutates app state ("model interprets, code acts").
class ToolExecutor {
  final TaskRepo tasks;
  final ReminderRepo reminders;
  final MemoryRepo memory;
  final ReminderScheduler scheduler;
  /// Best effort after a committed write (e.g. refresh the home-screen widget);
  /// its failure never fails the tool call.
  final FutureOr<void> Function()? onTasksChanged;
  final DateTime Function() clock;

  ToolExecutor(this.tasks, this.reminders, this.memory, this.scheduler,
      {this.onTasksChanged, DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  Future<String> execute(ToolCall c) async {
    final a = c.args;
    switch (c.tool) {
      case 'respond':
        return a['text'] as String;
      case 'create_task':
        final t = await tasks.create(a['title'] as String,
            notes: a['notes'] as String?,
            due: a['due'] as DateTime?,
            priority: (a['priority'] as int?) ?? 1);
        _changed();
        return 'Added task ${t.title}${t.dueAt == null ? "" : " due ${_fmt(t.dueAt!)}"}.';
      case 'edit_task':
        final id = await _taskId(a, 'target_title');
        final v = <String, Object?>{
          if (a['title'] != null) 'title': a['title'],
          if (a['notes'] != null) 'notes': a['notes'],
          if (a['due'] != null) 'due_at': (a['due'] as DateTime).millisecondsSinceEpoch,
          if (a['priority'] != null) 'priority': a['priority'],
        };
        if (v.isEmpty) throw ToolError('edit_task: nothing to change');
        if (!await tasks.update(id, v)) throw ToolError('No task #$id.');
        _changed();
        return 'Updated task #$id.';
      case 'complete_task':
        final id = await _taskId(a);
        if (!await tasks.complete(id)) throw ToolError('No task #$id.');
        _changed();
        return 'Marked task #$id done.';
      case 'delete_task':
        final id = await _taskId(a);
        if (!await tasks.delete(id)) throw ToolError('No task #$id.');
        _changed();
        return 'Deleted task #$id.';
      case 'list_tasks':
        final l = await tasks.list(
            from: a['from'] as DateTime?,
            to: a['to'] as DateTime?,
            includeDone: a['include_done'] == true);
        return l.isEmpty ? 'No tasks.' : l.join('\n');
      case 'create_reminder':
        final at = a['at'] as DateTime;
        if (!at.isAfter(clock())) throw ToolError('Reminder time is in the past.');
        final tid = a['task_id'] as int?;
        if (tid != null && await tasks.get(tid) == null) {
          throw ToolError('No task #$tid.');
        }
        // Saved with a pending 'schedule' intent first, so an interrupted
        // schedule is retried at startup instead of silently lost.
        final r = await reminders.create(a['title'] as String, at, taskId: tid);
        try {
          await scheduler.schedule(r);
        } catch (_) {
          await reminders.delete(r.id); // never keep an enabled row with no alarm
          throw ToolError(
              "I couldn't schedule that reminder, so it was not saved. Check notification and alarm permissions.");
        }
        await reminders.synced(r.id);
        return 'Okay, I will remind you ${_fmt(at)}: ${r.title}.';
      case 'edit_reminder':
        final id = await _reminderId(a, 'target_title');
        final old = await reminders.get(id);
        if (old == null || !old.enabled) throw ToolError('No reminder #$id.');
        final at = a['at'] as DateTime?;
        if (at != null && !at.isAfter(clock())) {
          throw ToolError('Reminder time is in the past.');
        }
        final v = <String, Object?>{
          if (a['title'] != null) 'title': a['title'],
          if (at != null) 'trigger_at': at.millisecondsSinceEpoch,
        };
        if (v.isEmpty) throw ToolError('edit_reminder: nothing to change');
        await reminders.update(id, {...v, 'sync': 'schedule'});
        try {
          await scheduler.schedule((await reminders.get(id))!);
        } catch (_) {
          await reminders.update(id, {
            'title': old.title,
            'trigger_at': old.triggerAt.millisecondsSinceEpoch,
          });
          try {
            await scheduler.schedule(old); // keep the old alarm
            await reminders.synced(id);
          } catch (_) {
            throw ToolError(
                "I couldn't reschedule reminder #$id. It was left unchanged, but its alarm may not be set; I'll retry when the app next starts.");
          }
          throw ToolError(
              "I couldn't reschedule reminder #$id, so it was left unchanged.");
        }
        await reminders.synced(id);
        return 'Updated reminder #$id.';
      case 'cancel_reminder':
        final id = await _reminderId(a);
        final r = await reminders.get(id);
        if (r == null || !r.enabled) throw ToolError('No reminder #$id.');
        // Intent first: once disabled it is never re-armed, even if the
        // platform cancel below fails or the app dies (startup retries it).
        await reminders.cancel(id);
        try {
          await scheduler.cancel(id);
        } catch (_) {
          throw ToolError(
              "I cancelled reminder #$id, but couldn't remove its alarm yet, so it may still go off. I'll retry when the app next starts.");
        }
        await reminders.synced(id);
        return 'Cancelled reminder #$id.';
      case 'search_memory':
        final m = await memory.search(a['query'] as String);
        return m.isEmpty ? 'I have nothing stored about that.' : m.join('\n');
    }
    throw ToolError('unknown tool ${c.tool}');
  }

  void _changed() {
    final f = onTasksChanged;
    if (f == null) return;
    unawaited(Future.sync(f)
        .catchError((Object e) => debugPrint('widget refresh failed: $e')));
  }

  /// id as given, or the single pending task with that exact (normalized) title.
  Future<int> _taskId(Map<String, Object?> a, [String key = 'title']) async {
    if (a['id'] != null) return a['id'] as int;
    final title = a[key] as String;
    return _one(await tasks.byTitle(title), (t) => t.id, (t) => t.toString(),
        'task', title);
  }

  Future<int> _reminderId(Map<String, Object?> a, [String key = 'title']) async {
    if (a['id'] != null) return a['id'] as int;
    final title = a[key] as String;
    return _one(await reminders.byTitle(title), (r) => r.id,
        (r) => r.toString(), 'reminder', title);
  }

  /// Exactly one match or a [ToolError]; duplicates ask which id instead of guessing.
  static int _one<T>(List<T> l, int Function(T) id, String Function(T) show,
      String kind, String title) {
    if (l.isEmpty) throw ToolError('No $kind titled "$title".');
    if (l.length > 1) {
      throw ToolError('Several ${kind}s are titled "$title":\n'
          '${l.map(show).join('\n')}\nWhich one? Say the number, e.g. #${id(l.first)}.');
    }
    return id(l.first);
  }

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
