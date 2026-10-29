import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

int _now() => DateTime.now().millisecondsSinceEpoch;
DateTime? _dt(Object? ms) =>
    ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms as int);

class Task {
  final int id;
  final String title;
  final String? notes;
  final bool done;
  final DateTime? dueAt;
  final int priority;

  /// v6 follow-through metadata (see db.dart); all optional.
  final DateTime? completedAt, endsAt, deadlineAt, awaitingAt;
  final String? subject, outcome;

  /// Open question: [TaskRepo.details] or [TaskRepo.outcomeQuestion].
  final String? awaiting;

  /// Daily reminder time (minutes after midnight); null = not recurring.
  final int? dailyMinute;
  Task(Map<String, Object?> r)
      : id = r['id'] as int,
        title = r['title'] as String,
        notes = r['notes'] as String?,
        done = r['status'] == 'done',
        dueAt = _dt(r['due_at']),
        priority = r['priority'] as int,
        completedAt = _dt(r['completed_at']),
        endsAt = _dt(r['ends_at']),
        deadlineAt = _dt(r['deadline_at']),
        awaitingAt = _dt(r['awaiting_at']),
        subject = r['subject'] as String?,
        outcome = r['outcome'] as String?,
        awaiting = r['awaiting'] as String?,
        dailyMinute = r['daily_minute'] as int?;
  @override
  String toString() =>
      '#$id ${done ? "[done] " : ""}$title${dueAt == null ? "" : " (due ${dueAt!.toIso8601String()})"}';
}

class Reminder {
  final String kind;
  final int id;
  final int? taskId;
  final String title;
  final DateTime triggerAt;
  final bool enabled;

  /// Pending platform operation ('schedule' / 'cancel'), null once in sync.
  final String? sync;
  Reminder(Map<String, Object?> r)
      : kind = r['kind'] as String? ?? 'reminder',
        id = r['id'] as int,
        taskId = r['task_id'] as int?,
        title = r['title'] as String,
        triggerAt = _dt(r['trigger_at'])!,
        enabled = r['enabled'] == 1,
        sync = r['sync'] as String?;
  @override
  String toString() => '#$id $title at ${triggerAt.toIso8601String()}';
}

class TaskRepo {
  final Database db;
  Future<void> Function()? onRemindersChanged;
  TaskRepo(this.db);

  /// [opId]: the submitted turn creating it (see OperationJournal), stamped
  /// in the same insert so a retry finds it ([byOperation]).
  Future<Task> create(String title,
      {String? notes, DateTime? due, int priority = 1, String? opId}) async {
    final id = await db.insert('tasks', {
      'title': title,
      'notes': notes,
      'created_at': _now(),
      'due_at': due?.millisecondsSinceEpoch,
      'priority': priority,
      if (opId != null) 'op_id': opId,
    });
    return (await get(id))!;
  }

  /// Tasks created by operation [opId] (a committed write of that turn).
  Future<List<Task>> byOperation(String opId) async => (await db.query('tasks',
          where: 'op_id = ?', whereArgs: [opId], orderBy: 'id'))
      .map(Task.new)
      .toList();

