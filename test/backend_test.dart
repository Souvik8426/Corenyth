import 'dart:async';
import 'dart:convert';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/data/repos.dart';
import 'package:assistant/services/app_services.dart';
import 'package:assistant/services/model_status.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

// In-memory repos (no sqflite FFI in dev deps, so SQL itself isn't exercised here).
class _NoDb implements Database {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

final _db = _NoDb();
final _now = DateTime(2026, 10, 7, 10);
final log = <String>[];

class FakeTasks extends TaskRepo {
  final rows = <int, Map<String, Object?>>{};
  var _id = 0;
  FakeTasks() : super(_db);
  @override
  Future<Task> create(String title,
      {String? notes, DateTime? due, int priority = 1}) async {
    final id = ++_id;
    rows[id] = {
      'id': id,
      'title': title,
      'notes': notes,
      'status': 'pending',
      'due_at': due?.millisecondsSinceEpoch,
      'priority': priority,
    };
    return Task(rows[id]!);
  }

  @override
  Future<Task?> get(int id) async => rows[id] == null ? null : Task(rows[id]!);
  @override
  Future<List<Task>> list(
          {DateTime? from, DateTime? to, bool includeDone = false}) async =>
      rows.values
          .map(Task.new)
          .where((t) => includeDone || !t.done)
          .where((t) =>
              from == null || (t.dueAt != null && !t.dueAt!.isBefore(from)))
          .where(
              (t) => to == null || (t.dueAt != null && t.dueAt!.isBefore(to)))
          .toList();
  @override
  Future<bool> update(int id, Map<String, Object?> v) async {
    if (rows[id] == null) return false;
    rows[id] = {...rows[id]!, ...v};
    return true;
  }

  @override
  Future<bool> delete(int id) async => rows.remove(id) != null;

  @override
  Future<bool> setAwaiting(int id, String? question) =>
      update(id, {'awaiting': question});

  @override
  Future<List<Task>> awaitingAnswers({String? question}) async => rows.values
      .map(Task.new)
      .where((t) =>
          t.awaiting != null && (question == null || t.awaiting == question))
      .toList()
      .reversed
      .toList();

  @override
  Future<bool> setOutcome(int id, String outcome) async {
    final r = rows[id];
    if (r == null) return false;
    rows[id] = {
      ...r,
      'outcome': outcome.trim(),
      if (r['awaiting'] == TaskRepo.outcomeQuestion) 'awaiting': null,
    };
    return true;
  }

  @override
  Future<bool> setEventDetails(int id,
      {DateTime? endsAt, String? subject}) async {
    final r = rows[id];
    if (r == null) return false;
    final due = r['due_at'] as int?;
    if (endsAt != null && due != null && endsAt.millisecondsSinceEpoch <= due) {
      throw ArgumentError('The end time must be after the start.');
    }
    rows[id] = {
      ...r,
      if (endsAt != null) 'ends_at': endsAt.millisecondsSinceEpoch,
      if (subject != null) 'subject': subject.trim(),
      if (r['awaiting'] == TaskRepo.details) 'awaiting': null,
    };
    return true;
  }
}

class FakeReminders extends ReminderRepo {
  final rows = <int, Map<String, Object?>>{};
  var _id = 0;
  FakeReminders() : super(_db);
  @override
  Future<Reminder> create(String title, DateTime at, {int? taskId}) async {
    final id = ++_id;
    rows[id] = {
      'id': id,
      'title': title,
      'trigger_at': at.millisecondsSinceEpoch,
      'task_id': taskId,
      'enabled': 1,
      'sync': 'schedule',
    };
    return Reminder(rows[id]!);
  }

  @override
  Future<Reminder?> get(int id) async =>
      rows[id] == null ? null : Reminder(rows[id]!);
  @override
  Future<List<Reminder>> upcoming() async =>
      rows.values.map(Reminder.new).where((r) => r.enabled).toList();
  @override
  Future<List<Reminder>> pending() async =>
      rows.values.map(Reminder.new).where((r) => r.sync != null).toList();
  @override
  Future<bool> update(int id, Map<String, Object?> v) async {
    if (rows[id] == null) return false;
    rows[id] = {...rows[id]!, ...v};
    return true;
  }

