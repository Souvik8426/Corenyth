import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

import '../assistant/core_policy.dart' show memoryInstructionIssue;
import '../assistant/rule_engine.dart' show RuleEngine;
import '../assistant/temporal.dart' show factExpiresAt, resolveFactDate;

int _now() => DateTime.now().millisecondsSinceEpoch;
DateTime? _dt(Object? ms) =>
    ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms as int);

/// Only the canonical positive integer suffix emitted for indexed creates.
/// The caller must still verify that the returned parent really exists.
String? indexedOperationParent(String id) {
  final split = id.lastIndexOf('#');
  if (split <= 0) return null;
  final suffix = id.substring(split + 1);
  final index = int.tryParse(suffix);
  return index != null && index > 0 && index.toString() == suffix
      ? id.substring(0, split)
      : null;
}

int _storageSavepoint = 0;
final _storageTransactions = Expando<Future<void>>('storage transactions');

/// A storage operation must roll back even if its caller catches the error
/// inside a larger transaction. Never open a second connection/transaction.
/// Serialize sibling storage calls on the same outer transaction: SQLite
/// savepoints are a stack, so releasing one can destroy a sibling's savepoint.
/// All memory writes participate, including ordinary add and access stamps.
/// Actions use private non-queuing helpers on tx, never re-enter this queue.
Future<T> _storageTransaction<T>(
  DatabaseExecutor db,
  Future<T> Function(DatabaseExecutor tx) action,
) async {
  if (db is Database) return db.transaction(action);
  if (db is! Transaction) {
    throw StateError('Storage requires a database or transaction');
  }
  final previous = _storageTransactions[db] ?? Future<void>.value();
  final completed = Completer<void>();
  _storageTransactions[db] = completed.future;
  try {
    await previous;
    final name = 'suggestion_${_storageSavepoint++}';
    await db.execute('SAVEPOINT $name');
    try {
      final result = await action(db);
      await db.execute('RELEASE SAVEPOINT $name');
      return result;
    } catch (_) {
      await db.execute('ROLLBACK TO SAVEPOINT $name');
      await db.execute('RELEASE SAVEPOINT $name');
      rethrow;
    }
  } finally {
    if (identical(_storageTransactions[db], completed.future)) {
      _storageTransactions[db] = null;
    }
    // The queue tracks completion, not success: a caught failure cannot block
    // subsequent siblings or leak an unhandled error through the queue tail.
    completed.complete();
  }
}

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
    final values = <String, Object?>{
      'title': title,
      'notes': notes,
      'created_at': _now(),
      'due_at': due?.millisecondsSinceEpoch,
      'priority': priority,
      if (opId != null) 'op_id': opId,
    };
    if (opId == null) return (await get(await db.insert('tasks', values)))!;
    // Stamp check and insert in one transaction: of two concurrent retries
    // of the same operation, the loser returns the winner's row.
    return db.transaction((tx) async {
      final prior = await tx.query('tasks',
          where: 'op_id = ?', whereArgs: [opId], orderBy: 'id', limit: 1);
      if (prior.isNotEmpty) return Task(prior.first);
      final id = await tx.insert('tasks', values);
      return Task((await tx.query('tasks', where: 'id = ?', whereArgs: [id]))
          .single);
    });
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
      if (opId != null) {
        // Stamp check and insert in one transaction (see [create]).
        final prior = await tx.query('tasks',
            where: 'op_id = ?', whereArgs: [opId], orderBy: 'id', limit: 1);
        if (prior.isNotEmpty) return prior.first['id'] as int;
      }
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
        if (opId != null) {
          // Stamp check inside the insert transaction: a retry that lost the
          // race returns the committed alerts instead of writing a second plan.
          final done = taskId == null
              ? await tx.query('tasks',
                  columns: ['id'], where: 'op_id = ?', whereArgs: [opId], limit: 1)
              : await tx.query('reminders',
                  columns: ['id'], where: 'op_id = ?', whereArgs: [opId], limit: 1);
          if (done.isNotEmpty) {
            return [
              for (final r in await tx.query('reminders',
                  where: 'op_id = ?', whereArgs: [opId], orderBy: 'trigger_at'))
                Reminder(r)
            ];
          }
        }
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
    final values = <String, Object?>{
      'title': title,
      'trigger_at': at.millisecondsSinceEpoch,
      'task_id': taskId,
      'sync': 'schedule',
      if (opId != null) 'op_id': opId,
    };
    if (opId == null) return (await get(await db.insert('reminders', values)))!;
    // Stamp check and insert in one transaction (see [TaskRepo.create]).
    return db.transaction((tx) async {
      final prior = await tx.query('reminders',
          where: 'op_id = ?', whereArgs: [opId], orderBy: 'id', limit: 1);
      if (prior.isNotEmpty) return Reminder(prior.first);
      final id = await tx.insert('reminders', values);
      return Reminder(
          (await tx.query('reminders', where: 'id = ?', whereArgs: [id]))
              .single);
    });
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
      DatabaseExecutor tx, String session, String role, String content,
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

/// A bounded batch counts rows examined, including rows the caller must skip.
class ExtractionBatch {
  final int lastMessageId;
  final List<Message> messages;
  ExtractionBatch(this.lastMessageId, List<Message> messages)
      : messages = List.unmodifiable(messages);
}

enum ExtractionSkipResult { skipped, notProvenOrStale }

/// Storage substrate only. Nothing calls this automatically or enables model
/// work. An absent state row denies reads and publication for that chat.
class ExtractionRepo {
  final DatabaseExecutor db;
  ExtractionRepo(this.db);

  /// Call only on explicit opt-in, including re-opt-in after clearing/import.
  /// Baseline every current chat at its latest row (including assistant rows),
  /// so old conversations never silently become extraction input.
  Future<void> initializeAtLatest() => _storageTransaction(db, (tx) async {
        await tx.delete('extraction_state');
        await tx
            .execute('''INSERT INTO extraction_state(chat_id, last_message_id)
          SELECT chats.id, COALESCE(MAX(c.id), 0) FROM chats
          LEFT JOIN conversations c ON c.session_id = chats.id
          GROUP BY chats.id''');
      });

  /// Opt-out revokes storage publication as well as future batch reads.
  /// The future lifecycle owner must also cancel its in-flight model work.
  Future<void> clear() => _storageTransaction(db, (tx) async {
        await tx.delete('extraction_state');
      });

  Future<ExtractionBatch?> nextBatch(String chatId) =>
      _storageTransaction(db, (tx) async {
        final states = await tx.query(
          'extraction_state',
          where: 'chat_id = ?',
          whereArgs: [chatId],
        );
        if (states.isEmpty) return null;
        final last = states.single['last_message_id'] as int;
        final rows = await tx.query(
          'conversations',
          where: "session_id = ? AND role = 'user' AND id > ?",
          whereArgs: [chatId, last],
          orderBy: 'id',
          limit: 5,
        );
        return ExtractionBatch(last, rows.map(Message._row).toList());
      });