  Future<Task?> get(int id) async {
    final r = await db.query('tasks', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Task(r.first);
  }

  /// [from]/[to] bound due_at; [includeDone] false hides completed tasks.
  Future<List<Task>> list(
      {DateTime? from, DateTime? to, bool includeDone = false}) async {
    final w = <String>[], a = <Object?>[];
    if (!includeDone) w.add("status = 'pending'");
    if (from != null) {
      w.add('due_at >= ?');
      a.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      w.add('due_at < ?');
      a.add(to.millisecondsSinceEpoch);
    }
    final r = await db.query('tasks',
        where: w.isEmpty ? null : w.join(' AND '),
        whereArgs: a,
        orderBy: 'due_at IS NULL, due_at, priority DESC, id');
    return r.map(Task.new).toList();
  }

  /// Retrieves tasks relevant to [text] before applying caps, including
  /// explicitly referenced older or completed items. Bounded to [cap].
  Future<List<Task>> relevantTasks(String text, {int cap = 10}) async {
    final results = <int, Task>{};
    // 1. Explicit ID references (e.g. #15, task 15)
    final idMatches =
        RegExp(r'(?:#|task\s+|id\s+)(\d+)\b', caseSensitive: false)
            .allMatches(text);
    for (final m in idMatches) {
      final id = int.tryParse(m.group(1)!);
      if (id != null) {
        final t = await get(id);
        if (t != null) results[t.id] = t;
      }
    }
    final bare = RegExp(r'^\s*#?(\d+)\s*$').firstMatch(text.trim());
    if (bare != null) {
      final id = int.tryParse(bare.group(1)!);
      if (id != null) {
        final t = await get(id);
        if (t != null) results[t.id] = t;
      }
    }

    // 2. Keyword/term matches across all pending tasks
    final allPending = await list();
    final words = MemoryRepo.terms(text);
    if (words.isNotEmpty) {
      final scored = <Task, int>{};
      for (final t in allPending) {
        if (results.containsKey(t.id)) continue;
        final tTerms = MemoryRepo.terms(t.title);
        final hits = words.where(tTerms.contains).length;
        if (hits > 0) scored[t] = hits;
      }
      final sortedScored = scored.keys.toList()
        ..sort((a, b) => scored[b]!.compareTo(scored[a]!));
      for (final t in sortedScored) {
        results[t.id] = t;
        if (results.length >= cap) break;
      }
    }

    // 3. Fill remaining slots with upcoming pending tasks
    if (results.length < cap) {
      for (final t in allPending) {
        if (!results.containsKey(t.id)) {
          results[t.id] = t;
          if (results.length >= cap) break;
        }
      }
    }
    return results.values.take(cap).toList();
  }

  /// Linked alerts follow the task in the same transaction (every caller:
  /// chat, Tasks page, widget): done or due removed cancels them all, a new due
  /// time shifts the whole plan, a new title renames them. Platform alarms are
  /// then synced via [onRemindersChanged]; its failure never fails the write
  /// (the intent stays pending and is retried), so callers never retry a
  /// committed change.
  Future<bool> update(int id, Map<String, Object?> values) async {
    final changed = await db.transaction((tx) async {
      final old = await tx.query('tasks', where: 'id = ?', whereArgs: [id]);
      if (old.isEmpty) return false;
      await tx.update('tasks', values, where: 'id = ?', whereArgs: [id]);
      const linked = 'task_id = ? AND enabled = 1';
      if (values['status'] == 'done' ||
          values.containsKey('due_at') && values['due_at'] == null) {
        await tx.update('reminders', {'enabled': 0, 'sync': 'cancel'},
            where: linked, whereArgs: [id]);
        // Plan over: restoring the task never re-arms it; a daily recurrence ends.
        await tx.update('tasks',
            {'alert_plan': null, 'daily_minute': null, 'recurrence': null},
            where: 'id = ?', whereArgs: [id]);
        return true;
      }
      final previous = old.first['due_at'] as int?;
      final next = values['due_at'] as int?;
      if (previous != null && next != null && !values.containsKey('ends_at')) {
        // A known end time moves with its start.
        await tx.rawUpdate(
            'UPDATE tasks SET ends_at = ends_at + ? '
            'WHERE id = ? AND ends_at IS NOT NULL',
            [next - previous, id]);
      }
      final intent = AlertIntentJson.decode(old.first['alert_plan']);
      if (previous != null &&
          next != null &&
          next != previous &&
          intent != null) {
        await _replan(tx, id, previous, next,
            (values['title'] ?? old.first['title']) as String, intent);
      } else if (previous != null && next != null && next != previous) {
        // No stored plan (older rows): same offsets from the new time; early
        // alerts/follow-ups now past or in quiet hours are dropped.
        final prefs = await _readPrefs(tx), now = DateTime.now();
        final delta = Duration(milliseconds: next - previous);
        for (final r
            in (await tx.query('reminders', where: linked, whereArgs: [id]))
                .map(Reminder.new)) {
          final at = r.triggerAt.add(delta);
          final drop =
              r.kind != 'reminder' && (!at.isAfter(now) || prefs.isQuiet(at));
          await tx.update(
              'reminders',
              drop
                  ? {'enabled': 0, 'sync': 'cancel'}
                  : {
                      'trigger_at': at.millisecondsSinceEpoch,
                      'sync': 'schedule'
                    },
              where: 'id = ?',
              whereArgs: [r.id]);
        }
      }
      final title = values['title'];
      if (title is String && title != old.first['title']) {
        await tx.rawUpdate(
            "UPDATE reminders SET title = CASE WHEN kind = 'follow_up' "
            "THEN ? ELSE ? END, sync = 'schedule' WHERE $linked",
            [followUpText(title), title, id]);
      }
      return true;
    });
    if (changed) await _synced();
    return changed;
  }

  /// Reapply stored intent after quiet-hour changes, including skipped alerts.
  Future<void> refreshPlans() async {
    await db.transaction((tx) async {
      for (final t in await tx.query('tasks',
          where:
              "status = 'pending' AND due_at IS NOT NULL AND alert_plan IS NOT NULL")) {
        final intent = AlertIntentJson.decode(t['alert_plan']);
        if (intent == null) continue;
        final at = t['due_at'] as int;
        await _replan(tx, t['id'] as int, at, at, t['title'] as String, intent);
      }
    });
    await _synced();
  }

  Future<void> _synced() async {
    try {
      await onRemindersChanged?.call();
    } catch (_) {} // pending intents are retried at the next sync/startup
  }

  Future<bool> complete(int id) =>
      update(id, {'status': 'done', 'completed_at': _now()});

  Future<bool> delete(int id) async {
    final changed = await db.transaction((tx) async {
      await tx.update('reminders', {'enabled': 0, 'sync': 'cancel'},
          where: 'task_id = ? AND enabled = 1', whereArgs: [id]);
      return await tx.delete('tasks', where: 'id = ?', whereArgs: [id]) > 0;
    });
    if (changed) await _synced();
    return changed;
  }

  /// Pending tasks whose [normTitle] equals [title]'s (several = ambiguous).
  Future<List<Task>> byTitle(String title) async {
    final want = normTitle(title);
    return (await list()).where((t) => normTitle(t.title) == want).toList();
  } // ponytail: scans pending tasks in Dart; add a normalized column if lists get huge.

  /// [Task.awaiting] values: optional meeting end/subject, or how it went.
  static const details = 'details', outcomeQuestion = 'outcome';

  /// Opens (null: closes) the task's one open question. Stored on the task,
  /// not the chat, so any chat or a restart can resume it; it never blocks
  /// the task's reminders.
  Future<bool> setAwaiting(int id, String? question) async =>
      await db.update(
          'tasks',
          {
            'awaiting': question,
            'awaiting_at': question == null ? null : _now()
          },
          where: 'id = ?',
          whereArgs: [id]) >
      0;

  /// Tasks with an open question (done ones too: outcomes), newest first.
  Future<List<Task>> awaitingAnswers({String? question}) async =>
      (await db.query('tasks',
              where: question == null ? 'awaiting IS NOT NULL' : 'awaiting = ?',
              whereArgs: question == null ? null : [question],
              orderBy: 'awaiting_at DESC, id DESC'))
          .map(Task.new)
          .toList();

  /// Saves optional meeting details and closes an open details question.
  /// [endsAt] replaces the follow-up estimate; regenerating the plan also
  /// removes quiet/past follow-ups or restores an earlier skipped one.
  /// Throws [ArgumentError] when [endsAt] is not after the task's start.
  /// False = no such task.
  Future<bool> setEventDetails(int id,
      {DateTime? endsAt, String? subject}) async {
    var moved = false;
    final found = await db.transaction((tx) async {
      final old = await tx.query('tasks', where: 'id = ?', whereArgs: [id]);
      if (old.isEmpty) return false;
      final due = _dt(old.first['due_at']);
      if (endsAt != null && due != null && !endsAt.isAfter(due)) {
        throw ArgumentError('The end time must be after the start.');
      }
      final v = {
        if (endsAt != null) 'ends_at': endsAt.millisecondsSinceEpoch,
        if (subject != null && subject.trim().isNotEmpty)
          'subject': subject.trim(),
        if (old.first['awaiting'] == details) ...{
          'awaiting': null,
          'awaiting_at': null
        },
      };
      if (v.isNotEmpty)
        await tx.update('tasks', v, where: 'id = ?', whereArgs: [id]);
      final intent = AlertIntentJson.decode(old.first['alert_plan']);
      if (endsAt == null ||
          due == null ||
          intent?.follow == null ||
          old.first['status'] == 'done') {
        return true;
      }
      final nextIntent =
          (lead: intent!.lead, follow: endsAt.difference(due).inMinutes);
      await tx.update(
          'tasks',
          {
            'alert_plan': nextIntent.encode(),
          },
          where: 'id = ?',
          whereArgs: [id]);
      await _replan(tx, id, due.millisecondsSinceEpoch,
          due.millisecondsSinceEpoch, old.first['title'] as String, nextIntent);
      moved = true;
      return true;
    });
    if (moved) await _synced();
    return found;
  }

  /// Saves what the user said happened and closes an open outcome question,
  /// so it is never asked again.
  Future<bool> setOutcome(int id, String outcome) async =>
      await db.rawUpdate(
          "UPDATE tasks SET outcome = ?, awaiting_at = CASE WHEN awaiting = 'outcome' "
          "THEN NULL ELSE awaiting_at END, awaiting = CASE WHEN awaiting = 'outcome' "
          'THEN NULL ELSE awaiting END WHERE id = ?',
          [outcome.trim(), id]) >
      0;

  /// Makes pending task [id] a daily reminder at [minute] (after midnight)
  /// until [deadline] inclusive (null = until done). Its alerts are replaced by
  /// one event alert at the first occurrence after [now], which becomes its
  /// due time; [deadline] is kept separately ([Task.deadlineAt]) and only
  /// changes here. Null = task not pending, or no occurrence before [deadline].
  Future<DateTime?> setDaily(int id, int minute,
      {DateTime? deadline, required DateTime now}) async {
    if (minute < 0 || minute >= 1440)
      throw ArgumentError('Invalid daily time.');
    final next = nextDaily(minute, now, deadline);
    if (next == null) return null;
    final ok = await db
        .transaction((tx) => _daily(tx, id, minute, deadline, next, null));
    if (!ok) return null;
    await _synced();
    return next;
  }

  /// A new pending task [title] that is a daily reminder (see [setDaily]),
  /// created with its alert in one transaction: no half-made daily task
  /// survives a crash. Null = no occurrence before [deadline]; nothing saved.
  Future<({Task task, DateTime first})?> createDaily(String title, int minute,
      {DateTime? deadline, required DateTime now, String? opId}) async {
    if (minute < 0 || minute >= 1440)
      throw ArgumentError('Invalid daily time.');
    final next = nextDaily(minute, now, deadline);
    if (next == null) return null;
    final id = await db.transaction((tx) async {
      final id = await tx.insert('tasks', {
        'title': title,
        'created_at': _now(),
        'priority': 1,
        if (opId != null) 'op_id': opId,
      });
      await _daily(tx, id, minute, deadline, next, opId);
      return id;
    });
    await _synced();
    return (task: (await get(id))!, first: next);
  }

  Future<bool> _daily(Transaction tx, int id, int minute, DateTime? deadline,
      DateTime next, String? opId) async {
    final t = await tx.query('tasks',
        where: "id = ? AND status = 'pending'", whereArgs: [id]);
    if (t.isEmpty) return false;
    await tx.update('reminders', {'enabled': 0, 'sync': 'cancel'},
        where: 'task_id = ? AND enabled = 1', whereArgs: [id]);
    await tx.update(
        'tasks',
        {
          'recurrence': 'daily',
          'daily_minute': minute,
          'deadline_at': deadline?.millisecondsSinceEpoch,
          'due_at': next.millisecondsSinceEpoch,
          'alert_plan': (lead: const <int>[], follow: null).encode(),
        },
        where: 'id = ?',
        whereArgs: [id]);
    await tx.insert('reminders', {
      'task_id': id,
      'kind': 'reminder',
      'title': t.first['title'],
      'trigger_at': next.millisecondsSinceEpoch,
      'enabled': 1,
      'sync': 'schedule',
      if (opId != null) 'op_id': opId,
    });
    return true;
  }

  /// Moves a pending daily task to its next occurrence after [now]; missed
  /// ones are skipped, never replayed. The alert row is reused (same
  /// notification id). Past its deadline the alerts are cancelled and null is
  /// returned; the task stays pending for the evening review, due unchanged.
  Future<DateTime?> advanceDaily(int id, DateTime now) async {
    final t = await get(id);
    if (t == null || t.done || t.dailyMinute == null) return null;
    if (t.dueAt != null &&
        t.dueAt!.isAfter(now) &&
        (t.deadlineAt == null || !t.dueAt!.isAfter(t.deadlineAt!)))
      return t.dueAt;
    final next = nextDaily(t.dailyMinute!, now, t.deadlineAt);
    if (next == null) {
      await db.transaction((tx) async {
        await tx.update('reminders', {'enabled': 0, 'sync': 'cancel'},
            where: 'task_id = ? AND enabled = 1', whereArgs: [id]);
        await tx.update('tasks',
            {'alert_plan': null, 'daily_minute': null, 'recurrence': null},
            where: 'id = ?', whereArgs: [id]);
      });
      await _synced();
      return null;
    }
    if (next != t.dueAt)
      await update(id, {'due_at': next.millisecondsSinceEpoch});
    return next;
  }
}

/// First daily [minute] (after midnight) strictly after [after], or null when
/// it is later than [until]. Calendar days, so DST keeps the wall-clock time.
DateTime? nextDaily(int minute, DateTime after, [DateTime? until]) {
  DateTime on(int day) =>
      DateTime(after.year, after.month, day, minute ~/ 60, minute % 60);
  var at = on(after.day);
  if (!at.isAfter(after)) at = on(after.day + 1);
  return until != null && at.isAfter(until) ? null : at;
}

/// Case/punctuation/whitespace-insensitive title key for exact title matching.
String normTitle(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

class ReminderRepo {
  final Database db;
  ReminderRepo(this.db, {DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;

  /// Saves the whole [plan] (see [reminderPlan]) and, without [taskId], its
  /// task due at [at], in one transaction with pending 'schedule' intents, so
  /// a crash never leaves half a plan or an alarm without a row.
  /// [intent] is stored on the task so a later due change regenerates the
  /// requested alerts, including ones skipped now (see [TaskRepo.update]).
  /// With [taskId] this replaces the task's plan: its enabled alerts get a
  /// cancel intent and its due time becomes [at], in the same transaction.
  /// Undo with [restorePlan].
  /// [opId] stamps the new task (or, with [taskId], the new alerts) with the
  /// submitted turn in the same transaction (see [TaskRepo.byOperation]).
  Future<List<Reminder>> createPlan(
          String title, DateTime at, List<PlannedAlert> plan,
          {int? taskId,
          AlertIntent intent = (lead: const [], follow: null),
          String? opId}) =>
      db.transaction((tx) async {
        final id = taskId ??
            await tx.insert('tasks', {
              'title': title,
              'created_at': _now(),
              'due_at': at.millisecondsSinceEpoch,
              if (opId != null) 'op_id': opId,
            });
        if (taskId != null) {
          await tx.update('reminders', {'enabled': 0, 'sync': 'cancel'},
              where: 'task_id = ? AND enabled = 1', whereArgs: [id]);
        }
        await tx.update(
            'tasks',
            {
              'alert_plan': intent.encode(),
              'due_at': at.millisecondsSinceEpoch,
            },
            where: 'id = ?',
            whereArgs: [id]);
        return [
          for (final p in plan)
            await () async {
              final values = <String, Object?>{
                'task_id': id,
                'kind': p.kind,
                'title': p.kind == 'follow_up' ? followUpText(title) : title,
                'trigger_at': p.at.millisecondsSinceEpoch,
                'enabled': 1,
                'sync': 'schedule',
                if (opId != null) 'op_id': opId,
              };
              return Reminder(
                  {...values, 'id': await tx.insert('reminders', values)});
            }(),
        ];
      });

  /// Enabled alerts of one task, earliest first.
  Future<List<Reminder>> forTask(int taskId) async =>
      (await db.query('reminders',
              where: 'task_id = ? AND enabled = 1',
              whereArgs: [taskId],
              orderBy: 'trigger_at'))
          .map(Reminder.new)
          .toList();

  /// Cancels a reminder together with the rest of its task's plan (one write).
  Future<List<int>> cancelGroup(Reminder r) async {
    if (r.taskId == null) {
      await cancel(r.id);
      return [r.id];
    }
    final ids = [for (final x in await forTask(r.taskId!)) x.id];
    await db.transaction((tx) async {
      await tx.update('reminders', {'enabled': 0, 'sync': 'cancel'},
          where: 'task_id = ? AND enabled = 1', whereArgs: [r.taskId]);
      await tx.update('tasks', {'alert_plan': null},
          where: 'id = ?', whereArgs: [r.taskId]); // never regenerated
    });
    return ids;
  }

  /// Raw stored plan of a task, to restore it on rollback ([setPlan]).
  Future<String?> planOf(int taskId) async => (await db.query('tasks',
          columns: ['alert_plan'], where: 'id = ?', whereArgs: [taskId]))
      .firstOrNull?['alert_plan'] as String?;

  /// Rolls back a failed replacement in one transaction: [added] alerts get
  /// a cancel intent, the [prior] alerts are re-armed, and the task's due
  /// time and stored plan return to [due] / [plan].
  Future<void> restorePlan(int taskId, DateTime? due, String? plan,
          List<int> prior, List<int> added) =>
      db.transaction((tx) async {
        for (final id in added) {
          await tx.update('reminders', {'enabled': 0, 'sync': 'cancel'},
              where: 'id = ?', whereArgs: [id]);
        }
        for (final id in prior) {
          await tx.update('reminders', {'enabled': 1, 'sync': 'schedule'},
              where: 'id = ?', whereArgs: [id]);
        }
        await tx.update(
            'tasks',
            {
              'alert_plan': plan,
              'due_at': due?.millisecondsSinceEpoch,
            },
            where: 'id = ?',
            whereArgs: [taskId]);
      });

  /// Tasks with an enabled follow-up (fired or not): only these get the
  /// "How did it go?" check-in in Tasks.
  Future<Set<int>> followUpTasks() async => {
        for (final r in await db.query('reminders',
            columns: ['task_id'],
            where:
                "kind = 'follow_up' AND enabled = 1 AND task_id IS NOT NULL"))
          r['task_id'] as int
      };

  /// The row is saved with a pending 'schedule' intent; clear it with [synced].
  Future<Reminder> create(String title, DateTime at,
      {int? taskId, String? opId}) async {
    final id = await db.insert('reminders', {
      'title': title,
      'trigger_at': at.millisecondsSinceEpoch,
      'task_id': taskId,
      'sync': 'schedule',
      if (opId != null) 'op_id': opId,
    });
    return (await get(id))!;
  }

  /// Alerts (any state) created by operation [opId], earliest first.
  Future<List<Reminder>> byOperation(String opId) async =>
      (await db.query('reminders',
              where: 'op_id = ?', whereArgs: [opId], orderBy: 'trigger_at'))
          .map(Reminder.new)
          .toList();

  /// Every alert of task [taskId] in any state (receipts, recovery).
  Future<List<Reminder>> allForTask(int taskId) async =>
      (await db.query('reminders',
              where: 'task_id = ?', whereArgs: [taskId], orderBy: 'trigger_at'))
          .map(Reminder.new)
          .toList();

  Future<Reminder?> get(int id) async {
    final r = await db.query('reminders', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Reminder(r.first);
  }

  Future<List<Reminder>> upcoming() => upcomingAt(_clock());

  /// Uses the caller's captured turn clock for temporal consistency.
  Future<List<Reminder>> upcomingAt(DateTime now) async =>
      (await db.query('reminders',
              where: 'enabled = 1 AND trigger_at > ?',
              whereArgs: [now.millisecondsSinceEpoch],
              orderBy: 'trigger_at'))
          .map(Reminder.new)
          .toList();

  Future<bool> update(int id, Map<String, Object?> v) async =>
      await db.update('reminders', v, where: 'id = ?', whereArgs: [id]) > 0;

  /// Disables the reminder and records the pending platform cancel in one write,
  /// so a crash or failed cancel is retried at startup, never re-armed.
  Future<bool> cancel(int id) => update(id, {'enabled': 0, 'sync': 'cancel'});

  /// Marks the platform operation done.
  Future<bool> synced(int id) => update(id, {'sync': null});

  /// Reminders whose last platform operation has not been confirmed.
  Future<List<Reminder>> pending() async =>
      (await db.query('reminders', where: 'sync IS NOT NULL'))
          .map(Reminder.new)
          .toList();

  /// Hard delete; used to roll back a reminder that could not be scheduled.
  Future<bool> delete(int id) async =>
      await db.delete('reminders', where: 'id = ?', whereArgs: [id]) > 0;

  /// Upcoming enabled reminders whose [normTitle] equals [title]'s; one per
  /// task plan (its early alerts share the title), so a plan isn't ambiguous.
  /// A plan is represented by its event-time ('reminder') alert, so an edit
  /// by title moves the whole plan, not one early alert.
  Future<List<Reminder>> byTitle(String title) async {
    final want = normTitle(title), seen = <int>{};
    final hits = [
      for (final r in await upcoming())
        if (normTitle(r.title) == want) r
    ];
    final main = {
      for (final r in hits)
        if (r.taskId != null && r.kind == 'reminder') r.taskId!: r
    };
    return [
      for (final r in hits)
        if (r.taskId == null)
          r
        else if (seen.add(r.taskId!))
          main[r.taskId!] ?? r
    ];
  }
}

/// Fixed follow-up wording: written by the app when the plan is saved, never
/// generated by the model in the background.
String followUpText(String title) =>
    'How did $title go? Mark it done or postpone it in Tasks.';

typedef PlannedAlert = ({String kind, DateTime at});

/// What the user asked for one item: early-alert offsets (empty = single
/// alert) and follow-up delay (null = none). Quiet hours come from the
/// current preferences whenever the plan is (re)generated.
typedef AlertIntent = ({List<int> lead, int? follow});

extension AlertIntentJson on AlertIntent {
  String encode() =>
      jsonEncode({'lead': lead, if (follow != null) 'follow': follow});

  static AlertIntent? decode(Object? raw) {
    if (raw is! String) return null;
    try {
      final m = jsonDecode(raw) as Map;
      return (
        lead: [for (final x in m['lead'] as List) x as int],
        follow: m['follow'] as int?,
      );
    } catch (_) {
      return null; // unreadable: fall back to shifting existing alerts
    }
  }
}

/// Regenerates task [id]'s alerts for a due change [previous] -> [next] from
/// [intent]: offsets skipped before (past, quiet hours) come back when the
/// new time allows; ones now past/quiet are cancelled. Rows are reused per
/// kind+offset (same notification id, re-armed), new ones get fresh ids,
/// leftovers get a durable cancel intent.
Future<void> _replan(Transaction tx, int id, int previous, int next,
    String title, AlertIntent intent) async {
  final prefs = await _readPrefs(tx);
  final at = DateTime.fromMillisecondsSinceEpoch(next);
  final plan = reminderPlan(
      at,
      prefs.copyWith(
          leadMinutes: intent.lead.isEmpty ? null : intent.lead,
          followUpMinutes: intent.follow),
      multiple: intent.lead.isNotEmpty,
      followUp: intent.follow != null,
      now: DateTime.now());
  String key(String kind, int offsetMin) =>
      kind == 'pre' ? 'pre:$offsetMin' : kind;
  final spare = <String, Reminder>{};
  for (final r in (await tx.query('reminders',
          where: 'task_id = ? AND enabled = 1', whereArgs: [id]))
      .map(Reminder.new)) {
    final k =
        key(r.kind, (previous - r.triggerAt.millisecondsSinceEpoch) ~/ 60000);
    if (spare.containsKey(k)) {
      await tx.update('reminders', {'enabled': 0, 'sync': 'cancel'},
          where: 'id = ?', whereArgs: [r.id]);
    } else {
      spare[k] = r;
    }
  }
  for (final p in plan) {
    final r = spare.remove(key(p.kind, at.difference(p.at).inMinutes));
    final v = {'trigger_at': p.at.millisecondsSinceEpoch, 'sync': 'schedule'};
    if (r != null) {
      await tx.update('reminders', v, where: 'id = ?', whereArgs: [r.id]);
    } else {
      await tx.insert('reminders', {
        ...v,
        'task_id': id,
        'kind': p.kind,
        'enabled': 1,
        'title': p.kind == 'follow_up' ? followUpText(title) : title,
      });
    }
  }
  for (final r in spare.values) {
    await tx.update('reminders', {'enabled': 0, 'sync': 'cancel'},
        where: 'id = ?', whereArgs: [r.id]);
  }
}

/// The alerts for an event at [at]. The event-time alert is always kept (the
/// user asked for it); early alerts and the follow-up are skipped when already
/// past or inside quiet hours. Pure, so callers can show exact times first.
List<PlannedAlert> reminderPlan(DateTime at, ReminderPreferences prefs,
    {required bool multiple, required bool followUp, required DateTime now}) {
  final extra = <PlannedAlert>[
    if (multiple)
      for (final m in prefs.leadMinutes)
        (kind: 'pre', at: at.subtract(Duration(minutes: m))),
    if (followUp)
      (kind: 'follow_up', at: at.add(Duration(minutes: prefs.followUpMinutes))),
  ].where((p) => p.at.isAfter(now) && !prefs.isQuiet(p.at));
  return [...extra, (kind: 'reminder', at: at)]
    ..sort((a, b) => a.at.compareTo(b.at));
}

class Message {
  final String role, content;
  final DateTime? createdAt;

  /// The `conversations` row id, when the message came from the database.
  /// The stable identity a per-turn mood record anchors to (never text or
  /// timestamps, which are not unique).
  final int? id;

  /// Set on proactive check-ins: the task it is about and its kind
  /// (e.g. 'nudge', 'follow_up', 'daily', 'review').
  final int? taskId;
  final String? kind;
  Message(this.role, this.content,
      {this.id, this.createdAt, this.taskId, this.kind});

  Message._row(Map<String, Object?> m)
      : this(m['role'] as String, m['content'] as String,
            id: m['id'] as int?,
            createdAt: _dt(m['created_at']),
            taskId: m['task_id'] as int?,
            kind: m['kind'] as String?);
}

class ChatSummary {
  final String id, title;
  final DateTime updatedAt;
  final bool isMain;
  ChatSummary(this.id, this.title, this.updatedAt, {this.isMain = false});
}

/// Proactive-delivery key of one alarm occurrence. A reused alert row gets a
/// new key per trigger time, so each daily occurrence is delivered once.
String alertKey(Reminder r) =>
    'alert:${r.id}:${r.triggerAt.millisecondsSinceEpoch}';

/// One evening review per local calendar day.
String reviewKey(DateTime day) => 'review:${dayKey(day)}';

/// Local calendar day as yyyy-mm-dd.
String dayKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

class ConversationRepo {
  final Database db;
  ConversationRepo(this.db);

  /// The one chat proactive messages go to. Recreated on the next delivery
  /// if the user deletes it.
  static const mainChatId = 'main';

  static String newChatId() => DateTime.now().microsecondsSinceEpoch.toString();

  /// Makes sure the main chat row exists (empty title; label it in the UI).
  Future<void> ensureMainChat() async {
    final t = _now();
    await db.insert('chats',
        {'id': mainChatId, 'title': '', 'created_at': t, 'updated_at': t},
        conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  /// Adds a proactive check-in to the main chat once per occurrence [key]
  /// (see [alertKey], [reviewKey]). Key and message commit in one
  /// transaction, so a retry, restart, or second delivery path (alarm and
  /// app reconcile) adds nothing. True = newly added. Deleting the chat
  /// keeps the key, so old occurrences are never replayed.
  Future<bool> addProactive(String key, String content,
          {int? taskId, required String kind}) =>
      db.transaction((tx) async {
        if ((await tx
                .query('proactive_events', where: 'key = ?', whereArgs: [key]))
            .isNotEmpty) {
          return false;
        }
        await tx.insert('proactive_events',
            {'key': key, 'task_id': taskId, 'created_at': _now()});
        await _insert(tx, mainChatId, 'assistant', content,
            taskId: taskId, kind: kind);
        return true;
      });

  /// Whether occurrence [key] was already delivered by [addProactive].
  Future<bool> delivered(String key) async =>
      (await db.query('proactive_events', where: 'key = ?', whereArgs: [key]))
          .isNotEmpty;

  /// The user's own messages from every chat sharing a word with [query],
  /// most shared words first, then newest: context is global, chats only
  /// organize display. The caller drops its current turn if already saved.
  Future<List<Message>> relevant(String query,
      {int limit = 5, int? excludeId}) async {
    final ts = MemoryRepo.terms(query);
    if (ts.isEmpty) return [];
    final where = <String>[
      "role = 'user'",
      "(${ts.map((_) => 'content LIKE ?').join(' OR ')})",
    ];
    final args = <Object?>[for (final t in ts) '%$t%'];
    if (excludeId != null) {
      where.add('id != ?');
      args.add(excludeId);
    }
    final rows = await db.query('conversations',
        where: where.join(' AND '),
        whereArgs: args,
        orderBy: 'id DESC',
        limit:
            200); // shortcut: scan the newest 200 hits; add FTS when chat search becomes slow.
    int hits(Map<String, Object?> r) {
      final c = (r['content'] as String).toLowerCase();
      return ts.where(c.contains).length;
    }

    final ranked = [...rows]..sort((a, b) => hits(b) - hits(a) != 0
        ? hits(b) - hits(a)
        : (b['id'] as int) - (a['id'] as int));
    return ranked.take(limit).map(Message._row).toList();
  }

  /// Persists an empty chat row so it shows up in [listChats] before any message.
  Future<String> createChat() async {
    final id = newChatId(), t = _now();
    await db.insert(
        'chats', {'id': id, 'title': '', 'created_at': t, 'updated_at': t},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return id;
  }

  /// Adds a message and creates/touches its chat row (title = first user message).
  Future<int> add(String session, String role, String content) =>
      db.transaction((tx) => _insert(tx, session, role, content));

  static Future<int> _insert(
      Transaction tx, String session, String role, String content,
      {int? taskId, String? kind}) async {
    final t = _now();
    final id = await tx.insert('conversations', {
      'session_id': session,
      'role': role,
      'content': content,
      'created_at': t,
      if (taskId != null) 'task_id': taskId,
      if (kind != null) 'kind': kind,
    });
    await tx.insert(
        'chats', {'id': session, 'title': '', 'created_at': t, 'updated_at': t},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    await tx.rawUpdate(
        "UPDATE chats SET updated_at = ?, title = CASE WHEN title = '' AND ? = 'user' "
        'THEN substr(?, 1, 60) ELSE title END WHERE id = ?',
        [t, role, content, session]);
    return id;
  }

  /// Newest first.
  Future<List<ChatSummary>> listChats() async =>
      (await db.query('chats', orderBy: 'updated_at DESC, id DESC'))
          .map((r) => ChatSummary(
              r['id'] as String, r['title'] as String, _dt(r['updated_at'])!,
              isMain: r['id'] == mainChatId))
          .toList();

  /// Every message of the chat, oldest first.
  Future<List<Message>> messages(String session) async =>
      (await db.query('conversations',
              where: 'session_id = ?', whereArgs: [session], orderBy: 'id'))
          .map(Message._row)
          .toList();

  Future<void> deleteChat(String id) => db.transaction((tx) async {
        await tx.delete('pending_clarifications',
            where: 'chat_id = ?', whereArgs: [id]);
        await tx
            .delete('conversations', where: 'session_id = ?', whereArgs: [id]);
        await tx.delete('chats', where: 'id = ?', whereArgs: [id]);
      });

  /// Last [n] messages of the session, oldest first.
  Future<List<Message>> recent(String session,
      {int n = 8, int? excludeId}) async {
    final where = <String>['session_id = ?'];
    final args = <Object?>[session];
    if (excludeId != null) {
      where.add('id != ?');
      args.add(excludeId);
    }
    final r = await db.query('conversations',
        where: where.join(' AND '),
        whereArgs: args,
        orderBy: 'id DESC',
        limit: n);
    return r.reversed.map(Message._row).toList();
  }
}

/// Per-turn mascot mood records (schema v9, see `_createMessageMoods`).
/// Rows are keyed by the user message's `conversations` id; the mood values
/// themselves are primitives here — the typed record lives in
/// `lib/mascot/mascot_emotion.dart` ([TurnMood.fromDbRow]), keeping this
/// repository free of the mascot import.
class MoodRepo {
  final Database db;
  MoodRepo(this.db);

  /// Upserts the mood of one submitted user turn. [mood] null = unknown.
  Future<void> save({
    required int messageId,
    required String chatId,
    required String source,
    String? mood,
    double intensity = 0.25,
    double? confidence,
  }) async {
    await db.insert(
        'message_moods',
        {
          'message_id': messageId,
          'chat_id': chatId,
          'mood': mood,
          'intensity': intensity,
          'confidence': confidence,
          'source': source,
          'created_at': _now(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Every stored mood row of one chat, keyed by message id.
  Future<Map<int, Map<String, Object?>>> rowsForChat(String chatId) async {
    final rows = await db
        .query('message_moods', where: 'chat_id = ?', whereArgs: [chatId]);
    return {for (final r in rows) r['message_id'] as int: r};
  }
}

class Memory {
  final int id;
  final String content, category;
  final double importance;
  final DateTime? createdAt, updatedAt, lastAccessedAt, observedAtUtc;
  final String? opId, source, status, contentHash, subjectKey, attributeKey, factDate;
  final int? supersededBy, observationOffsetMin;

  Memory(Map<String, Object?> r)
      : id = r['id'] as int,
        content = r['content'] as String,
        category = r['category'] as String,
        importance = (r['importance'] as num).toDouble(),
        createdAt = _dt(r['created_at']),
        updatedAt = _dt(r['updated_at']),
        lastAccessedAt = _dt(r['last_accessed_at']),
        opId = r['op_id'] as String?,
        source = r['source'] as String?,
        status = r['status'] as String? ?? 'active',
        supersededBy = r['superseded_by'] as int?,
        contentHash = r['content_hash'] as String?,
        subjectKey = r['subject_key'] as String?,
        attributeKey = r['attribute_key'] as String?,
        observedAtUtc = _dt(r['observed_at_utc']),
        observationOffsetMin = r['observation_offset_min'] as int?,
        factDate = r['fact_date'] as String?;

  bool get isActive => status == 'active';

  @override
  String toString() => content;
}

class MemorySlot {
  final String subject;
  final String slot;
  const MemorySlot(this.subject, this.slot);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemorySlot &&
          other.subject.toLowerCase() == subject.toLowerCase() &&
          other.slot.toLowerCase() == slot.toLowerCase();

  @override
  int get hashCode => Object.hash(subject.toLowerCase(), slot.toLowerCase());

  @override
  String toString() => '$subject:$slot';
}

String _drinkAttribute(String value) {
  if (value.contains('sugar') || value.contains('sweet')) return 'sugar';
  if (value.contains('milk')) return 'milk';
  if (RegExp(r'\b(?:hot|cold|iced)\b').hasMatch(value)) return 'temperature';
  return 'kind';
}

MemorySlot? extractMemorySlot(String content) {
  final c = content.trim().toLowerCase();
  String subject = 'user';
  String rest = c;

  if (c.startsWith('user ')) {
    subject = 'user';
    rest = c.substring(5).trim();
  } else if (c.startsWith("user's ")) {
    subject = 'user';
    rest = c.substring(7).trim();
  } else if (c.startsWith('i ')) {
    subject = 'user';
    rest = c.substring(2).trim();
  } else if (c.startsWith('my ')) {
    subject = 'user';
    rest = c.substring(3).trim();
  } else {
    final m = RegExp(
            r'^([a-z]+)\s+(?:prefers?|likes?|loves?|hates?|dislikes?|lives?|works?)\b')
        .firstMatch(c);
    if (m != null) {
      subject = m.group(1)!;
      rest = c.substring(subject.length).trim();
    } else {
      return null;
    }
  }

  // Answer/reply length or tone style (e.g. short answers, concise answers, detailed answers)
  if (RegExp(r'\b(?:answers?|replies|responses?)\b').hasMatch(rest) &&
      RegExp(r'\b(?:short|concise|brief|detailed|long|bullet)\b')
          .hasMatch(rest)) {
    return MemorySlot(subject, 'pref:answer_style');
  }

  // Drink preference
  if (RegExp(r'\b(?:tea|coffee|drink|drinks|beverage)\b').hasMatch(rest) &&
      RegExp(r'\b(?:prefers?|likes?|loves?|hates?|dislikes?|drinks?)\b')
          .hasMatch(rest)) {
    return MemorySlot(subject, 'pref:drink:${_drinkAttribute(rest)}');
  }

  // Meeting time preference
  if (RegExp(r'\bmeetings?\b').hasMatch(rest) &&
      RegExp(r'\b(?:morning|afternoon|evening)\b').hasMatch(rest)) {
    return MemorySlot(subject, 'pref:meeting_time');
  }

  // Residence
  if (RegExp(r'\blives?\s+in\b').hasMatch(rest)) {
    return MemorySlot(subject, 'location:residence');
  }

  // Occupation
  if (RegExp(r'\bworks?\s+as\b').hasMatch(rest) ||
      RegExp(r'\bjob\s+is\b').hasMatch(rest)) {
    return MemorySlot(subject, 'profile:occupation');
  }

  return null;
}

class MemoryRepo {
  final DatabaseExecutor db;
  MemoryRepo(this.db);

  static final _word = RegExp(r'[\p{L}\p{N}]{2,}', unicode: true);
  static const _stop = {
    'the',
    'and',
    'what',
    'did',
    'you',
    'when',
    'do',
    'is',
    'are',
    'about',
    'tell',
    'me',
    'my',
    'for',
    'with',
    'that',
    'this',
    'how',
    'who',
    'have',
  };

  static List<String> terms(String s) => _word
      .allMatches(s.toLowerCase())
      .map((m) => m.group(0)!)
      .where((w) => !_stop.contains(w))
      .toSet()
      .toList();

  /// Stores a memory; an explicit new preference supersedes its prior value;
  /// an exact same-terms duplicate bumps importance.
  Future<int> add(String content,
      {String category = 'fact',
      double importance = 0.5,
      String? opId,
      String? source}) async {
    if (db is Database) {
      return (db as Database).transaction((tx) => MemoryRepo(tx).add(content,
          category: category,
          importance: importance,
          opId: opId,
          source: source));
    }
    content = content.trim();
    String normalized(String value) => value
        .toLowerCase()
        .replaceAll(RegExp(r'[.!?]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final norm = normalized(content);
    final contentHash = sha256.convert(utf8.encode(norm)).toString();
    // Fast deduplication check using indexed content_hash
    for (final r in await db.query('memories',
        columns: ['id', 'content', 'importance'],
        where: "status = 'active' AND content_hash = ?",
        whereArgs: [contentHash])) {
      if (normalized(r['content'] as String) == norm) {
        final imp = ((r['importance'] as num) + 0.1).clamp(0.0, 1.0);
        await db.update(
            'memories',
            {
              'importance': imp,
              'updated_at': _now(),
              if (opId != null) 'op_id': opId,
              if (source != null) 'source': source,
            },
            where: 'id = ?',
            whereArgs: [r['id']]);
        return r['id'] as int;
      }
    }

    // Fast slot superseding check using indexed subject_key & attribute_key
    final newSlot = extractMemorySlot(content);
    final toSupersede = <int>[];
    if (newSlot != null) {
      for (final r in await db.query('memories',
          columns: ['id', 'content'],
          where: "status = 'active' AND subject_key = ? AND attribute_key = ?",
          whereArgs: [newSlot.subject, newSlot.slot])) {
        toSupersede.add(r['id'] as int);
      }
    }

    final t = _now();
    final newId = await db.insert('memories', {
      'content': content,
      'category': category,
      'importance': importance,
      'created_at': t,
      'updated_at': t,
      'status': 'active',
      'content_hash': contentHash,
      'subject_key': newSlot?.subject,
      'attribute_key': newSlot?.slot,
      if (opId != null) 'op_id': opId,
      if (source != null) 'source': source,
    });
    for (final oldId in toSupersede) {
      await supersede(oldId, newId);
    }
    return newId;
  }

  /// Supersedes a prior memory with [newId]: marks it superseded and removes
  /// it from FTS so it leaves all retrieval and prompt contexts.
  Future<void> supersede(int oldId, int newId) async {
    await db.update(
        'memories',
        {
          'status': 'superseded',
          'superseded_by': newId,
          'updated_at': _now(),
        },
        where: 'id = ?',
        whereArgs: [oldId]);
    await db.delete('memories_fts', where: 'docid = ?', whereArgs: [oldId]);
  }

  /// FTS match on active memories, re-ranked by term hits + importance + recency (30-day decay).
  Future<List<Memory>> search(String query, {int limit = 3}) async {
    final ts = terms(query);
    if (ts.isEmpty) return [];
    final rows = (await db.rawQuery(
            'SELECT m.* FROM memories m JOIN memories_fts f ON f.docid = m.id '
            'WHERE memories_fts MATCH ? AND m.status = \'active\'',
            [ts.map((t) => '"$t" OR ${t.replaceAll('"', '')}*').join(' OR ')]))
        .toList();
    final now = _now();
    double score(Map<String, Object?> r) {
      final text = (r['content'] as String).toLowerCase();
      final hits = ts.where(text.contains).length / ts.length;
      final ageDays = (now - (r['updated_at'] as int)) / 86400000;
      return hits * 2 + (r['importance'] as num) + 1 / (1 + ageDays / 30);
    }

    rows.sort((a, b) => score(b).compareTo(score(a)));
    final top = rows.take(limit).toList();
    for (final r in top) {
      await db.update('memories', {'last_accessed_at': now},
          where: 'id = ?', whereArgs: [r['id']]);
    }
    return top.map(Memory.new).toList();
  }

  Future<bool> delete(int id) async {
    await db.delete('memories_fts', where: 'docid = ?', whereArgs: [id]);
    return await db.delete('memories', where: 'id = ?', whereArgs: [id]) > 0;
  }

  Future<List<Memory>> all() async => (await db.query('memories',
          where: "status = 'active'", orderBy: 'id DESC'))
      .map(Memory.new)
      .toList();

  Future<List<Memory>> important({int limit = 3}) async {
    final rows = await db.query('memories',
        where: "status = 'active'",
        orderBy: 'importance DESC, updated_at DESC');
    return rows
        .map(Memory.new)
        .where((memory) => isUsefulPersonalMemory(memory.content))
        .take(limit)
        .toList();
  }

  /// Retrieves relevant active durable memories for injecting into planning
  /// and conversation prompts (bounded, never all rows or static top-3).
  Future<List<Memory>> relevantForContext(String query, {int limit = 3}) async {
    final results = <int, Memory>{};
    for (final m in await search(query, limit: limit)) {
      if (m.isActive && isUsefulPersonalMemory(m.content)) {
        results[m.id] = m;
      }
    }
    if (results.length < limit) {
      final prefs = (await db.query('memories',
              where:
                  "status = 'active' AND (category = 'preference' OR content LIKE '%prefer%')",
              orderBy: 'importance DESC, updated_at DESC',
              limit: limit))
          .map(Memory.new)
          .where((m) => m.isActive && isUsefulPersonalMemory(m.content));
      for (final p in prefs) {
        if (!results.containsKey(p.id)) {
          results[p.id] = p;
          if (results.length >= limit) break;
        }
      }
    }
    return results.values.take(limit).toList();
  }
}

class UserProfile {
  final String name;
  final String occupation;
  final String tone;

  const UserProfile(
      {this.name = '', this.occupation = '', this.tone = 'cheerful'});

  factory UserProfile.fromRow(Map<String, Object?> row) => UserProfile(
        name: row['name'] as String? ?? '',
        occupation: row['occupation'] as String? ?? '',
        tone: row['tone'] as String? ?? 'cheerful',
      );
}

bool isUsefulPersonalMemory(String content) {
  final value = content.trim().toLowerCase();
  if (RegExp(
          r"\b(?:done with|finished|never replied|hasn't replied|tired|exhausted|got back|couldn't make|meeting is over)\b")
      .hasMatch(value)) return false;
  if (value.contains('language model') ||
      value.contains('assistant that helps') ||
      value.contains('various tasks') ||
      value.contains('...')) {
    return false;
  }
  return RegExp(
    r'^(?:user\s+(?:is|works|lives|prefers|likes|loves|hates|dislikes|studies|uses|has|usually|normally|always|never)\b|'
    r"i\s+(?:(?:usually|normally|always|never)\s+)?(?:am|'m|work|live|prefer|like|love|hate|dislike|study|use)\b|"
    r"i\s+have\s+(?:a|an|one|two|three|four|five)\b|my\s+(?:name|job|role|goal|preference|sister|brother|mother|father)\b|[a-z]+\s+(?:prefers?|likes?|loves?|hates?|dislikes?|lives?|works?)\b)",
  ).hasMatch(value);
}

String buildPersonalContext(UserProfile profile, List<String> memories) {
  final parts = <String>[];
  final name = profile.name.trim();
  final occupation = profile.occupation.trim();
  if (name.isNotEmpty && occupation.isNotEmpty) {
    parts.add('The user is $name and works as $occupation.');
  } else if (name.isNotEmpty) {
    parts.add('The user is $name.');
  } else if (occupation.isNotEmpty) {
    parts.add('The user works as $occupation.');
  }
  parts.add('Preferred assistant tone: ${profile.tone}.');
  final useful = memories
      .map((m) => m.trim())
      .where(isUsefulPersonalMemory)
      .take(3)
      .toList();
  if (useful.isNotEmpty)
    parts.add('Important things the user has shared: ${useful.join('; ')}.');
  return parts.join(' ');
}

class ProfileRepo {
  final Database db;
  ProfileRepo(this.db);

  Future<UserProfile?> get() async {
    final rows = await db.query('assistant_profile', where: 'id = 1');
    if (rows.isEmpty || rows.first['onboarding_complete'] != 1) return null;
    return UserProfile.fromRow(rows.first);
  }

  Future<void> save(UserProfile profile) async {
    await db.insert(
        'assistant_profile',
        {
          'id': 1,
          'name': profile.name.trim(),
          'occupation': profile.occupation.trim(),
          'tone': profile.tone,
          'onboarding_complete': 1,
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

/// Notification defaults; a single reminder unless the user opts in.
/// Per-reminder `multiple` / `follow_up` overrides win (see reminderPlan).
class ReminderPreferences {
  final bool multiple, followUp;

  /// Early alerts, minutes before the event (1..1440, at most 3).
  final List<int> leadMinutes;

  /// Follow-up delay after the start, used because the end time is unknown.
  final int followUpMinutes;

  /// Minutes after midnight; both null = no quiet hours. May wrap midnight.
  final int? quietStart, quietEnd;

  const ReminderPreferences(
      {this.multiple = false,
      this.followUp = false,
      this.leadMinutes = const [30, 10],
      this.followUpMinutes = 60,
      this.quietStart,
      this.quietEnd});

  bool get hasQuietHours =>
      quietStart != null && quietEnd != null && quietStart != quietEnd;

  /// Evening review: 30 min before quiet hours start; 21:30 when they're off.
  int get reviewMinute => ((quietStart ?? 22 * 60) - 30) % 1440;

  bool isQuiet(DateTime t) {
    if (!hasQuietHours) return false;
    final m = t.hour * 60 + t.minute, s = quietStart!, e = quietEnd!;
    return s < e ? m >= s && m < e : m >= s || m < e;
  }

  /// Throws [ArgumentError] on out-of-range values instead of saving them.
  ReminderPreferences validated() {
    final leads = leadMinutes.toSet().toList()..sort((a, b) => b - a);
    if (leads.isEmpty ||
        leads.length > 3 ||
        leads.any((m) => m < 1 || m > 1440)) {
      throw ArgumentError(
          'Early alerts must be 1-3 values between 1 and 1440 minutes.');
    }
    if (followUpMinutes < 5 || followUpMinutes > 1440) {
      throw ArgumentError('Follow-up delay must be 5-1440 minutes.');
    }
    if ((quietStart == null) != (quietEnd == null) ||
        [quietStart, quietEnd].any((m) => m != null && (m < 0 || m >= 1440))) {
      throw ArgumentError('Quiet hours need a valid start and end.');
    }
    return copyWith(leadMinutes: leads);
  }

  ReminderPreferences copyWith(
          {bool? multiple,
          bool? followUp,
          List<int>? leadMinutes,
          int? followUpMinutes,
          (int, int)? quiet,
          bool clearQuiet = false}) =>
      ReminderPreferences(
          multiple: multiple ?? this.multiple,
          followUp: followUp ?? this.followUp,
          leadMinutes: leadMinutes ?? this.leadMinutes,
          followUpMinutes: followUpMinutes ?? this.followUpMinutes,
          quietStart: clearQuiet ? null : quiet?.$1 ?? quietStart,
          quietEnd: clearQuiet ? null : quiet?.$2 ?? quietEnd);
}

class ReminderPreferencesRepo {
  final Database db;

  /// Called after any committed settings change to reconcile platform alarms.
  Future<void> Function()? onRemindersChanged;
  ReminderPreferencesRepo(this.db);

  Future<ReminderPreferences> get() => _readPrefs(db);

  /// Turning follow-ups off also cancels every pending follow-up, atomically.
  Future<void> save(ReminderPreferences value) async {
    value = value.validated();
    await db.transaction((tx) async {
      await tx.insert(
          'assistant_preferences',
          {
            'id': 1,
            'multiple': value.multiple ? 1 : 0,
            'follow_up': value.followUp ? 1 : 0,
            'lead_minutes': value.leadMinutes.join(','),
            'follow_up_minutes': value.followUpMinutes,
            'quiet_start': value.quietStart,
            'quiet_end': value.quietEnd,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      if (value.followUp) return 0;
      // Stored plans drop their follow-up too, so a later move can't bring it back.
      for (final t in await tx.query('tasks',
          columns: ['id', 'alert_plan'], where: 'alert_plan IS NOT NULL')) {
        final i = AlertIntentJson.decode(t['alert_plan']);
        if (i == null || i.follow == null) continue;
        await tx.update(
            'tasks', {'alert_plan': (lead: i.lead, follow: null).encode()},
            where: 'id = ?', whereArgs: [t['id']]);
      }
      return tx.update('reminders', {'enabled': 0, 'sync': 'cancel'},
          where: "kind = 'follow_up' AND enabled = 1");
    });
    try {
      await onRemindersChanged?.call();
    } catch (_) {} // committed settings remain saved; startup retries delivery
  }
}

/// Never saved = default quiet hours 22:00-07:00. A saved row with null quiet
/// hours is an explicit "off"; saved choices are preserved across upgrades.
Future<ReminderPreferences> _readPrefs(DatabaseExecutor db) async {
  final rows = await db.query('assistant_preferences', where: 'id = 1');
  if (rows.isEmpty)
    return const ReminderPreferences(quietStart: 22 * 60, quietEnd: 7 * 60);
  final r = rows.first;
  final leads = (r['lead_minutes'] as String)
      .split(',')
      .map(int.tryParse)
      .whereType<int>()
      .toList();
  return ReminderPreferences(
      multiple: r['multiple'] == 1,
      followUp: r['follow_up'] == 1,
      leadMinutes: leads.isEmpty ? const [30, 10] : leads,
      followUpMinutes: r['follow_up_minutes'] as int,
      quietStart: r['quiet_start'] as int?,
      quietEnd: r['quiet_end'] as int?);
}

/// The open clarification of each chat, as the JSON the assistant wrote.
class PendingRepo {
  final Database db;
  PendingRepo(this.db);

  Future<String?> get(String chatId) async {
    final r = await db.query('pending_clarifications',
        where: 'chat_id = ?', whereArgs: [chatId]);
    return r.isEmpty ? null : r.first['draft'] as String;
  }

  Future<void> put(String chatId, String draft) => db.insert(
      'pending_clarifications',
      {'chat_id': chatId, 'draft': draft, 'updated_at': _now()},
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> clear(String chatId) => db.delete('pending_clarifications',
      where: 'chat_id = ?', whereArgs: [chatId]);

  /// All open clarifications and picks across every chat, newest first.
  Future<List<({String chatId, String draft, DateTime updatedAt})>>
      allOpen() async {
    final rows =
        await db.query('pending_clarifications', orderBy: 'updated_at DESC');
    return [
      for (final r in rows)
        (
          chatId: r['chat_id'] as String,
          draft: r['draft'] as String,
          updatedAt:
              DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
        )
    ];
  }
}

/// One submitted assistant turn's durable identity (v7 `operations`).
/// Statuses: started (message received; nothing written yet), executing (a
/// validated write is about to run; [action] holds it), committed (the write
/// finished; [receipt] holds its facts), replied / no_write (the turn's reply
/// is final and stored in [receipt]), failed, abandoned (cancelled or
/// interrupted before any write). No message text is stored, only a hash.
class Operation {
  final String id, chatId, textHash, status;
  final String? action, receipt;
  final DateTime createdAt, updatedAt;
  Operation(Map<String, Object?> r)
      : id = r['op_id'] as String,
        chatId = r['chat_id'] as String,
        textHash = r['text_hash'] as String,
        status = r['status'] as String,
        action = r['action'] as String?,
        receipt = r['receipt'] as String?,
        createdAt = _dt(r['created_at'])!,
        updatedAt = _dt(r['updated_at'])!;
}

class OperationJournal {
  final Database db;
  final Set<String> _activeOps = {};

  OperationJournal(this.db);

  void registerActive(String id) => _activeOps.add(id);
  void unregisterActive(String id) => _activeOps.remove(id);
  bool isLocallyActive(String id) => _activeOps.contains(id);

  static const started = 'started',
      executing = 'executing',
      committed = 'committed',
      replied = 'replied',
      noWrite = 'no_write',
      failed = 'failed',
      abandoned = 'abandoned';

  Future<Operation?> get(String id) async {
    final r = await db.query('operations', where: 'op_id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Operation(r.first);
  }

  /// Records a new submitted turn; an existing id is left as it is.
  Future<void> begin(String id, String chatId, String textHash) => db.insert(
      'operations',
      {
        'op_id': id,
        'chat_id': chatId,
        'text_hash': textHash,
        'status': started,
        'created_at': _now(),
        'updated_at': _now(),
      },
      conflictAlgorithm: ConflictAlgorithm.ignore);

  Future<void> mark(String id, String status,
          {String? action, String? receipt}) =>
      db.update(
          'operations',
          {
            'status': status,
            if (action != null) 'action': action,
            if (receipt != null) 'receipt': receipt,
            'updated_at': _now(),
          },
          where: 'op_id = ?',
          whereArgs: [id]);

  /// Startup: turns left `started`/`executing` by a crash are settled without
  /// running anything. A write whose rows exist (stamped `op_id`) is
  /// committed; anything else is abandoned only if it is not currently active
  /// in memory or recently updated within [olderThan] (defaulting to 2 minutes
  /// to avoid abandoning turns still computing in an engine).
  /// Returns the ids settled.
  Future<List<String>> recoverStale({
    Duration olderThan = const Duration(minutes: 2),
    Set<String>? activeOpIds,
  }) async {
    final cutoff =
        olderThan == Duration.zero ? null : _now() - olderThan.inMilliseconds;
    final out = <String>[];
    for (final r in await db.query('operations',
        where: 'status IN (?, ?)', whereArgs: [started, executing])) {
      final id = r['op_id'] as String;
      if (_activeOps.contains(id) ||
          (activeOpIds != null && activeOpIds.contains(id))) {
        continue;
      }
      final updated = r['updated_at'] as int;
      if (cutoff != null && updated > cutoff) {
        continue;
      }
      final rows = (await db.query('tasks',
                  columns: ['id'], where: 'op_id = ?', whereArgs: [id]))
              .length +
          (await db.query('reminders',
                  columns: ['id'], where: 'op_id = ?', whereArgs: [id]))
              .length;
      await mark(id, rows > 0 ? committed : abandoned);
      out.add(id);
    }
    return out;
  }
}

typedef ReviewAgenda = ({
  List<Task> unresolved,
  List<Task> finished,
  List<Task> tomorrow
});

/// Evening-review participation. Nothing here moves deadlines or creates
/// alerts: ignored tasks simply stay pending and are raised again.
class ReviewRepo {
  final Database db;
  ReviewRepo(this.db);

  /// Read from current rows at delivery time, so done, deleted or moved tasks
  /// never appear stale. unresolved: pending and due before tomorrow
  /// (overdue included), plus pending tasks an earlier review raised that were
  /// never answered, whatever their date. finished: completed on [day].
  /// tomorrow: pending, due tomorrow, not already unresolved.
  Future<ReviewAgenda> agenda(DateTime day) async {
    final start = DateTime(day.year, day.month, day.day).millisecondsSinceEpoch;
    final t1 =
        DateTime(day.year, day.month, day.day + 1).millisecondsSinceEpoch;
    final t2 =
        DateTime(day.year, day.month, day.day + 2).millisecondsSinceEpoch;
    Future<List<Task>> q(String where, List<Object?> args) async =>
        (await db.rawQuery(
                'SELECT * FROM tasks t WHERE $where ORDER BY due_at IS NULL, due_at, id',
                args))
            .map(Task.new)
            .toList();
    final unresolved = await q(
        "status = 'pending' AND (due_at < ? OR EXISTS (SELECT 1 FROM review_items r "
        'WHERE r.task_id = t.id AND r.answered = 0))',
        [t1]);
    final seen = {for (final t in unresolved) t.id};
    return (
      unresolved: unresolved,
      finished: await q(
          "status = 'done' AND completed_at >= ? AND completed_at < ?",
          [start, t1]),
      tomorrow: [
        for (final t in await q(
            "status = 'pending' AND due_at >= ? AND due_at < ?", [t1, t2]))
          if (!seen.contains(t.id)) t
      ],
    );
  }

  /// Records the tasks the review of [day] asked about (idempotent).
  Future<void> record(DateTime day, Iterable<int> taskIds) =>
      db.transaction((tx) async {
        for (final id in taskIds) {
          await tx.insert('review_items', {'day': dayKey(day), 'task_id': id},
              conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      });

  /// The user answered about [taskId] (in any chat): its open review rows close.
  Future<void> answered(int taskId) =>
      db.update('review_items', {'answered': 1},
          where: 'task_id = ? AND answered = 0', whereArgs: [taskId]);

  /// Pending task id -> reviews that raised it without an answer.
  Future<Map<int, int>> ignoredCounts() async => {
        for (final r in await db.rawQuery(
            'SELECT r.task_id, COUNT(*) AS n FROM review_items r JOIN tasks t ON t.id = r.task_id '
            "WHERE r.answered = 0 AND t.status = 'pending' GROUP BY r.task_id"))
          r['task_id'] as int: r['n'] as int
      };
}