  @override
  Future<bool> delete(int id) async => rows.remove(id) != null;
}

class FakeMemory extends MemoryRepo {
  final items = <String>[];
  FakeMemory() : super(_db);
  @override
  Future<int> add(String content,
      {String category = 'fact', double importance = 0.5}) async {
    log.add('memory:$content');
    items.add(content);
    return items.length;
  }

  @override
  Future<List<Memory>> search(String query, {int limit = 3}) async => [];
  @override
  Future<List<Memory>> important({int limit = 3}) async => [];
}

class FakeProfile extends ProfileRepo {
  FakeProfile() : super(_db);
  @override
  Future<UserProfile?> get() async => null;
}

class FakeConversations extends ConversationRepo {
  final msgs = <Message>[];
  FakeConversations() : super(_db);
  @override
  Future<void> add(String session, String role, String content) async {
    log.add('$role:$content');
    msgs.add(Message(role, content));
  }

  @override
  Future<List<Message>> recent(String session, {int n = 8}) async =>
      msgs.reversed.take(n).toList().reversed.toList();

  /// Like the SQLite version: the user's messages sharing a term, newest first.
  @override
  Future<List<Message>> relevant(String query, {int limit = 5}) async {
    final ts = MemoryRepo.terms(query);
    return msgs.reversed
        .where(
            (m) => m.role == 'user' && ts.any(m.content.toLowerCase().contains))
        .take(limit)
        .toList();
  }
}

/// Model stand-in: records calls; each call waits on [next] when set.
class SpyEngine extends LlmEngine {
  var calls = 0, cancels = 0, unloads = 0;
  Completer<String>? next;
  String output = '{"type":"respond","text":"model reply"}';
  @override
  String get name => 'spy';
  @override
  Future<bool> load() async => true;
  @override
  Future<void> unload() async => unloads++;
  @override
  Future<String> complete(Prompt p) async {
    calls++;
    return next != null ? await next!.future : output;
  }

  @override
  Future<void> cancel() async => cancels++;
}

/// Engine whose generation fails with a native error code.
class ThrowingEngine extends SpyEngine {
  final String code;
  ThrowingEngine(this.code);
  @override
  Future<String> complete(Prompt p) async {
    calls++;
    throw PlatformException(code: code);
  }
}

class FailingScheduler extends ReminderScheduler {
  bool failSchedule = true, failCancel = true;
  @override
  Future<void> schedule(Reminder r) async {
    if (failSchedule) throw Exception('no exact alarm permission');
  }

  @override
  Future<void> cancel(int id) async {
    if (failCancel) throw Exception('platform error');
  }
}

late FakeTasks tasks;
late FakeReminders reminders;
late FakeMemory memory;
late FakeConversations convs;

AssistantSession session(LlmEngine engine,
    {ReminderScheduler? scheduler, String? id}) {
  return AssistantSession(
    engine: engine,
    tools: ToolExecutor(tasks, reminders, memory, scheduler ?? NoopScheduler(),
        clock: () => _now),
    memory: memory,
    profile: FakeProfile(),
    taskRepo: tasks,
    conversations: convs,
    conversationId: id,
    clock: () => _now,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    tasks = FakeTasks();
    reminders = FakeReminders();
    memory = FakeMemory();
    convs = FakeConversations();
    log.clear();
  });