  /// For a caller-validated skip or valid remember:false only. Invalid output,
  /// cancellation, and model errors must never call this. Enforces ascending
  /// processing and compare-and-set against the batch's captured watermark.
  Future<bool> advance(
    String chatId,
    int messageId, {
    required int expectedLastMessageId,
  }) =>
      _storageTransaction(db, (tx) async {
        if (await _nextSource(tx, chatId, messageId, expectedLastMessageId) ==
            null) {
          return false;
        }
        await tx.update(
          'extraction_state',
          {'last_message_id': messageId},
          where: 'chat_id = ?',
          whereArgs: [chatId],
        );
        return true;
      });

  /// Proof and watermark publication are one transaction, never a separate
  /// positive marker read followed by advance. Opt-out/order/CAS all apply.
  Future<ExtractionSkipResult> skipIfMemoryWritten(
    String chatId,
    int messageId, {
    required int expectedLastMessageId,
  }) =>
      _storageTransaction(db, (tx) async {
        if (await _nextSource(tx, chatId, messageId, expectedLastMessageId) ==
                null ||
            !await MemoryWriteSource.wasWritten(tx, chatId, messageId)) {
          return ExtractionSkipResult.notProvenOrStale;
        }
        await tx.update('extraction_state', {'last_message_id': messageId},
            where: 'chat_id = ?', whereArgs: [chatId]);
        return ExtractionSkipResult.skipped;
      });

  static Future<Map<String, Object?>?> _nextSource(
    DatabaseExecutor tx,
    String chatId,
    int messageId,
    int expectedLastMessageId,
  ) async {
    final rows = await tx.rawQuery(
      '''SELECT c.* FROM conversations c
      JOIN extraction_state s ON s.chat_id = c.session_id
      WHERE s.chat_id = ? AND s.last_message_id = ?
        AND c.role = 'user' AND c.id > s.last_message_id
      ORDER BY c.id LIMIT 1''',
      [chatId, expectedLastMessageId],
    );
    return rows.isNotEmpty && rows.single['id'] == messageId
        ? rows.single
        : null;
  }
}

/// Content-free identity, checked again inside the memory transaction.
class MemoryWriteSource {
  final String operationId, chatId;
  final int messageId;
  const MemoryWriteSource(this.operationId, this.chatId, this.messageId);

  static Future<MemoryWriteSource?> forOperation(
      DatabaseExecutor db, String operationId) async {
    final rows = await db.rawQuery('''SELECT c.id, o.chat_id FROM operations o
      JOIN conversations c ON c.id = o.source_message_id
      WHERE o.op_id = ? AND c.role = 'user' AND c.session_id = o.chat_id''',
        [operationId]);
    if (rows.isEmpty) return null;
    return MemoryWriteSource(operationId, rows.single['chat_id'] as String,
        rows.single['id'] as int);
  }

  static Future<bool> wasWritten(
          DatabaseExecutor db, String chatId, int messageId) async =>
      (await db.rawQuery('''SELECT w.message_id FROM memory_write_sources w
      JOIN conversations c ON c.id = w.message_id
      JOIN operations o ON o.source_message_id = c.id
      WHERE c.id = ? AND c.session_id = ? AND c.role = 'user'
        AND o.chat_id = c.session_id''', [messageId, chatId])).isNotEmpty;
}

class MemorySourceUnverified implements Exception {}

class Memory {
  final int id;
  final String content, category;
  final double importance;
  final DateTime? createdAt, updatedAt, lastAccessedAt, observedAtUtc;
  final String? opId,
      source,
      status,
      contentHash,
      subjectKey,
      attributeKey,
      factDate;
  final int? supersededBy, observationOffsetMin;

  /// When this time-bound fact stops being current (plan 1.4), UTC epoch
  /// ms; null when it never expires. Reads skip it from that instant on.
  final int? expiresAt;

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
        factDate = r['fact_date'] as String?,
        expiresAt = r['expires_at'] as int?;

  bool get isActive => status == 'active';

  /// [content] with its absolute fact date, for prompts and replies.
  String get dated => withFactDate(content, factDate);

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

enum ForgetEvidence { exact, slot, candidates, none }

class ForgetMatch {
  final ForgetEvidence evidence;
  final List<Memory> memories;
  final bool severalMatch;
  const ForgetMatch(this.evidence, this.memories, {this.severalMatch = false});
}

enum RestoreStatus { restored, duplicate, slotTaken, gone }

enum SuggestionDecision { accepted, rejected, gone }

class SuggestionDecisionResult {
  final SuggestionDecision status;

  /// The active memory returned by normal add/deduplication on acceptance.
  final int? memoryId;
  const SuggestionDecisionResult(this.status, [this.memoryId]);
}

class RestoreResult {
  final RestoreStatus status;
  final int? id;
  const RestoreResult(this.status, [this.id]);
}

/// Plan 1.5: new memory text that reads as an instruction to the assistant
/// ([memoryInstructionIssue]). Thrown by [MemoryRepo.add] and
/// [MemoryRepo.addCorrection] before anything is written.
class MemoryInstructionRejected implements Exception {
  /// The user-facing reason (the shared refusal wording).
  final String reason;
  const MemoryInstructionRejected(this.reason);
  @override
  String toString() => 'MemoryInstructionRejected: $reason';
}

/// Legacy/imported supersede events have no replacement-memory identity.
/// Automatic actions refuse to guess and keep the history; the user's own
/// erase (deletePermanently, rejectSuggestion) redacts those copies instead.
class MemoryPrivacyBlocked implements Exception {
  final int memoryId;
  final int historyId;

  static const explanation =
      'Older memory history contains copied text that cannot be safely linked '
      'to a specific memory. Automatic purge and accepting suggestions are '
      'blocked. Memory and history text remain stored and can appear in '
      'exports. Deleting a memory permanently from Recently deleted still '
      'works and also discards those copies.';

  const MemoryPrivacyBlocked(this.memoryId, this.historyId);

  @override
  String toString() => 'MemoryPrivacyBlocked: Cannot safely remove memory '
      '#$memoryId: supersede history #$historyId contains replacement text '
      'without per-event target provenance. No permanent erasure was performed. '
      'Memory and history are retained; privacy erasure has not completed.';
}

/// Expiry retirement commits before the atomic hard-purge batch. A blocked
/// batch erases nothing; newly retired rows remain available for restoration.
class MemoryCleanupResult {
  final int retired;
  final int purged;
  final MemoryPrivacyBlocked? blocked;
  const MemoryCleanupResult({
    required this.retired,
    required this.purged,
    this.blocked,
  });
}

class MemoryRepo {
  final DatabaseExecutor db;
  final DateTime Function() clock;
  MemoryRepo(this.db, {DateTime Function()? clock})
      : clock = clock ?? DateTime.now;

  /// Review-only read; never used by retrieval or prompt context.
  Future<List<Memory>> suggestions() async => (await db.query(
        'memories',
        where: "status = 'suggested'",
        orderBy: 'id',
      ))
          .map(Memory.new)
          .toList();

