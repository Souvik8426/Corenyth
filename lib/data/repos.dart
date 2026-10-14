import 'dart:convert';

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
  Task(Map<String, Object?> r)
      : id = r['id'] as int,
        title = r['title'] as String,
        notes = r['notes'] as String?,
        done = r['status'] == 'done',
        dueAt = _dt(r['due_at']),
        priority = r['priority'] as int;
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

  Future<Task> create(String title,
      {String? notes, DateTime? due, int priority = 1}) async {
    final id = await db.insert('tasks', {
      'title': title,
      'notes': notes,
      'created_at': _now(),
      'due_at': due?.millisecondsSinceEpoch,
      'priority': priority,
    });
    return (await get(id))!;
  }

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
        // Plan over: restoring the task never re-arms it.
        await tx.update('tasks', {'alert_plan': null}, where: 'id = ?', whereArgs: [id]);
        return true;
      }
      final previous = old.first['due_at'] as int?;
      final next = values['due_at'] as int?;
      final intent = AlertIntentJson.decode(old.first['alert_plan']);
      if (previous != null && next != null && next != previous && intent != null) {
        await _replan(tx, id, previous, next,
            (values['title'] ?? old.first['title']) as String, intent);
      } else if (previous != null && next != null && next != previous) {
        // No stored plan (older rows): same offsets from the new time; early
        // alerts/follow-ups now past or in quiet hours are dropped.
        final prefs = await _readPrefs(tx), now = DateTime.now();
        final delta = Duration(milliseconds: next - previous);
        for (final r in (await tx.query('reminders', where: linked, whereArgs: [id]))
            .map(Reminder.new)) {
          final at = r.triggerAt.add(delta);
          final drop = r.kind != 'reminder' && (!at.isAfter(now) || prefs.isQuiet(at));
          await tx.update('reminders', drop
              ? {'enabled': 0, 'sync': 'cancel'}
              : {'trigger_at': at.millisecondsSinceEpoch, 'sync': 'schedule'},
              where: 'id = ?', whereArgs: [r.id]);
        }
      }
      final title = values['title'];
      if (title is String && title != old.first['title']) {
        await tx.rawUpdate("UPDATE reminders SET title = CASE WHEN kind = 'follow_up' "
            "THEN ? ELSE ? END, sync = 'schedule' WHERE $linked",
            [followUpText(title), title, id]);
      }
      return true;
    });
    if (changed) await _synced();
    return changed;
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
}