  test('commands work through the rules when the model reply is not a plan',
      () async {
    final e = SpyEngine(); // legacy output: never valid for the plan grammar
    final s = session(e, id: 'chat-1');
    expect(s.id, 'chat-1');
    await s.start();
    expect(await s.handle('Add task buy milk tomorrow'), contains('buy milk'));
    expect(tasks.rows.length, 1);
    expect(await s.handle('what are my tasks?'), contains('buy milk'));
    expect(await s.handle('complete task 1'), contains('#1'));
    expect(e.calls, 3,
        reason: 'model-first: consulted every conversational turn');
    expect(s.lastFallbackReason, contains('not a valid plan'));
    // a grounded chat plan is shown as the model said it
    e.output = '{"intent":"chat","reply":"Doing great, thanks for asking!"}';
    expect(await s.handle('hey, how is it going'),
        'Doing great, thanks for asking!');
    expect(e.calls, 5, reason: 'chat: the plan, then a reply with recent turns');
    await s.close();
    expect(e.unloads, 0, reason: 'sessions never unload the shared model');
  });

  test('unsupported date phrases are not added as titles or guessed', () async {
    final r = RuleEngine(clock: () => _now);
    for (final s in [
      'add task call mom next friday',
      'add task dentist on 12/03',
      'add task pay rent in 2 weeks',
      'remind me next monday to call Bob',
      'add task tomorrow',
    ]) {
      expect(r.fastRoute(s), isNull, reason: s);
      expect(r.plan(s)['type'], 'respond', reason: s);
    }
    final s = session(RuleEngine(clock: () => _now));
    await s.start();
    expect(await s.handle('add task call mom next friday'),
        contains("didn't add"));
    expect(tasks.rows, isEmpty);
  });

  test('title commands resolve exact titles and ask on duplicates', () async {
    final s = session(SpyEngine());
    await s.start();
    await tasks.create('Buy milk');
    await tasks.create('buy  milk!');
    await tasks.create('Buy milk and eggs');
    final reply = await s.handle('complete task buy milk');
    expect(reply, allOf(contains('#1'), contains('#2'), contains('Which')));
    expect((await tasks.list()).length, 3, reason: 'nothing guessed');
    expect(await s.handle('delete task buy milk and eggs'), contains('#3'));
    expect(tasks.rows.containsKey(3), isFalse);
    expect(await s.handle('delete task walk the cat'), contains('No task'));
  });