  /// Persist an already grounded/validated extraction, never ordinary add.
  /// Full JSON/grounding validation and lifecycle checks belong to the future
  /// pipeline; these storage checks do not establish model precision.
  /// Returns null for revoked/stale work or an already used source message.
  Future<int?> suggest(
    String content, {
    required String chatId,
    required int sourceMessageId,
    required int expectedLastMessageId,
    String category = 'fact',
  }) =>
      _storageTransaction(db, (tx) async {
        final source = await ExtractionRepo._nextSource(
          tx,
          chatId,
          sourceMessageId,
          expectedLastMessageId,
        );
        if (source == null ||
            await MemoryWriteSource.wasWritten(tx, chatId, sourceMessageId)) {
          return null;
        }
        final used = await tx.query(
          'extraction_sources',
          columns: ['message_id'],
          where: 'message_id = ?',
          whereArgs: [sourceMessageId],
        );
        if (used.isNotEmpty) return null;
        _validateSuggestion(content, category);
        final sourceText = source['content'] as String;
        _rejectInstruction(sourceText);
        if (RuleEngine.isTemporary(sourceText) ||
            RuleEngine.isObligation(sourceText)) {
          throw ArgumentError(
              'Temporary or obligation source is not a suggestion');
        }
        final t = _nowMs;
        final text = content.trim();
        final normalized = text
            .toLowerCase()
            .replaceAll(RegExp(r'[.!?]+$'), '')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        final slot = extractMemorySlot(text);
        final id = await tx.insert('memories', {
          'content': text,
          'category': category,
          'importance': 0.5,
          'created_at': t,
          'updated_at': t,
          'status': 'suggested',
          'source': 'model:extract',
          // Derived keys match backup reindexing; every consumer still filters
          // status, so these keys reserve neither a duplicate nor an active slot.
          'content_hash': sha256.convert(utf8.encode(normalized)).toString(),
          'subject_key': slot?.subject,
          'attribute_key': slot?.slot,
        });
        await tx.insert('extraction_sources', {
          'message_id': sourceMessageId,
          'suggestion_id': id,
          'memory_id': id,
        });
        await MemoryRepo(
          tx,
          clock: clock,
        )._log('add', id, now: content.trim(), actor: 'model');
        await tx.update(
          'extraction_state',
          {'last_message_id': sourceMessageId},
          where: 'chat_id = ?',
          whereArgs: [chatId],
        );
        return id;
      });

  static void _validateSuggestion(String content, String category) {
    if (content.trim().isEmpty ||
        content.length > 2000 ||
        !const {'preference', 'fact', 'person'}.contains(category)) {
      throw ArgumentError('Invalid suggestion text or category');
    }
    _rejectInstruction(content);
    if (RuleEngine.isTemporary(content) || RuleEngine.isObligation(content)) {
      throw ArgumentError(
        'Temporary or obligation content is not a suggestion',
      );
    }
  }

  /// Validation, ordinary add (including bump/slot supersede), user audit,
  /// provenance relink, and removal are one transaction. The suggested row
  /// itself is never activated or exposed to FTS. Any failure keeps it intact.
  /// Unattributed replacement copies throw [MemoryPrivacyBlocked], as accepting
  /// also erases the suggestion identity and its owned historical text.
  Future<SuggestionDecisionResult> acceptSuggestion(int id) =>
      _storageTransaction(db, (tx) async {
        final rows = await tx.query(
          'memories',
          where: "id = ? AND status = 'suggested'",
          whereArgs: [id],
        );
        if (rows.isEmpty) {
          return const SuggestionDecisionResult(SuggestionDecision.gone);
        }
        final row = rows.single;
        final content = row['content'] as String;
        final category = row['category'] as String;
        _validateSuggestion(content, category);
        final repo = MemoryRepo(tx, clock: clock);
        await repo._requireErasableHistory(id);
        final saved = await repo._add(
          content,
          category: category,
          importance: (row['importance'] as num).toDouble(),
          source: row['source'] as String?,
          actor: 'user',
          observedAt: _dt(row['observed_at_utc']),
          observationOffsetMin: row['observation_offset_min'] as int?,
        );
        // The saved row's ordinary history owns the text from now on. Do not
        // leave an orphan copy under the removed suggestion that a later
        // deletePermanently(saved) could never redact.
        await tx.update(
          'memory_history',
          {'old_content': null, 'new_content': null},
          where: 'memory_id = ?',
          whereArgs: [id],
        );
        await repo._log('accept', id, actor: 'user');
        await tx.update(
          'extraction_sources',
          {'memory_id': saved},
          where: 'memory_id = ?',
          whereArgs: [id],
        );
        // Imports can reference a suggestion even though normal writes do not.
        // Preserve that relationship under the accepted identity. Deduplication
        // can return a referring row itself; do not create a self-reference.
        await tx.update('memories', {'superseded_by': null},
            where: 'id = ? AND superseded_by = ?', whereArgs: [saved, id]);
        await tx.update('memories', {'superseded_by': saved},
            where: 'superseded_by = ?', whereArgs: [id]);
        await tx.delete(
          'memories',
          where: "id = ? AND status = 'suggested'",
          whereArgs: [id],
        );
        return SuggestionDecisionResult(SuggestionDecision.accepted, saved);
      });

  /// Reject replaces the generic purge event with a user reject event. Erase
  /// all history text and the row together; retain only content-free audit and
  /// source identity. Calling deletePermanently separately would break atomicity.
  /// Never blocked by legacy copies: they are redacted in the same transaction.
  Future<SuggestionDecisionResult> rejectSuggestion(int id) =>
      _storageTransaction(db, (tx) async {
        final rows = await tx.query('memories',
            columns: ['id'],
            where: "id = ? AND status = 'suggested'",
            whereArgs: [id]);
        if (rows.isEmpty) {
          return const SuggestionDecisionResult(SuggestionDecision.gone);
        }
        final repo = MemoryRepo(tx, clock: clock);
        // Rejecting is the user erasing the suggestion: never blocked.
        await repo._redactUnattributedCopies();
        final removed = await tx.delete(
          'memories',
          where: "id = ? AND status = 'suggested'",
          whereArgs: [id],
        );
        if (removed == 0) {
          return const SuggestionDecisionResult(SuggestionDecision.gone);
        }
        await tx.update('memories', {'superseded_by': null},
            where: 'superseded_by = ?', whereArgs: [id]);
        await tx.update(
          'memory_history',
          {'old_content': null, 'new_content': null},
          where: 'memory_id = ?',
          whereArgs: [id],
        );
        await repo._log('reject', id, actor: 'user');
        return const SuggestionDecisionResult(SuggestionDecision.rejected);
      });

  /// Plan 1.4: a memory reads as current while it is active and not past
  /// its `expires_at`, judged by [clock]. The instant is an integer inlined
  /// into the SQL (no injection risk), so bound arguments stay unchanged.
  /// [_liveM] is for joins on `memories m`; [_liveAt] for a captured
  /// instant (one clock read per call).
  static String _liveAt(int nowMs, [String table = '']) =>
      "${table}status = 'active' AND "
      '(${table}expires_at IS NULL OR ${table}expires_at > $nowMs)';
  String get _live => _liveAt(_nowMs);
  String get _liveM => _liveAt(_nowMs, 'm.');
  int get _nowMs => clock().millisecondsSinceEpoch;

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