/// Case/punctuation/whitespace-insensitive title key for exact title matching.
String normTitle(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

class ReminderRepo {
  final Database db;
  ReminderRepo(this.db);

  /// Saves the whole [plan] (see [reminderPlan]) and, without [taskId], its
  /// task due at [at], in one transaction with pending 'schedule' intents, so
  /// a crash never leaves half a plan or an alarm without a row.
  /// [intent] is stored on the task so a later due change regenerates the
  /// requested alerts, including ones skipped now (see [TaskRepo.update]).
  /// With [taskId] this replaces the task's plan: its enabled alerts get a
  /// cancel intent and its due time becomes [at], in the same transaction.
  /// Undo with [restorePlan].
  Future<List<Reminder>> createPlan(
          String title, DateTime at, List<PlannedAlert> plan,
          {int? taskId, AlertIntent intent = (lead: const [], follow: null)}) =>
      db.transaction((tx) async {
        final id = taskId ??
            await tx.insert('tasks', {
              'title': title, 'created_at': _now(),
              'due_at': at.millisecondsSinceEpoch,
            });
        if (taskId != null) {
          await tx.update('reminders', {'enabled': 0, 'sync': 'cancel'},
              where: 'task_id = ? AND enabled = 1', whereArgs: [id]);
        }
        await tx.update('tasks', {
          'alert_plan': intent.encode(),
          'due_at': at.millisecondsSinceEpoch,
        }, where: 'id = ?', whereArgs: [id]);
        return [
          for (final p in plan)
            await () async {
              final values = <String, Object?>{
                'task_id': id, 'kind': p.kind,
                'title': p.kind == 'follow_up' ? followUpText(title) : title,
                'trigger_at': p.at.millisecondsSinceEpoch, 'enabled': 1,
                'sync': 'schedule',
              };
              return Reminder({...values, 'id': await tx.insert('reminders', values)});
            }(),
        ];
      });

  /// Enabled alerts of one task, earliest first.
  Future<List<Reminder>> forTask(int taskId) async =>
      (await db.query('reminders', where: 'task_id = ? AND enabled = 1',
          whereArgs: [taskId], orderBy: 'trigger_at')).map(Reminder.new).toList();

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
        await tx.update('tasks', {
          'alert_plan': plan,
          'due_at': due?.millisecondsSinceEpoch,
        }, where: 'id = ?', whereArgs: [taskId]);
      });

  /// Tasks with an enabled follow-up (fired or not): only these get the
  /// "How did it go?" check-in in Tasks.
  Future<Set<int>> followUpTasks() async => {
        for (final r in await db.query('reminders',
            columns: ['task_id'],
            where: "kind = 'follow_up' AND enabled = 1 AND task_id IS NOT NULL"))
          r['task_id'] as int
      };

  /// The row is saved with a pending 'schedule' intent; clear it with [synced].
  Future<Reminder> create(String title, DateTime at, {int? taskId}) async {
    final id = await db.insert('reminders', {
      'title': title,
      'trigger_at': at.millisecondsSinceEpoch,
      'task_id': taskId,
      'sync': 'schedule',
    });
    return (await get(id))!;
  }

  Future<Reminder?> get(int id) async {
    final r = await db.query('reminders', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Reminder(r.first);
  }

  Future<List<Reminder>> upcoming() async => (await db.query('reminders',
          where: 'enabled = 1 AND trigger_at > ?',
          whereArgs: [_now()],
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
  String encode() => jsonEncode({'lead': lead, if (follow != null) 'follow': follow});

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
  String key(String kind, int offsetMin) => kind == 'pre' ? 'pre:$offsetMin' : kind;
  final spare = <String, Reminder>{};
  for (final r in (await tx.query('reminders',
          where: 'task_id = ? AND enabled = 1', whereArgs: [id]))
      .map(Reminder.new)) {
    final k = key(r.kind, (previous - r.triggerAt.millisecondsSinceEpoch) ~/ 60000);
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
        ...v, 'task_id': id, 'kind': p.kind, 'enabled': 1,
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
  Message(this.role, this.content);
}

class ChatSummary {
  final String id, title;
  final DateTime updatedAt;
  ChatSummary(this.id, this.title, this.updatedAt);
}

class ConversationRepo {
  final Database db;
  ConversationRepo(this.db);

  static String newChatId() => DateTime.now().microsecondsSinceEpoch.toString();

  /// Persists an empty chat row so it shows up in [listChats] before any message.
  Future<String> createChat() async {
    final id = newChatId(), t = _now();
    await db.insert('chats', {'id': id, 'title': '', 'created_at': t, 'updated_at': t},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    return id;
  }

  /// Adds a message and creates/touches its chat row (title = first user message).
  Future<void> add(String session, String role, String content) =>
      db.transaction((tx) async {
        final t = _now();
        await tx.insert('conversations', {
          'session_id': session,
          'role': role,
          'content': content,
          'created_at': t,
        });
        await tx.insert('chats', {'id': session, 'title': '', 'created_at': t, 'updated_at': t},
            conflictAlgorithm: ConflictAlgorithm.ignore);
        await tx.rawUpdate(
            "UPDATE chats SET updated_at = ?, title = CASE WHEN title = '' AND ? = 'user' "
            'THEN substr(?, 1, 60) ELSE title END WHERE id = ?',
            [t, role, content, session]);
      });

  /// Newest first.
  Future<List<ChatSummary>> listChats() async =>
      (await db.query('chats', orderBy: 'updated_at DESC, id DESC'))
          .map((r) => ChatSummary(r['id'] as String, r['title'] as String,
              _dt(r['updated_at'])!))
          .toList();

  /// Every message of the chat, oldest first.
  Future<List<Message>> messages(String session) async =>
      (await db.query('conversations',
              where: 'session_id = ?', whereArgs: [session], orderBy: 'id'))
          .map((m) => Message(m['role'] as String, m['content'] as String))
          .toList();

  Future<void> deleteChat(String id) => db.transaction((tx) async {
        await tx.delete('pending_clarifications', where: 'chat_id = ?', whereArgs: [id]);
        await tx.delete('conversations', where: 'session_id = ?', whereArgs: [id]);
        await tx.delete('chats', where: 'id = ?', whereArgs: [id]);
      });

  /// Last [n] messages of the session, oldest first.
  Future<List<Message>> recent(String session, {int n = 8}) async {
    final r = await db.query('conversations',
        where: 'session_id = ?',
        whereArgs: [session],
        orderBy: 'id DESC',
        limit: n);
    return r.reversed
        .map((m) => Message(m['role'] as String, m['content'] as String))
        .toList();
  }
}

class Memory {
  final int id;
  final String content, category;
  final double importance;
  Memory(Map<String, Object?> r)
      : id = r['id'] as int,
        content = r['content'] as String,
        category = r['category'] as String,
        importance = (r['importance'] as num).toDouble();
  @override
  String toString() => content;
}

class MemoryRepo {
  final Database db;
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

  /// Stores a memory; a same-terms duplicate just bumps importance.
  Future<int> add(String content,
      {String category = 'fact', double importance = 0.5}) async {
    content = content.trim();
    final norm = (terms(content)..sort()).join(' ');
    for (final r in await db
        .query('memories', columns: ['id', 'content', 'importance'])) {
      if ((terms(r['content'] as String)..sort()).join(' ') == norm) {
        final imp = ((r['importance'] as num) + 0.1).clamp(0.0, 1.0);
        await db.update('memories', {'importance': imp, 'updated_at': _now()},
            where: 'id = ?', whereArgs: [r['id']]);
        return r['id'] as int;
      }
    } // ponytail: O(n) dedupe scan, fine for thousands; use an FTS/embedding probe beyond that.
    final t = _now();
    return db.insert('memories', {
      'content': content,
      'category': category,
      'importance': importance,
      'created_at': t,
      'updated_at': t,
    });
  }

  /// FTS match, re-ranked by term hits + importance + recency (30-day decay).
  Future<List<Memory>> search(String query, {int limit = 3}) async {
    final ts = terms(query);
    if (ts.isEmpty) return [];
    final rows = (await db.rawQuery(
            'SELECT m.* FROM memories m JOIN memories_fts f ON f.docid = m.id '
            'WHERE memories_fts MATCH ?',
            [ts.map((t) => '"$t"').join(' OR ')]))
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

  Future<bool> delete(int id) async =>
      await db.delete('memories', where: 'id = ?', whereArgs: [id]) > 0;

  Future<List<Memory>> all() async =>
      (await db.query('memories', orderBy: 'id DESC')).map(Memory.new).toList();

  Future<List<Memory>> important({int limit = 3}) async {
    final rows =
        await db.query('memories', orderBy: 'importance DESC, updated_at DESC');
    return rows
        .map(Memory.new)
        .where((memory) => isUsefulPersonalMemory(memory.content))
        .take(limit)
        .toList();
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
  if (value.contains('language model') ||
      value.contains('assistant that helps') ||
      value.contains('various tasks') ||
      value.contains('...')) {
    return false;
  }
  return RegExp(
    r'^(?:user\s+(?:is|works|lives|prefers|likes|loves|hates|dislikes|studies|uses|has|usually|normally|always|never)\b|'
    r"i\s+(?:(?:usually|normally|always|never)\s+)?(?:am|'m|work|live|prefer|like|love|hate|dislike|study|use)\b|"
    r'i\s+have\s+(?:a|an|one|two|three|four|five)\b|my\s+(?:name|job|role|goal|preference)\s+is\b)',
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

  bool isQuiet(DateTime t) {
    if (!hasQuietHours) return false;
    final m = t.hour * 60 + t.minute, s = quietStart!, e = quietEnd!;
    return s < e ? m >= s && m < e : m >= s || m < e;
  }

  /// Throws [ArgumentError] on out-of-range values instead of saving them.
  ReminderPreferences validated() {
    final leads = leadMinutes.toSet().toList()..sort((a, b) => b - a);
    if (leads.isEmpty || leads.length > 3 || leads.any((m) => m < 1 || m > 1440)) {
      throw ArgumentError('Early alerts must be 1-3 values between 1 and 1440 minutes.');
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

  /// Called after a save that cancelled alerts, to sync platform alarms.
  Future<void> Function()? onRemindersChanged;
  ReminderPreferencesRepo(this.db);

  Future<ReminderPreferences> get() => _readPrefs(db);

  /// Turning follow-ups off also cancels every pending follow-up, atomically.
  Future<void> save(ReminderPreferences value) async {
    value = value.validated();
    final cancelled = await db.transaction((tx) async {
      await tx.insert('assistant_preferences', {
        'id': 1,
        'multiple': value.multiple ? 1 : 0,
        'follow_up': value.followUp ? 1 : 0,
        'lead_minutes': value.leadMinutes.join(','),
        'follow_up_minutes': value.followUpMinutes,
        'quiet_start': value.quietStart,
        'quiet_end': value.quietEnd,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (value.followUp) return 0;
      // Stored plans drop their follow-up too, so a later move can't bring it back.
      for (final t in await tx.query('tasks',
          columns: ['id', 'alert_plan'], where: 'alert_plan IS NOT NULL')) {
        final i = AlertIntentJson.decode(t['alert_plan']);
        if (i == null || i.follow == null) continue;
        await tx.update('tasks', {'alert_plan': (lead: i.lead, follow: null).encode()},
            where: 'id = ?', whereArgs: [t['id']]);
      }
      return tx.update('reminders', {'enabled': 0, 'sync': 'cancel'},
          where: "kind = 'follow_up' AND enabled = 1");
    });
    if (cancelled > 0) {
      try {
        await onRemindersChanged?.call();
      } catch (_) {} // pending cancels are retried at startup
    }
  }
}

Future<ReminderPreferences> _readPrefs(DatabaseExecutor db) async {
  final rows = await db.query('assistant_preferences', where: 'id = 1');
  if (rows.isEmpty) return const ReminderPreferences();
  final r = rows.first;
  final leads = (r['lead_minutes'] as String)
      .split(',').map(int.tryParse).whereType<int>().toList();
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
}
