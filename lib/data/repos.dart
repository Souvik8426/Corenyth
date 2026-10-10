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
  final int id;
  final int? taskId;
  final String title;
  final DateTime triggerAt;
  final bool enabled;
  Reminder(Map<String, Object?> r)
      : id = r['id'] as int,
        taskId = r['task_id'] as int?,
        title = r['title'] as String,
        triggerAt = _dt(r['trigger_at'])!,
        enabled = r['enabled'] == 1;
  @override
  String toString() => '#$id $title at ${triggerAt.toIso8601String()}';
}

class TaskRepo {
  final Database db;
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

  Future<bool> update(int id, Map<String, Object?> values) async =>
      await db.update('tasks', values, where: 'id = ?', whereArgs: [id]) > 0;

  Future<bool> complete(int id) =>
      update(id, {'status': 'done', 'completed_at': _now()});

  Future<bool> delete(int id) async =>
      await db.delete('tasks', where: 'id = ?', whereArgs: [id]) > 0;
}

class ReminderRepo {
  final Database db;
  ReminderRepo(this.db);

  Future<Reminder> create(String title, DateTime at, {int? taskId}) async {
    final id = await db.insert('reminders', {
      'title': title,
      'trigger_at': at.millisecondsSinceEpoch,
      'task_id': taskId,
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

  Future<bool> cancel(int id) => update(id, {'enabled': 0});
}

class Message {
  final String role, content;
  Message(this.role, this.content);
}

class ConversationRepo {
  final Database db;
  ConversationRepo(this.db);

  Future<void> add(String session, String role, String content) =>
      db.insert('conversations', {
        'session_id': session,
        'role': role,
        'content': content,
        'created_at': _now(),
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
    'the', 'and', 'what', 'did', 'you', 'when', 'do', 'is', 'are', 'about',
    'tell', 'me', 'my', 'for', 'with', 'that', 'this', 'how', 'who', 'have',
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
}