  /// Resolves active memories for forgetting; loose retrieval never authorizes
  /// deletion, even when there is only one candidate.
  Future<ForgetMatch> matchForForget(String fact) async {
    String normalized(String value) => value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[.!?]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final norm = normalized(fact);
    final hash = sha256.convert(utf8.encode(norm)).toString();
    final exact = (await db.query('memories',
            where: "$_live AND content_hash = ?", whereArgs: [hash]))
        .map(Memory.new)
        .where((m) => normalized(m.content) == norm)
        .toList();
    if (exact.length == 1) {
      return ForgetMatch(ForgetEvidence.exact, exact);
    }

    const slotVocabulary = {
      'user',
      'i',
      'my',
      'like',
      'likes',
      'love',
      'loves',
      'prefer',
      'prefers',
      'hate',
      'hates',
      'dislike',
      'dislikes',
      'drink',
      'drinks',
      'live',
      'lives',
      'work',
      'works',
      'as',
      'in',
    };
    final values =
        terms(fact).where((term) => !slotVocabulary.contains(term)).toList();
    if (values.isEmpty) {
      return const ForgetMatch(ForgetEvidence.none, []);
    }
    final slot = extractMemorySlot(fact);
    if (slot != null) {
      final matches = (await db.query('memories',
              where: '$_live AND subject_key = ? AND attribute_key = ?',
              whereArgs: [slot.subject, slot.slot]))
          .map(Memory.new)
          .where((m) => values.any(terms(m.content).contains))
          .toList();
      if (matches.length == 1) {
        return ForgetMatch(ForgetEvidence.slot, matches);
      }
    }
    final candidates = (await search(fact, limit: 5))
        .where((m) => values.every(terms(m.content).contains))
        .toList();
    if (candidates.isNotEmpty && candidates.length <= 3) {
      return ForgetMatch(ForgetEvidence.candidates, candidates);
    }
    return ForgetMatch(ForgetEvidence.none, const [],
        severalMatch: candidates.length > 3);
  }

  /// Stores a memory; an explicit new preference supersedes its prior value;
  /// an exact same-terms duplicate bumps importance.
  ///
  /// [observedAt] is when the user said it (plan 1.3). A new row stores the
  /// instant (`observed_at_utc`), the UTC offset it was said at
  /// (`observation_offset_min`, default `observedAt.timeZoneOffset`) and the
  /// calendar date the fact refers to (`fact_date`, see [resolveFactDate]),
  /// resolved against that local day. A duplicate keeps its first
  /// observation, unless it is time-bound and is re-observed (see [_add]).
  ///
  /// Plan 1.4: an observed time-bound fact also stores `expires_at` (see
  /// [memoryExpiresAt]), from the same journaled observation, so a replay
  /// stores the same expiry. An expiring row takes no preference slot and
  /// supersedes nothing: a short-lived "I'm in Goa this week" must not retire
  /// a lasting fact that would then be lost when it expires. An expired row
  /// is not a duplicate; saying it again stores a fresh row.
  Future<int> add(String content,
      {String category = 'fact',
      double importance = 0.5,
      String? opId,
      String? source,
      String actor = 'rules',
      DateTime? observedAt,
      int? observationOffsetMin}) async {
    _rejectInstruction(content);
    return _storageTransaction(
        db,
        (tx) => MemoryRepo(tx, clock: clock)._add(content,
            category: category,
            importance: importance,
            opId: opId,
            source: source,
            actor: actor,
            observedAt: observedAt,
            observationOffsetMin: observationOffsetMin));
  }

  /// Returns false for a proven replay, including a memory since purged.
  /// The successful write (add/bump/correction) and content-free marker commit
  /// together. A failed marker rolls back all writes even in an outer tx.
  Future<bool> saveLinked(
    String content, {
    required MemoryWriteSource identity,
    String? replaces,
    String category = 'fact',
    String source = 'chat',
    String actor = 'rules',
    DateTime? observedAt,
    int? observationOffsetMin,
  }) async {
    _rejectInstruction(content);
    return _storageTransaction(db, (tx) async {
      final verified =
          await MemoryWriteSource.forOperation(tx, identity.operationId);
      if (verified == null ||
          verified.chatId != identity.chatId ||
          verified.messageId != identity.messageId) {
        throw MemorySourceUnverified();
      }
      if (await MemoryWriteSource.wasWritten(
          tx, identity.chatId, identity.messageId)) {
        return false;
      }
      final repo = MemoryRepo(tx, clock: clock);
      if (replaces == null) {
        await repo._add(content,
            category: category,
            opId: identity.operationId,
            source: source,
            actor: actor,
            observedAt: observedAt,
            observationOffsetMin: observationOffsetMin);
      } else {
        await repo._addCorrection(content,
            replaces: replaces,
            category: category,
            opId: identity.operationId,
            source: source,
            actor: actor,
            observedAt: observedAt,
            observationOffsetMin: observationOffsetMin);
      }
      await tx
          .insert('memory_write_sources', {'message_id': identity.messageId});
      return true;
    });
  }

  /// Plan 1.5: new text only. Rows that already exist (restore, undo,
  /// backup import, supersede, history) are never rescanned.
  static void _rejectInstruction(String content) {
    final issue = memoryInstructionIssue(content.trim());
    if (issue != null) throw MemoryInstructionRejected(issue);
  }

