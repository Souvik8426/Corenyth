import 'dart:convert';

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
  'edit_task': {'id': 'i!', 'title': 's', 'notes': 's', 'due': 'd', 'priority': 'i'},
  'complete_task': {'id': 'i!'},
  'delete_task': {'id': 'i!'},
  'list_tasks': {'from': 'd', 'to': 'd', 'include_done': 'b'},
  'create_reminder': {'title': 's!', 'at': 'd!', 'task_id': 'i'},
  'edit_reminder': {'id': 'i!', 'title': 's', 'at': 'd'},
  'cancel_reminder': {'id': 'i!'},
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
  final tool = j['type'] == 'respond' ? 'respond' : j['tool'];
  if (tool is! String || !toolSchemas.containsKey(tool)) {
    throw ToolError('unknown tool: $tool');
  }
  final a = (tool == 'respond' && j['arguments'] == null) ? j : j['arguments'];
  return ToolCall(tool, _validate(tool, a is Map ? Map<String, Object?>.from(a) : {}));
}

const _priorityWords = {'low': 0, 'normal': 1, 'medium': 1, 'high': 2};

Map<String, Object?> _validate(String tool, Map<String, Object?> args) {
  final schema = toolSchemas[tool]!;
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
        out[e.key] = n;
      case 'd':
        final d = v is String ? DateTime.tryParse(v) : null;
        if (d == null) throw ToolError('$tool: "${e.key}" must be ISO-8601');
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
  final void Function()? onTasksChanged; // e.g. refresh the home-screen widget
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
        final id = a['id'] as int;
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
        final id = a['id'] as int;
        if (!await tasks.complete(id)) throw ToolError('No task #$id.');
        _changed();
        return 'Marked task #$id done.';
      case 'delete_task':
        final id = a['id'] as int;
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
        final r = await reminders.create(a['title'] as String, at, taskId: tid);
        await scheduler.schedule(r);
        return 'Okay, I will remind you ${_fmt(at)}: ${r.title}.';
      case 'edit_reminder':
        final id = a['id'] as int;
        final old = await reminders.get(id);
        if (old == null || !old.enabled) throw ToolError('No reminder #$id.');
        final at = a['at'] as DateTime?;
        if (at != null && !at.isAfter(clock())) {
          throw ToolError('Reminder time is in the past.');
        }
        await reminders.update(id, {
          if (a['title'] != null) 'title': a['title'],
          if (at != null) 'trigger_at': at.millisecondsSinceEpoch,
        });
        await scheduler.schedule((await reminders.get(id))!);
        return 'Updated reminder #$id.';
      case 'cancel_reminder':
        final id = a['id'] as int;
        if (!await reminders.cancel(id)) throw ToolError('No reminder #$id.');
        await scheduler.cancel(id);
        return 'Cancelled reminder #$id.';
      case 'search_memory':
        final m = await memory.search(a['query'] as String);
        return m.isEmpty ? 'I have nothing stored about that.' : m.join('\n');
    }
    throw ToolError('unknown tool ${c.tool}');
  }

  void _changed() => onTasksChanged?.call();

  static String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