  test('cancel during generation prevents the tool from running', () async {
    final e = SpyEngine()..next = Completer();
    final s = session(e);
    await s.start();
    final reply = s.handle('could you jot down something for me');
    await Future<void>.delayed(Duration.zero);
    while (e.calls == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final cancelled = s.cancel();
    // generation finishes anyway with an action
    e.next!.complete(
        '{"type":"tool","tool":"create_task","arguments":{"title":"x"}}');
    await cancelled;
    expect(await reply, '');
    expect(e.cancels, 1);
    expect(tasks.rows, isEmpty);
    expect(s.current, SessionState.listening);
  });

  test('close awaits in-flight start/turn, is idempotent and never unloads',
      () async {
    final e = SpyEngine()..next = Completer();
    final s = session(e);
    await s.close(); // never started
    final starting = s.start();
    final closing = s.close(); // during start
    await starting;
    await closing;
    expect(s.current, SessionState.idle);

    final s2 = session(e);
    await s2.start();
    final turn = s2.handle('tell me something nice');
    while (e.calls < 1) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final c1 = s2.close(), c2 = s2.close();
    expect(identical(c1, c2), isTrue);
    e.next!.complete('{"type":"respond","text":"hi"}');
    await c1;
    expect(await turn, '');
    expect(s2.current, SessionState.idle);
    await expectLater(s2.handle('hello'), throwsStateError);
    expect(e.unloads, 0);
  });

  test('explicit remember is saved before the success reply', () async {
    final s = session(SpyEngine());
    await s.start();
    expect(
        await s.handle('Remember that I like green tea'), contains('remember'));
    expect(memory.items, ['User likes green tea']);
    expect(log.indexOf('memory:User likes green tea'),
        lessThan(log.indexWhere((l) => l.startsWith('assistant:'))));
    // personal facts are captured incrementally; close does no extraction
    await s.handle('I work as a nurse');
    expect(memory.items, contains('User works as a nurse'));
    expect(await s.close(), hasLength(2));
    // "remember to" is a request, not a memory
    final s2 = session(SpyEngine());
    await s2.start();
    await s2.handle('remember to buy bread');
    expect(memory.items, hasLength(2));
  });

  test('strict envelope, positive ids and real calendar datetimes', () {
    String tool(String t, String args) =>
        '{"type":"tool","tool":"$t","arguments":$args}';
    for (final bad in [
      tool('create_task', '{"title":"a","due":"2026-02-30T10:00:00"}'),
      tool('create_task', '{"title":"a","due":"2026-02-29T10:00:00"}'),
      tool('create_task', '{"title":"a","due":"2026-10-09T25:00:00"}'),
      tool('create_task', '{"title":"a","due":"2026-10-09T10:60:00"}'),
      tool('create_task', '{"title":"a","due":"2026-13-01T10:00:00"}'),
      tool('create_task', '{"title":"a","due":"2026-10-09T10:00:00Z"}'),
      tool('create_task', '{"title":"a","due":"2026-10-09"}'),
      tool('complete_task', '{"id":0}'),
      tool('delete_task', '{"id":-3}'),
      tool('complete_task', '{}'),
      tool('create_task', '{"title":"a","bogus":1}'),
      tool('respond', '{"text":"x"}'),
      '{"tool":"create_task","arguments":{"title":"a"}}',
      '{"type":"tool","tool":"create_task"}',
      '{"type":"respond"}',
    ]) {
      expect(() => parseToolCall(bad), throwsA(isA<ToolError>()), reason: bad);
    }
    expect(
        parseToolCall(tool(
                'create_task', '{"title":"a","due":"2028-02-29T10:00:00"}'))
            .args['due'],
        DateTime(2028, 2, 29, 10));
    expect(parseToolCall(tool('complete_task', '{"title":"Buy milk"}')).args,
        {'title': 'Buy milk'});
  });

  test('prompt_too_long asks for shorter input, never falls back', () async {
    final s = session(ThrowingEngine('prompt_too_long'));
    await s.start();
    expect(
        await s.handle('tell me a long story'), AssistantSession.tooLongReply);
    expect(s.lastFallbackReason, isNull);
    expect(s.lastTiming.keys, containsAll(['route', 'context', 'total']));
  });

  test('llama_cancelled ends the turn with no reply or action', () async {
    final s = session(ThrowingEngine('llama_cancelled'));
    await s.start();
    expect(await s.handle('jot something down'), '');
    expect(convs.msgs.where((m) => m.role == 'assistant'), isEmpty);
    expect(s.lastFallbackReason, isNull);
  });

  test('real model failure falls back and says why; reset next turn', () async {
    final s = session(ThrowingEngine('llama_error'));
    await s.start();
    await s.handle('how are you doing');
    expect(s.lastFallbackReason, contains('llama_error'));
    expect(await s.handle('add task Call Bob'), contains('Call Bob'),
        reason: 'rules fallback');
    expect(s.lastFallbackReason, contains('llama_error'));
    await s.handle('2+2'); // app-side calculator: no model, reason reset
    expect(s.lastFallbackReason, isNull);
  });

  test('fast route keeps casing, greets, and skips negated/compound text', () {
    final r = RuleEngine(clock: () => _now);
    expect(
        (r.fastRoute('Add task Call Bob tomorrow')!['arguments']
            as Map)['title'],
        'Call Bob');
    expect(
        (r.fastRoute('remind me at 5pm to call Mom')!['arguments']
            as Map)['title'],
        'call Mom');
    expect(r.fastRoute('Hello!')!['type'], 'respond');
    expect(r.fastRoute('What are my tasks for today')!['tool'], 'list_tasks');
    for (final t in [
      "don't add task buy milk",
      'delete task tea or coffee',
      'add task buy milk and remind me at 5pm',
      'add task buy milk; delete task 2',
      'do not remind me at 5pm to call',
    ]) {
      expect(r.fastRoute(t), isNull, reason: t);
    }
  });

  test('plan never mutates on negated or unanchored text', () async {
    final r = RuleEngine(clock: () => _now);
    for (final t in [
      'do not delete task 3',
      "don't complete task 1",
      'please never cancel reminder 2',
      'I might delete task 3 later',
      'should I finish task 2 or not',
    ]) {
      expect(r.plan(t)['type'], 'respond', reason: t);
    }
    final s = session(RuleEngine(clock: () => _now));
    await s.start();
    await tasks.create('Keep me');
    await tasks.create('Me too');
    await tasks.create('And me');
    for (final t in [
      'do not delete task 3',
      'never complete task 1',
      'I will delete task 2 tomorrow'
    ]) {
      await s.handle(t);
    }
    expect(tasks.rows.length, 3);
    expect((await tasks.list()).length, 3, reason: 'nothing completed');
  });

  test('edits by unambiguous target title, never guessing', () async {
    final x = ToolExecutor(tasks, reminders, memory, NoopScheduler(),
        clock: () => _now);
    await tasks.create('Buy milk');
    await tasks.create('Call Bob');
    await tasks.create('call bob!');
    final r = RuleEngine(clock: () => _now);
    final rename = parseToolCall(
        jsonEncode(r.fastRoute('rename task Buy milk to Buy oat milk')));
    expect(rename.args, {'target_title': 'Buy milk', 'title': 'Buy oat milk'});
    expect(await x.execute(rename), contains('#1'));
    expect((await tasks.get(1))!.title, 'Buy oat milk');
    await expectLater(
        x.execute(
            ToolCall('edit_task', {'target_title': 'Call Bob', 'title': 'x'})),
        throwsA(
            isA<ToolError>().having((e) => e.message, 'm', contains('Which'))));
    expect((await tasks.get(2))!.title, 'Call Bob');
    // numeric API preserved; exactly one selector
    expect(await x.execute(ToolCall('edit_task', {'id': 2, 'priority': 2})),
        contains('#2'));
    String tool(String a) =>
        '{"type":"tool","tool":"edit_task","arguments":$a}';
    for (final bad in [
      '{"title":"x"}',
      '{"id":1,"target_title":"Buy","title":"x"}'
    ]) {
      expect(() => parseToolCall(tool(bad)), throwsA(isA<ToolError>()),
          reason: bad);
    }
    // reminder by title
    await x.execute(ToolCall('create_reminder',
        {'title': 'Dentist', 'at': _now.add(const Duration(hours: 1))}));
    final move = parseToolCall(
        jsonEncode(r.fastRoute('move reminder Dentist to tomorrow at 9am')));
    expect(move.args['target_title'], 'Dentist');
    expect(await x.execute(move), contains('#1'));
    expect((await reminders.get(1))!.triggerAt, DateTime(2026, 10, 8, 9));
  });

  test('widget refresh failure never fails a committed write', () async {
    final x = ToolExecutor(tasks, reminders, memory, NoopScheduler(),
        clock: () => _now,
        onTasksChanged: () async => throw Exception('widget'));
    expect(await x.execute(ToolCall('create_task', {'title': 'Once'})),
        contains('Added'));
    await Future<void>.delayed(Duration.zero);
    expect(tasks.rows.length, 1);
  });

  test('ensureModel re-checks native residency even when marked loaded',
      () async {
    const ch = MethodChannel('assistant/llm');
    final results = [true, true, false, true];
    var loads = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, (c) async {
      if (c.method == 'load') return results[loads++];
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null));
    final app = AppServices(_db, NoopScheduler(), '/m.gguf');
    final seen = <ModelLoad>[];
    app.modelLoad.addListener(() => seen.add(app.modelLoad.value));
    expect(await app.ensureModel(), isTrue);
    expect(seen, [ModelLoad.loading, ModelLoad.loaded]);
    expect(await app.ensureModel(), isTrue); // silent check, no spinner churn
    expect(seen, [ModelLoad.loading, ModelLoad.loaded]);
    // released elsewhere and the reload fails: status turns truthful
    expect(await app.ensureModel(), isFalse);
    expect(app.modelLoad.value, ModelLoad.failed);
    expect(await app.ensureModel(), isTrue);
    expect(loads, 4, reason: 'native asked every time');
    await app.releaseModel();
    expect(app.modelLoad.value, ModelLoad.idle);
  });