  /// [add] inside a transaction; [permanent] stores no expiry (corrections).
  Future<int> _add(String content,
      {String category = 'fact',
      double importance = 0.5,
      String? opId,
      String? source,
      String actor = 'rules',
      DateTime? observedAt,
      int? observationOffsetMin,
      bool permanent = false}) async {
    content = content.trim();
    String normalized(String value) => value
        .toLowerCase()
        .replaceAll(RegExp(r'[.!?]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final norm = normalized(content);
    final contentHash = sha256.convert(utf8.encode(norm)).toString();
    // The local day the user said it on: the instant shifted by its offset.
    final offsetMin =
        observationOffsetMin ?? observedAt?.timeZoneOffset.inMinutes;
    final observedUtc = observedAt?.toUtc();
    final observedLocal = observedUtc?.add(Duration(minutes: offsetMin!));
    final expiresAt = permanent || observedUtc == null
        ? null
        : memoryExpiresAt(content,
            observedAt: observedUtc, observationOffsetMin: offsetMin!);

    // Fast deduplication check using indexed content_hash
    for (final r in await db.query('memories',
        columns: ['id', 'content', 'importance', 'expires_at'],
        where: '$_live AND content_hash = ?',
        whereArgs: [contentHash])) {
      if (normalized(r['content'] as String) == norm) {
        final imp = ((r['importance'] as num) + 0.1).clamp(0.0, 1.0);
        // Plan 1.4 (D3): restating a time-bound row re-observes it, so its
        // expiry is the later of the old and the new one (a null new expiry
        // never ends) and its observation and fact day follow the new
        // statement. An earlier new expiry keeps the old observation, so the
        // stored day and expiry stay consistent. A lasting row stays lasting.
        final oldExpiry = r['expires_at'] as int?;
        final reobserve = !permanent &&
            oldExpiry != null &&
            observedUtc != null &&
            (expiresAt == null || expiresAt >= oldExpiry);
        await db.update(
            'memories',
            {
              'importance': imp,
              'updated_at': _now(),
              if (opId != null) 'op_id': opId,
              if (source != null) 'source': source,
              // A correction restating a time-bound row makes it lasting.
              if (permanent) 'expires_at': null,
              if (reobserve) ...{
                'expires_at': expiresAt,
                'observed_at_utc': observedUtc.millisecondsSinceEpoch,
                'observation_offset_min': offsetMin,
                'fact_date': resolveFactDate(content, observedLocal!)?.value,
              },
            },
            where: 'id = ?',
            whereArgs: [r['id']]);
        final id = r['id'] as int;
        await _log('bump', id,
            old: r['content'] as String,
            now: r['content'] as String,
            actor: actor,
            opId: opId);
        return id;
      }
    }

    final t = _now();

    // Fast slot superseding check using indexed subject_key & attribute_key
    final newSlot = expiresAt == null ? extractMemorySlot(content) : null;
    final toSupersede = <int>[];
    if (newSlot != null) {
      for (final r in await db.query('memories',
          columns: ['id', 'content'],
          where: "status = 'active' AND subject_key = ? AND attribute_key = ?",
          whereArgs: [newSlot.subject, newSlot.slot])) {
        toSupersede.add(r['id'] as int);
      }
    }

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
      if (observedUtc != null) ...{
        'observed_at_utc': observedUtc.millisecondsSinceEpoch,
        'observation_offset_min': offsetMin,
        'fact_date': resolveFactDate(content, observedLocal!)?.value,
        if (expiresAt != null) 'expires_at': expiresAt,
      },
    });
    await _log('add', newId, now: content, actor: actor, opId: opId);
    for (final oldId in toSupersede) {
      await _supersede(oldId, newId, actor: actor, opId: opId);
    }
    return newId;
  }

  /// Supersedes a prior memory with [newId]: marks it superseded and removes
  /// it from FTS so it leaves all retrieval and prompt contexts.
  Future<void> supersede(int oldId, int newId,
          {String actor = 'rules', String? opId}) =>
      _storageTransaction(
          db,
          (tx) => MemoryRepo(tx, clock: clock)
              ._supersede(oldId, newId, actor: actor, opId: opId));

  Future<void> _supersede(int oldId, int newId,
      {String actor = 'rules', String? opId}) async {
    if (oldId == newId) return;
    final old = await db.query('memories',
        columns: ['content'],
        where: "id = ? AND status = 'active'",
        whereArgs: [oldId]);
    if (old.isEmpty) return;
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
    await _log('supersede', oldId,
        old: old.single['content'] as String,
        // Replacement text belongs to the successor's own history. Copying it
        // here would lose its identity once the current link changes or clears.
        // Keep the existing nullable schema and the event/actor/op audit trail.
        actor: actor,
        opId: opId);
  }

  Future<void> _log(String event, int memoryId,
      {String? old, String? now, required String actor, String? opId}) async {
    await db.insert('memory_history', {
      'memory_id': memoryId,
      'event': event,
      'old_content': old,
      'new_content': now,
      'actor': actor,
      'op_id': opId,
      'created_at': _now(),
    });
  }

  /// Saves a correction and retires at most three matching active memories.
  Future<int> addCorrection(String content,
      {required String replaces,
      String category = 'fact',
      double importance = 0.5,
      String? opId,
      String? source,
      String actor = 'rules',
      DateTime? observedAt,
      int? observationOffsetMin}) async {
    // Checked before _add, so a rejected correction retires nothing.
    _rejectInstruction(content);
    return _storageTransaction(
        db,
        (tx) => MemoryRepo(tx, clock: clock)._addCorrection(content,
            replaces: replaces,
            category: category,
            importance: importance,
            opId: opId,
            source: source,
            actor: actor,
            observedAt: observedAt,
            observationOffsetMin: observationOffsetMin));
  }

  Future<int> _addCorrection(String content,
      {required String replaces,
      String category = 'fact',
      double importance = 0.5,
      String? opId,
      String? source,
      String actor = 'rules',
      DateTime? observedAt,
      int? observationOffsetMin}) async {
    // Plan 1.4: a correction is a lasting change of state ("I no longer
    // live in Pune"); it never expires, so what it retires stays retired.
    final saved = await _add(content,
        permanent: true,
        category: category,
        importance: importance,
        opId: opId,
        source: source,
        actor: actor,
        observedAt: observedAt,
        observationOffsetMin: observationOffsetMin);
    final words = terms(replaces);
    if (words.isEmpty) return saved;
    final candidates = (await db.rawQuery(
      'SELECT m.* FROM memories m JOIN memories_fts f ON f.docid = m.id '
      "WHERE memories_fts MATCH ? AND $_liveM AND m.id != ?",
      [words.map((word) => '"$word"').join(' '), saved],
    ))
        .map(Memory.new)
        .where((m) => words.every(terms(m.content).contains))
        .toList();
    if (candidates.length <= 3) {
      for (final memory in candidates) {
        await _supersede(memory.id, saved, actor: actor, opId: opId);
      }
    }
    return saved;
  }

  /// Content lookup only. This is never proof that a source wrote memory;
  /// replay and extraction skips must use the durable source marker.
  Future<int?> activeIdForContent(String content) async {
    final normalized = content
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[.!?]+$'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final hash = sha256.convert(utf8.encode(normalized)).toString();
    final rows = await db.query('memories',
        columns: ['id'],
        where: "status = 'active' AND content_hash = ?",
        whereArgs: [hash],
        limit: 1);
    return rows.isEmpty ? null : rows.single['id'] as int;
  }

  Future<List<Map<String, Object?>>> history(int memoryId) =>
      db.query('memory_history',
          where: 'memory_id = ?', whereArgs: [memoryId], orderBy: 'id');

  /// Decodes FTS4's p, c, n, a, l, x blocks without loading memory content.
  static double _normalizedBm25(Uint8List bytes, int termCount) {
    final data = ByteData.sublistView(bytes);
    int at(int i) => data.getUint32(i * 4, Endian.little);
    final phrases = at(0), columns = at(1), documents = at(2);
    var bm25 = 0.0;
    for (var phrase = 0; phrase < phrases; phrase++) {
      for (var column = 0; column < columns; column++) {
        final offset = 3 + 2 * columns + 3 * (phrase * columns + column);
        final frequency = at(offset);
        if (frequency == 0) continue;
        final documentFrequency = at(offset + 2);
        final averageLength = math.max(1, at(3 + column));
        final length = at(3 + columns + column);
        // Positive, smoothed IDF keeps even ubiquitous terms useful.
        final idf = math.log(1 +
            (documents - documentFrequency + 0.5) / (documentFrequency + 0.5));
        const k1 = 1.2, b = 0.75;
        bm25 += idf *
            frequency *
            (k1 + 1) /
            (frequency + k1 * (1 - b + b * length / averageLength));
      }
    }
    // mem0/utils/scoring.py:get_bm25_params, using deduplicated query terms.
    final (midpoint, steepness) = switch (termCount) {
      <= 3 => (5.0, 0.7),
      <= 6 => (7.0, 0.6),
      <= 9 => (9.0, 0.5),
      <= 15 => (10.0, 0.5),
      _ => (12.0, 0.5),
    };
    return 1 / (1 + math.exp(-steepness * (bm25 - midpoint)));
  }

