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
  // multiple / follow_up: per-reminder overrides of ReminderPreferences.
  'create_reminder': {'title': 's!', 'at': 'd!', 'task_id': 'i', 'multiple': 'b', 'follow_up': 'b'},
  'list_reminders': {},
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
    if (req.isEmpty && opt.isEmpty) {
      args = '';
    } else if (req.isNotEmpty) {
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

  /// When set (the app), a reminder is saved as a task with a notification
  /// plan per these preferences; null keeps one standalone reminder.
  final ReminderPreferencesRepo? preferences;

  /// Best effort after a committed write (e.g. refresh the home-screen widget);
  /// its failure never fails the tool call.
  final FutureOr<void> Function()? onTasksChanged;
  final DateTime Function() clock;

  ToolExecutor(this.tasks, this.reminders, this.memory, this.scheduler,
      {this.onTasksChanged, DateTime Function()? clock, this.preferences})
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
        return 'Added task ${t.title}'
            '${t.dueAt == null ? "" : ", due ${_when(t.dueAt!)}"}.'
            '${await _shoppingNudge(t)}';
      case 'edit_task':
        final id = await _taskId(a, 'target_title');
        final v = <String, Object?>{
          if (a['title'] != null) 'title': a['title'],
          if (a['notes'] != null) 'notes': a['notes'],
          if (a['due'] != null) 'due_at': (a['due'] as DateTime).millisecondsSinceEpoch,
          if (a['priority'] != null) 'priority': a['priority'],
        };
        if (v.isEmpty) throw ToolError('edit_task: nothing to change');
        final alerts = await _alertsFor(id);
        if (!await tasks.update(id, v)) throw ToolError('No task #$id.');
        _changed();
        final t = (await tasks.get(id))!;
        final moved = alerts.isNotEmpty && (a['due'] != null || a['title'] != null);
        return 'Updated task #$id ${t.title}'
            '${a['due'] == null ? "" : ", now due ${_when(t.dueAt!)}"}.'
            '${moved ? " Its reminders moved with it." : ""}'
            '${await _sync()}';
      case 'complete_task':
        final id = await _taskId(a);
        final t = await tasks.get(id);
        final alerts = await _alertsFor(id);
        if (t == null || !await tasks.complete(id)) throw ToolError('No task #$id.');
        _changed();
        return 'Nice, marked #$id ${t.title} done.'
            '${alerts.isEmpty ? "" : " I cancelled its remaining reminders."}'
            '${await _sync()}';
      case 'delete_task':
        final id = await _taskId(a);
        final t = await tasks.get(id);
        final alerts = await _alertsFor(id);
        if (t == null || !await tasks.delete(id)) throw ToolError('No task #$id.');
        _changed();
        return 'Deleted task #$id ${t.title}.'
            '${alerts.isEmpty ? "" : " Its reminders are cancelled too."}'
            '${await _sync()}';
      case 'list_tasks':
        final l = await tasks.list(
            from: a['from'] as DateTime?,
            to: a['to'] as DateTime?,
            includeDone: a['include_done'] == true);
        return l.isEmpty
            ? 'No tasks.'
            : l.map((t) => '#${t.id} ${t.done ? "[done] " : ""}${t.title}'
                '${t.dueAt == null ? "" : " (due ${_when(t.dueAt!)})"}').join('\n');
      case 'list_reminders':
        final l = await reminders.upcoming();
        return l.isEmpty
            ? 'No upcoming reminders.'
            : l.map((r) => '#${r.id} ${r.title}: ${_when(r.triggerAt)}'
                '${switch (r.kind) { 'pre' => ' (early alert)', 'follow_up' => ' (follow-up)', _ => '' }}').join('\n');
      case 'create_reminder':
        return _createReminder(a);
      case 'edit_reminder':
        final id = await _reminderId(a, 'target_title');
        final old = await reminders.get(id);
        if (old == null || !old.enabled) throw ToolError('No reminder #$id.');
        final at = a['at'] as DateTime?;
        if (at != null && !at.isAfter(clock())) {
          throw ToolError('Reminder time is in the past.');
        }
        if (a['title'] == null && at == null) {
          throw ToolError('edit_reminder: nothing to change');
        }
        final task = old.taskId == null ? null : await tasks.get(old.taskId!);
        if (task != null && old.kind == 'reminder' && task.dueAt == old.triggerAt) {
          return _editPlan(id, task, a['title'] as String?, at);
        }
        final v = <String, Object?>{
          if (a['title'] != null) 'title': a['title'],
          if (at != null) 'trigger_at': at.millisecondsSinceEpoch,
        };
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
        final r = (await reminders.get(id))!;
        return 'Updated reminder #$id: ${r.title}, ${_when(r.triggerAt)}.';
      case 'cancel_reminder':
        final id = await _reminderId(a);
        final r = await reminders.get(id);
        if (r == null || !r.enabled) throw ToolError('No reminder #$id.');
        // Intent first: once disabled it is never re-armed, even if the
        // platform cancel below fails or the app dies (startup retries it).
        // A task's plan is cancelled as a whole; the task itself stays.
        final List<int> ids;
        if (r.taskId == null) {
          await reminders.cancel(id);
          ids = [id];
        } else {
          ids = await reminders.cancelGroup(r);
        }
        try {
          for (final x in ids) {
            await scheduler.cancel(x);
            await reminders.synced(x);
          }
        } catch (_) {
          throw ToolError(
              "I cancelled reminder #$id, but couldn't remove its alarm yet, so it may still go off. I'll retry when the app next starts.");
        }
        return 'Cancelled reminder #$id ${r.title}'
            '${ids.length > 1 ? " and its other alerts" : ""}.'
            '${r.taskId == null ? "" : " The task is still in Tasks."}';
      case 'search_memory':
        final m = await memory.search(a['query'] as String);
        return m.isEmpty ? 'I have nothing stored about that.' : m.join('\n');
    }
    throw ToolError('unknown tool ${c.tool}');
  }

  Future<String> _createReminder(Map<String, Object?> a) async {
    final title = a['title'] as String, at = a['at'] as DateTime;
    final now = clock();
    if (!at.isAfter(now)) throw ToolError('Reminder time is in the past.');
    final tid = a['task_id'] as int?;
    final linked = tid == null ? null : await tasks.get(tid);
    if (tid != null && linked == null) throw ToolError('No task #$tid.');
    if (linked != null && linked.done) {
      throw ToolError('Task #$tid is done. Restore it first if you want a reminder for it.');
    }
    // A repeated request must not double the notification.
    final want = normTitle(title);
    for (final r in await reminders.upcoming()) {
      if (r.kind == 'reminder' && r.triggerAt == at && normTitle(r.title) == want) {
        return 'You already have that reminder: ${r.title}, ${_when(at)}.';
      }
    }
    const failure =
        "I couldn't schedule that reminder, so it was not saved. Check notification and alarm permissions.";
    final prefsRepo = preferences;
    if (prefsRepo == null) {
      // Saved with a pending 'schedule' intent first, so an interrupted
      // schedule is retried at startup instead of silently lost.
      final r = await reminders.create(title, at, taskId: tid);
      try {
        await scheduler.schedule(r);
      } catch (_) {
        await reminders.delete(r.id); // never keep an enabled row with no alarm
        throw ToolError(failure);
      }
      await reminders.synced(r.id);
      return await _confirm(at, r.title);
    }
    final prefs = await prefsRepo.get();
    final multiple = a['multiple'] as bool? ?? prefs.multiple;
    final followUp = a['follow_up'] as bool? ?? prefs.followUp;
    final plan = reminderPlan(at, prefs,
        multiple: multiple, followUp: followUp, now: now);
    // Linking to a task replaces its plan; keep what's needed to undo it.
    final priorPlan = tid == null ? null : await reminders.planOf(tid);
    final prior = tid == null ? const <int>[] : [for (final r in await reminders.forTask(tid)) r.id];
    final saved = await reminders.createPlan(title, at, plan, taskId: tid,
        intent: (
          lead: multiple ? prefs.leadMinutes : const <int>[],
          follow: followUp ? prefs.followUpMinutes : null,
        ));
    try {
      for (final r in saved) {
        await scheduler.schedule(r);
        await reminders.synced(r.id);
      }
      if (prior.isNotEmpty) await scheduler.syncPending(reminders); // old alarms off
    } catch (_) {
      // All or nothing: a half-armed plan would invite a retry that duplicates.
      if (tid == null) {
        await tasks.delete(saved.first.taskId!);
      } else {
        await reminders.restorePlan(tid, linked!.dueAt, priorPlan, prior,
            [for (final r in saved) r.id]);
      }
      List<int> stuck;
      try {
        stuck = await scheduler.syncPending(reminders);
      } catch (_) {
        stuck = [for (final r in saved) r.id];
      }
      // Cancel intents stay pending and are retried at the next sync/startup.
      final leftover = saved.any((r) => stuck.contains(r.id));
      final unrestored = prior.any(stuck.contains);
      if (leftover || unrestored) {
        throw ToolError([
          "I couldn't schedule all alerts for that reminder, so it was not saved.",
          if (leftover) 'Some of its alerts that were already set may still go off.',
          if (unrestored) "Some of the task's earlier alarms may not be restored yet.",
          "I'll keep retrying when the app syncs or next starts.",
        ].join(' '));
      }
      throw ToolError(failure);
    }
    _changed();
    final alerts = saved.where((r) => r.kind != 'follow_up').toList();
    final follow = saved.where((r) => r.kind == 'follow_up').firstOrNull;
    final expected = (multiple ? prefs.leadMinutes.length : 0) + 1;
    return [
      await _confirm(at, title),
      if (alerts.length > 1)
        'Alerts at ${_join(alerts.map((r) => _clock(r.triggerAt)))}.',
      if (multiple && alerts.length < expected)
        'I skipped earlier alerts that would be in the past${prefs.hasQuietHours ? " or in quiet hours" : ""}.',
      if (follow != null)
        "I'll check in ${_when(follow.triggerAt)} (${prefs.followUpMinutes} min after the start, since I don't know when it ends) to ask how it went.",
      if (followUp && follow == null)
        'No follow-up: it would fall in quiet hours.',
    ].join(' ');
  }

  /// "Okay, I'll remind you…", unless the phone won't deliver it as asked.
  Future<String> _confirm(DateTime at, String title) async {
    String? issue;
    try {
      issue = await scheduler.deliveryIssue();
    } catch (_) {} // unknown: don't invent a problem
    return issue == null
        ? "Okay, I'll remind you ${_when(at)}: $title."
        : 'Saved the reminder for ${_when(at)}: $title, but $issue';
  }

  /// Moves/renames a task's whole plan through [TaskRepo.update]; rolled back
  /// if its alarms can't be set.
  Future<String> _editPlan(int id, Task task, String? title, DateTime? at) async {
    final group = {for (final r in await _alertsFor(task.id)) r.id};
    await tasks.update(task.id, {
      if (title != null) 'title': title,
      if (at != null) 'due_at': at.millisecondsSinceEpoch,
    });
    // Regeneration may add rows, so check every alert of the task.
    Future<bool> stuck() async {
      final failed = await scheduler.syncPending(reminders);
      final ids = {...group, for (final r in await reminders.forTask(task.id)) r.id};
      return failed.any(ids.contains);
    }
    if (await stuck()) {
      // Moving back regenerates the whole prior plan from the stored intent.
      await tasks.update(task.id,
          {'title': task.title, 'due_at': task.dueAt!.millisecondsSinceEpoch});
      throw ToolError(await stuck()
          ? "I couldn't reschedule reminder #$id. It was left unchanged, but its alarm may not be set; I'll retry when the app next starts."
          : "I couldn't reschedule reminder #$id, so it was left unchanged.");
    }
    _changed();
    final t = (await tasks.get(task.id))!;
    return 'Updated reminder #$id: ${t.title}, ${_when(t.dueAt!)}.'
        '${group.length > 1 ? " Its other alerts moved with it." : ""}';
  }

  /// Applies pending alarm intents after a task write; honest when it can't.
  Future<String> _sync() async {
    try {
      if ((await scheduler.syncPending(reminders)).isEmpty) return '';
    } catch (_) {}
    return " I couldn't update its notifications yet; I'll retry when the app next starts.";
  }

  Future<List<Reminder>> _alertsFor(int taskId) async =>
      (await reminders.upcoming()).where((r) => r.taskId == taskId).toList();

  static final _shopping =
      RegExp(r'^(?:buy|get|pick up|grab|purchase)\s+(.+)$', caseSensitive: false);

  /// " You also still need to buy eggs and bread." for other pending
  /// shopping tasks (done ones are excluded by [TaskRepo.list]).
  Future<String> _shoppingNudge(Task t) async {
    if (!_shopping.hasMatch(t.title.trim())) return '';
    final others = [
      for (final o in await tasks.list())
        if (o.id != t.id) _shopping.firstMatch(o.title.trim())?.group(1)
    ].whereType<String>().toSet();
    return others.isEmpty ? '' : ' You also still need to buy ${_join(others)}.';
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

  String _when(DateTime d) => friendlyTime(d, clock());

  static String _clock(DateTime d) =>
      '${d.hour % 12 == 0 ? 12 : d.hour % 12}:${d.minute.toString().padLeft(2, '0')} '
      '${d.hour < 12 ? 'AM' : 'PM'}';

  static String _join(Iterable<String> l) {
    final x = l.toList();
    return x.length < 2 ? x.join() : '${x.take(x.length - 1).join(', ')} and ${x.last}';
  }
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "tomorrow (Wed 14 Oct) at 9:00 AM": always the exact date and time, with
/// today/tomorrow/yesterday spelled out relative to [now].
String friendlyTime(DateTime d, DateTime now) {
  final days = DateTime.utc(d.year, d.month, d.day)
      .difference(DateTime.utc(now.year, now.month, now.day))
      .inDays;
  final date = '${_weekdays[d.weekday - 1]} ${d.day} ${_months[d.month - 1]}'
      '${d.year == now.year ? '' : ' ${d.year}'}';
  final rel = switch (days) { 0 => 'today', 1 => 'tomorrow', -1 => 'yesterday', _ => null };
  return '${rel == null ? 'on $date' : '$rel ($date)'} at ${ToolExecutor._clock(d)}';
}