  group('reminder scheduling failures', () {
    test('create rolls back and reports failure', () async {
      final x = ToolExecutor(tasks, reminders, memory, FailingScheduler(),
          clock: () => _now);
      await expectLater(
          x.execute(ToolCall('create_reminder',
              {'title': 'call', 'at': _now.add(const Duration(hours: 1))})),
          throwsA(isA<ToolError>()));
      expect(reminders.rows, isEmpty);
    });

    test('edit restores the old reminder', () async {
      final sch = FailingScheduler()..failSchedule = false;
      final x = ToolExecutor(tasks, reminders, memory, sch, clock: () => _now);
      await x.execute(ToolCall('create_reminder',
          {'title': 'call', 'at': _now.add(const Duration(hours: 1))}));
      sch.failSchedule = true;
      await expectLater(
          x.execute(ToolCall('edit_reminder', {'id': 1, 'title': 'other'})),
          throwsA(isA<ToolError>()));
      expect((await reminders.get(1))!.title, 'call');
    });

    test('failed cancel stays cancelled and is retried, never re-armed',
        () async {
      final sch = FailingScheduler()..failSchedule = false;
      final x = ToolExecutor(tasks, reminders, memory, sch, clock: () => _now);
      await x.execute(ToolCall('create_reminder',
          {'title': 'call', 'at': _now.add(const Duration(hours: 1))}));
      expect((await reminders.get(1))!.sync, isNull);
      await expectLater(
          x.execute(ToolCall('cancel_reminder', {'title': 'Call'})),
          throwsA(isA<ToolError>().having(
              (e) => e.message, 'message', contains('may still go off'))));
      final r = (await reminders.get(1))!;
      expect(r.enabled, isFalse);
      expect(r.sync, 'cancel');
      // next start: cancel still fails -> reported, and not re-armed
      final scheduled = <int>[];
      final startup = _CountingScheduler(() => false,
          failCancel: true, scheduled: scheduled);
      expect(await startup.rescheduleAll(reminders), [1]);
      expect(scheduled, isEmpty);
      // recovery: cancel succeeds, intent cleared
      expect(await _CountingScheduler(() => false).rescheduleAll(reminders),
          isEmpty);
      expect((await reminders.get(1))!.sync, isNull);
      expect((await reminders.get(1))!.enabled, isFalse);
    });

    test('interrupted create is scheduled at startup', () async {
      await reminders.create('a', _now); // sync = 'schedule', app died here
      final sch = _CountingScheduler(() => false);
      expect(await sch.rescheduleAll(reminders), isEmpty);
      expect(sch.scheduled, [1]);
      expect((await reminders.get(1))!.sync, isNull);
    });

    test('startup reschedule continues past failures', () async {
      await reminders.create('a', _now);
      await reminders.create('b', _now);
      var n = 0;
      final sch = _CountingScheduler(() => ++n == 1);
      expect(await sch.rescheduleAll(reminders), [1]);
      expect(sch.scheduled, [2]);
    });
  });
}

class _CountingScheduler extends ReminderScheduler {
  final bool Function() fail;
  final bool failCancel;
  final List<int> scheduled;
  _CountingScheduler(this.fail, {this.failCancel = false, List<int>? scheduled})
      : scheduled = scheduled ?? [];
  @override
  Future<void> schedule(Reminder r) async {
    if (fail()) throw Exception('boom');
    scheduled.add(r.id);
  }

  @override
  Future<void> cancel(int id) async {
    if (failCancel) throw Exception('boom');
  }
}