  /// Rank active FTS metadata first; load only a bounded content shortlist.
  /// Database calls already wait behind open transactions; a caller-owned tx
  /// also needs the storage queue so its access stamp survives sibling failure.
  Future<List<Memory>> search(String query, {int limit = 3}) => db
          is Transaction
      ? _storageTransaction(
          db, (tx) => MemoryRepo(tx, clock: clock)._search(query, limit: limit))
      : _search(query, limit: limit);

  Future<List<Memory>> _search(String query, {int limit = 3}) async {
    final ts = terms(query);
    if (ts.isEmpty || limit <= 0) return [];
    final now = clock().millisecondsSinceEpoch;
    final candidates = await db.rawQuery(
        'SELECT m.id, m.importance, m.updated_at, '
        "matchinfo(memories_fts, 'pcnalx') AS mi "
        'FROM memories_fts JOIN memories m ON m.id = memories_fts.docid '
        'WHERE memories_fts MATCH ? AND ${_liveAt(now, 'm.')}',
        // Prefix matching already includes exact tokens. Do not count both
        // as separate BM25 phrases for the same query term.
        [ts.map((t) => '$t*').join(' OR ')]);
    if (candidates.isEmpty) return [];
    double metadataScore(Map<String, Object?> r) {
      final ageDays = (now - (r['updated_at'] as int)) / 86400000;
      return (r['importance'] as num) + 1 / (1 + ageDays / 30);
    }

    final ranked = candidates
        .map((r) => (
              id: r['id'] as int,
              score: _normalizedBm25(r['mi'] as Uint8List, ts.length) * 2 +
                  metadataScore(r),
            ))
        .toList()
      ..sort((a, b) {
        final comparison = b.score.compareTo(a.score);
        return comparison != 0 ? comparison : a.id.compareTo(b.id);
      });
    final scores = {
      for (final candidate in ranked.take(math.max(limit * 4, 60)))
        candidate.id: candidate.score,
    };
    final placeholders = List.filled(scores.length, '?').join(',');
    final rows = (await db.rawQuery(
            'SELECT * FROM memories WHERE ${_liveAt(now)} '
            'AND id IN ($placeholders)',
            scores.keys.toList()))
        .toList();
    double exactScore(Map<String, Object?> r) {
      final text = (r['content'] as String).toLowerCase();
      return ts.where(text.contains).length / ts.length * 2 + metadataScore(r);
    }

    final exactScores = {
      for (final r in rows) r['id'] as int: exactScore(r),
    };
    rows.sort((a, b) {
      final aId = a['id'] as int, bId = b['id'] as int;
      final comparison = scores[bId]!.compareTo(scores[aId]!);
      if (comparison != 0) return comparison;
      final exactComparison = exactScores[bId]!.compareTo(exactScores[aId]!);
      return exactComparison != 0 ? exactComparison : aId.compareTo(bId);
    });
    final top = rows.take(limit).toList();
    if (top.isNotEmpty) {
      final accessedIds = top.map((r) => r['id']).toList();
      final accessedPlaceholders = List.filled(top.length, '?').join(',');
      await db.update('memories', {'last_accessed_at': now},
          where: "status = 'active' AND id IN ($accessedPlaceholders)",
          whereArgs: accessedIds);
    }
    return top.map(Memory.new).toList();
  }

  Future<bool> delete(int id, {String actor = 'user', String? opId}) =>
      _storageTransaction(
          db,
          (tx) => MemoryRepo(tx, clock: clock)
              ._delete(id, actor: actor, opId: opId));

  Future<bool> _delete(int id, {String actor = 'user', String? opId}) async {
    final rows = await db.query('memories',
        columns: ['content'],
        where: "id = ? AND status = 'active'",
        whereArgs: [id]);
    if (rows.isEmpty) return false;
    final changed = await db.update(
        'memories',
        {
          'status': 'deleted',
          'deleted_at': clock().millisecondsSinceEpoch,
        },
        where: "id = ? AND status = 'active'",
        whereArgs: [id]);
    if (changed == 0) return false;
    await db.delete('memories_fts', where: 'docid = ?', whereArgs: [id]);
    await _log('delete', id,
        old: rows.single['content'] as String, actor: actor, opId: opId);
    return true;
  }

  Future<List<Memory>> deleted() async => (await db.query('memories',
          where: "status = 'deleted'", orderBy: 'deleted_at DESC, id DESC'))
      .map(Memory.new)
      .toList();

  /// The deletion remains recoverable through the inclusive 30-day boundary.
  Future<RestoreResult> restore(int id) => _storageTransaction(
      db, (tx) => MemoryRepo(tx, clock: clock)._restore(id));

  Future<RestoreResult> _restore(int id) async {
    final rows = await db.query('memories',
        where: "id = ? AND status = 'deleted' AND deleted_at >= ?",
        whereArgs: [
          id,
          clock().subtract(const Duration(days: 30)).millisecondsSinceEpoch
        ]);
    if (rows.isEmpty) return const RestoreResult(RestoreStatus.gone);
    final row = rows.single;
    final duplicates = await db.query('memories',
        columns: ['id'],
        where: '$_live AND content_hash = ?',
        whereArgs: [row['content_hash']],
        limit: 1);
    if (duplicates.isNotEmpty) {
      return RestoreResult(
          RestoreStatus.duplicate, duplicates.single['id'] as int);
    }
    if (row['subject_key'] != null && row['attribute_key'] != null) {
      final occupied = await db.query('memories',
          columns: ['id'],
          where: '$_live AND subject_key = ? AND attribute_key = ?',
          whereArgs: [row['subject_key'], row['attribute_key']],
          limit: 1);
      if (occupied.isNotEmpty)
        return const RestoreResult(RestoreStatus.slotTaken);
    }
    // Plan 1.4: restoring a fact that expired (and was retired by
    // [purgeDeleted]) is the user keeping it, so it no longer expires; one
    // deleted before its expiry keeps that expiry.
    final expiresAt = row['expires_at'] as int?;
    await db.update(
        'memories',
        {
          'status': 'active',
          'deleted_at': null,
          if (expiresAt != null && expiresAt <= _nowMs) 'expires_at': null,
        },
        where: 'id = ?',
        whereArgs: [id]);
    await db.insert('memories_fts', {'docid': id, 'content': row['content']},
        conflictAlgorithm: ConflictAlgorithm.replace);
    await _log('restore', id, now: row['content'] as String, actor: 'user');
    return RestoreResult(RestoreStatus.restored, id);
  }

  /// Explicit privacy path; always succeeds for an existing row. Legacy
  /// replacement copies that cannot be attributed are redacted in the same
  /// transaction (see [_redactUnattributedCopies]); only automatic purge and
  /// suggestion acceptance still fail closed on them.
  Future<bool> deletePermanently(int id) => _storageTransaction(
      db, (tx) => MemoryRepo(tx, clock: clock)._deletePermanently(id));

  Future<bool> _deletePermanently(int id) async {
    final rows = await db.query('memories',
        columns: ['id'], where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return false;
    // The user's explicit erase never fails on legacy history: copies that
    // cannot be attributed are discarded with it, in this same transaction.
    await _redactUnattributedCopies();
    await _eraseMemory(id);
    return true;
  }

  /// Nulls the replacement text of every legacy supersede event. Those events
  /// have no target identity, so any of them may hold text of the memory being
  /// erased; the successor keeps its own text in its own add/edit history, so
  /// only the redundant audit copy is lost. Event, actor, op and time stay.
  Future<void> _redactUnattributedCopies() => db.update(
      'memory_history', {'new_content': null},
      where: "event = 'supersede' AND new_content IS NOT NULL "
          "AND new_content != ''");

  /// Only after the global guard, on the same transaction and snapshot.
  Future<void> _eraseMemory(int id) async {
    await db.delete('memories', where: 'id = ?', whereArgs: [id]);
    await db.update('memories', {'superseded_by': null},
        where: 'superseded_by = ?', whereArgs: [id]);
    await db.update(
        'memory_history', {'old_content': null, 'new_content': null},
        where: 'memory_id = ?', whereArgs: [id]);
    await _log('purge', id, actor: 'system');
  }

  Future<void> _requireErasableHistory(int id) async {
    // The current link, text equality, timestamps and event ordering are not
    // per-event provenance. Even an apparently unrelated copy may be an older
    // version of this memory. Include orphan history and the target's own
    // supersede events (whose replacement text may belong to a survivor).
    // Deliberately global: narrower matching would claim erasure we cannot
    // establish. Old backups remain readable/exportable, but destructive
    // decisions require resolution outside this schema when copies exist.
    final historyId = await _unattributedHistoryId();
    if (historyId != null) throw MemoryPrivacyBlocked(id, historyId);
  }

  /// Recomputed from retained history, including after restart/import. This
  /// reports the blocker, not a past erasure attempt or user consent.
  Future<bool> legacyErasureBlocked() async =>
      await _unattributedHistoryId() != null;

  Future<int?> _unattributedHistoryId() async {
    final rows = await db.query('memory_history',
        columns: ['id'],
        where: "event = 'supersede' AND new_content IS NOT NULL "
            "AND new_content != ''",
        orderBy: 'id',
        limit: 1);
    return rows.isEmpty ? null : rows.single['id'] as int;
  }

  /// Retire expiry independently of hard erasure. Each stage has its own
  /// transaction/savepoint; a caller's outer transaction can still roll back
  /// both stages. No legacy text is automatically discarded to unblock purge.
  Future<MemoryCleanupResult> cleanupDeleted({
    Duration olderThan = const Duration(days: 30),
  }) async {
    final retired = await _storageTransaction(
        db, (tx) => MemoryRepo(tx, clock: clock)._retireExpired());
    try {
      final purged = await _storageTransaction(
          db,
          (tx) =>
              MemoryRepo(tx, clock: clock)._purgeDeleted(olderThan: olderThan));
      return MemoryCleanupResult(retired: retired, purged: purged);
    } on MemoryPrivacyBlocked catch (blocked) {
      return MemoryCleanupResult(retired: retired, purged: 0, blocked: blocked);
    }
  }

  /// Compatibility count API. A blocked purge still throws, but expiry
  /// retirement has already committed. Use [cleanupDeleted] for partial status.
  Future<int> purgeDeleted(
      {Duration olderThan = const Duration(days: 30)}) async {
    final result = await cleanupDeleted(olderThan: olderThan);
    if (result.blocked != null) throw result.blocked!;
    return result.purged;
  }

  Future<int> _retireExpired() async {
    var retired = 0;
    for (final row in await db.query('memories',
        columns: ['id'],
        where:
            "status = 'active' AND expires_at IS NOT NULL AND expires_at <= ?",
        whereArgs: [_nowMs])) {
      if (await _delete(row['id'] as int, actor: 'system')) retired++;
    }
    return retired;
  }

  Future<int> _purgeDeleted({required Duration olderThan}) async {
    final rows = await db.query('memories',
        columns: ['id'],
        where: "status = 'deleted' AND deleted_at < ?",
        whereArgs: [clock().subtract(olderThan).millisecondsSinceEpoch]);
    if (rows.isEmpty) return 0;
    // Once per batch, within the same transaction as every erasure. No other
    // writer can add a legacy copy between this check and the hard deletes.
    await _requireErasableHistory(rows.first['id'] as int);
    for (final row in rows) {
      await _eraseMemory(row['id'] as int);
    }
    return rows.length;
  }

  Future<List<Memory>> all() async =>
      (await db.query('memories', where: _live, orderBy: 'id DESC'))
          .map(Memory.new)
          .toList();

  Future<List<Memory>> important({int limit = 3}) async {
    if (limit <= 0) return [];
    const pageSize = 50, maxPages = 5;
    final live = _live;
    final results = <Memory>[];
    for (var page = 0; page < maxPages; page++) {
      final rows = await db.query('memories',
          where: "$live AND category IN ('preference','fact','person')",
          orderBy: 'importance DESC, updated_at DESC, id',
          limit: pageSize,
          offset: page * pageSize);
      for (final row in rows) {
        final memory = Memory(row);
        if (isUsefulPersonalMemory(memory.content)) {
          results.add(memory);
          if (results.length == limit) return results;
        }
      }
      if (rows.length < pageSize) break;
    }
    return results;
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
                  "$_live AND (category = 'preference' OR content LIKE '%prefer%')",
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

/// The `expires_at` [MemoryRepo.add] stores for [content] said at
/// [observedAt] with UTC offset [observationOffsetMin] (plan 1.4); null when
/// it never expires. Habits and preferences ("usually", "every", "prefer")
/// and lasting slot facts (residence, job, preferences) never expire; a
/// short-lived fact ([RuleEngine.isTemporary]) ends with its window, and
/// another one-off dated fact 30 days after its day (see [factExpiresAt]).
/// Deterministic for the same integers, so journal replay agrees.
int? memoryExpiresAt(String content,
    {required DateTime observedAt, required int observationOffsetMin}) {
  final text = content.toLowerCase();
  if (RuleEngine.isDurable(text)) return null;
  final temporary = RuleEngine.isTemporary(text);
  if (!temporary && extractMemorySlot(content) != null) return null;
  final utc = observedAt.toUtc();
  final local = utc.add(Duration(minutes: observationOffsetMin));
  return factExpiresAt(content,
      observedUtcMs: utc.millisecondsSinceEpoch,
      offsetMin: observationOffsetMin,
      factDate: resolveFactDate(content, local)?.value,
      temporary: temporary);
}

/// [content] with the absolute date of its `fact_date` (plan 1.3), so a
/// relative day said earlier ("my exam is on Monday") cannot be re-read
/// against today: "User's exam is on Monday (2 Nov 2026)", or for a yearly
/// date "(every year on 4 June)". Unchanged when [factDate] is null or not a
/// stored date shape.
String withFactDate(String content, String? factDate) {
  if (factDate == null) return content;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];
  const longMonths = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December'
  ];
  final String label;
  final full = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(factDate);
  final yearly = RegExp(r'^--(\d{2})-(\d{2})$').firstMatch(factDate);
  if (full != null) {
    final month = int.parse(full.group(2)!);
    if (month < 1 || month > 12) return content;
    label = '${int.parse(full.group(3)!)} ${months[month - 1]} '
        '${full.group(1)}';
  } else if (yearly != null) {
    final month = int.parse(yearly.group(1)!);
    if (month < 1 || month > 12) return content;
    label = 'every year on ${int.parse(yearly.group(2)!)} '
        '${longMonths[month - 1]}';
  } else {
    return content;
  }
  final end = RegExp(r'[.!?]+$').firstMatch(content.trimRight());
  final body = end == null
      ? content.trimRight()
      : content.trimRight().substring(0, end.start);
  return '$body ($label)${end?.group(0) ?? ''}';
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
  final int? sourceMessageId;
  final DateTime createdAt, updatedAt;
  Operation(Map<String, Object?> r)
      : id = r['op_id'] as String,
        chatId = r['chat_id'] as String,
        textHash = r['text_hash'] as String,
        status = r['status'] as String,
        sourceMessageId = r['source_message_id'] as int?,
        action = r['action'] as String?,
        receipt = r['receipt'] as String?,
        createdAt = _dt(r['created_at'])!,
        updatedAt = _dt(r['updated_at'])!;
}

class OperationJournal {
  final DatabaseExecutor db;
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
      abandoned = 'abandoned',
      recoveryUnresolved = 'recovery_unresolved';

  Future<Operation?> get(String id) async {
    final r = await db.query('operations', where: 'op_id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Operation(r.first);
  }

  /// New turns only: the source and journal have no observable half-state.
  /// A racing/retried id must refer to the exact same chat and message hash.
  Future<int> beginTurn(
          String id, String chatId, String textHash, String text) =>
      _storageTransaction(db, (tx) async {
        final prior =
            await tx.query('operations', where: 'op_id = ?', whereArgs: [id]);
        if (prior.isNotEmpty) {
          final op = Operation(prior.single);
          final source = await MemoryWriteSource.forOperation(tx, id);
          if (op.chatId != chatId ||
              op.textHash != textHash ||
              source == null) {
            throw ArgumentError('Operation identity mismatch');
          }
          return source.messageId;
        }
        final messageId =
            await ConversationRepo._insert(tx, chatId, 'user', text);
        await tx.insert('operations', {
          'op_id': id,
          'chat_id': chatId,
          'text_hash': textHash,
          'source_message_id': messageId,
          'status': started,
          'created_at': _now(),
          'updated_at': _now(),
        });
        return messageId;
      });

  /// Legacy/imported journal only. No historical message link is inferred.
  /// New foreground turns must use beginTurn.
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

  /// Publish a final receipt and its transcript row together. Unresolved
  /// recovery keeps its status, so the receipt records publication explicitly.
  Future<void> publishReply(String id, String reply, String status,
          Map<String, Object?> receipt, {bool replay = false}) =>
      _storageTransaction(db, (tx) async {
        final rows = await tx.query('operations',
            where: 'op_id = ?', whereArgs: [id]);
        final op = Operation(rows.single);
        final prior = op.receipt == null ? null : jsonDecode(op.receipt!) as Map;
        var messageId =
            replay ? (prior?['assistant_message_id'] as int?) : null;
        // Older unresolved final receipts have no publication marker. Reuse
        // their already-persisted reply, bounded to that operation's lifetime.
        if (replay && messageId == null && op.status == recoveryUnresolved) {
          final published = await tx.query('conversations',
              columns: ['id'],
              where: "session_id = ? AND role = 'assistant' AND content = ? "
                  'AND created_at >= ? AND created_at <= ?',
              whereArgs: [
                op.chatId,
                reply,
                op.createdAt.millisecondsSinceEpoch,
                op.updatedAt.millisecondsSinceEpoch
              ],
              orderBy: 'id DESC',
              limit: 1);
          messageId = published.firstOrNull?['id'] as int?;
        }
        messageId ??=
            await ConversationRepo._insert(tx, op.chatId, 'assistant', reply);
        await tx.update('operations', {
          'status': status,
          'receipt': jsonEncode({...receipt, 'assistant_message_id': messageId}),
          'updated_at': _now(),
        }, where: 'op_id = ?', whereArgs: [id]);
      });

  static bool _hasMemoryAction(String? action) {
    if (action == null) return false;
    try {
      bool containsMemory(Object? value) => switch (value) {
            Map m => m['tool'] == 'save_memory' || m.values.any(containsMemory),
            List l => l.any(containsMemory),
            _ => false,
          };
      return containsMemory(jsonDecode(action));
    } catch (_) {
      return true; // malformed legacy intent cannot establish provenance
    }
  }

  /// Startup: turns left `started`/`executing` by a crash are settled without
  /// running anything. Task/reminder op ids and verified memory markers prove
  /// commits, even after memory purge or duplicate bumps. Ambiguous unlinked
  /// memory intent becomes recovery_unresolved; replay withholds only memory.
  /// Otherwise abandon only if the operation is not currently active
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
      final source = await MemoryWriteSource.forOperation(db, id);
      final memoryWritten = source != null &&
          await MemoryWriteSource.wasWritten(
              db, source.chatId, source.messageId);
      final prefix = '$id#';
      final stamped = await db.rawQuery(
          'SELECT t.op_id FROM tasks t WHERE t.op_id = ? OR '
          '(substr(t.op_id, 1, ?) = ? AND NOT EXISTS '
          '(SELECT 1 FROM operations o WHERE o.op_id = t.op_id)) '
          'UNION ALL '
          'SELECT r.op_id FROM reminders r WHERE r.op_id = ? OR '
          '(substr(r.op_id, 1, ?) = ? AND NOT EXISTS '
          '(SELECT 1 FROM operations o WHERE o.op_id = r.op_id))',
          [id, prefix.length, prefix, id, prefix.length, prefix]);
      final rows = stamped.where((row) {
            final stamp = row['op_id'] as String;
            return stamp == id || indexedOperationParent(stamp) == id;
          }).length +
          (memoryWritten ? 1 : 0);
      // Unlinked memory intent is unknowable, even if an unrelated matching
      // row exists. Withhold it on replay; task/reminder recovery stays usable.
      final unknownMemory =
          source == null && _hasMemoryAction(r['action'] as String?);
      await mark(
          id,
          unknownMemory
              ? recoveryUnresolved
              : rows > 0
                  ? committed
                  : abandoned);
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
