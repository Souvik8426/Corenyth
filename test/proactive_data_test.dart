import 'package:assistant/data/repos.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

import 'support/v2_db.dart';

void main() {
  late Database db;
  late TaskRepo tasks;
  late ReminderRepo reminders;
  late ConversationRepo chats;
  final now = DateTime.now();
  // Tomorrow 15:00: in the future and outside the default quiet hours.
  final at = DateTime(now.year, now.month, now.day + 1, 15);

  setUp(() async {
    db = await openMigratedV2(seed: (old) async {
      await old.insert(
          'tasks', {'title': 'legacy', 'created_at': 1, 'due_at': 9000});
      await old.insert('conversations', {
        'session_id': 'old',
        'role': 'user',
        'content': 'Ask Aditya Sharma to arrange the client meeting',
        'created_at': 1000
      });
    });
    tasks = TaskRepo(db);
    reminders = ReminderRepo(db);
    chats = ConversationRepo(db);
  });

  Future<Task> meeting({int? follow = 60}) async {
    final plan = reminderPlan(at, const ReminderPreferences(),
        multiple: false, followUp: follow != null, now: now);
    final r = await reminders.createPlan('Client meeting', at, plan,
        intent: (lead: const [], follow: follow));
    return (await tasks.get(r.first.taskId!))!;
  }

  test('migration keeps legacy rows; old constructors stay valid', () async {
    final legacy = (await tasks.list(includeDone: true)).single;
    expect(
        (legacy.title, legacy.dueAt!.millisecondsSinceEpoch), ('legacy', 9000));
    expect([
      legacy.endsAt,
      legacy.subject,
      legacy.deadlineAt,
      legacy.dailyMinute,
      legacy.awaiting,
      legacy.outcome
    ], everyElement(isNull));
    final m = (await chats.messages('old')).single;
    expect((m.role, m.createdAt!.millisecondsSinceEpoch, m.taskId, m.kind),
        ('user', 1000, null, null));
    final plain = Message('user', 'hi');
    expect((plain.createdAt, plain.taskId, plain.kind), (null, null, null));
    expect(ChatSummary('a', '', DateTime(2026)).isMain, isFalse);
  });

  test('quiet hours default to 22:00-07:00 until the user turns them off',
      () async {
    final prefs = ReminderPreferencesRepo(db);
    final p = await prefs.get();
    expect((p.quietStart, p.quietEnd, p.reviewMinute),
        (22 * 60, 7 * 60, 21 * 60 + 30));
    await prefs.save(p.copyWith(clearQuiet: true));
    expect((await prefs.get()).hasQuietHours, isFalse,
        reason: 'explicit off is kept');
    expect((await prefs.get()).reviewMinute, 21 * 60 + 30);
    await prefs.save(p.copyWith(quiet: (23 * 60, 6 * 60)));
    expect((await prefs.get()).reviewMinute, 22 * 60 + 30);
    expect(
        const ReminderPreferences(quietStart: 15, quietEnd: 400).reviewMinute,
        1425,
        reason: 'wraps before midnight');
  });

  test('enabling follow-ups and changing DND notify the scheduler after saving',
      () async {
    final prefs = ReminderPreferencesRepo(db);
    var syncs = 0;
    prefs.onRemindersChanged = () async {
      expect((await prefs.get()).followUp, isTrue);
      syncs++;
    };
    final p = (await prefs.get()).copyWith(followUp: true);
    await prefs.save(p);
    await prefs.save(p.copyWith(quiet: (23 * 60, 7 * 60)));
    expect(syncs, 2);
  });

  test('context spans chats: only the user\'s matching words, best first',
      () async {
    await chats.add('b', 'user', 'Book flights');
    await chats.add('b', 'assistant', 'Aditya Sharma is on your list');
    await chats.add('c', 'user', 'Aditya Kumar sent the invoice');
    final hits = await chats.relevant("Aditya Sharma hasn't replied");
    expect(hits.map((m) => m.content), [
      'Ask Aditya Sharma to arrange the client meeting', // two shared words
      'Aditya Kumar sent the invoice',
    ]);
    expect(await chats.relevant('the and'), isEmpty, reason: 'stop words only');
  });

  test('a duplicate proactive event adds one main-chat message, never replayed',
      () async {
    final t = await meeting();
    final r =
        (await reminders.forTask(t.id)).firstWhere((r) => r.kind == 'reminder');
    expect(
        await chats.addProactive(alertKey(r), 'Client meeting now',
            taskId: t.id, kind: 'nudge'),
        isTrue);
    expect(
        await chats.addProactive(alertKey(r), 'Client meeting now',
            taskId: t.id, kind: 'nudge'),
        isFalse);
    final main = await chats.messages(ConversationRepo.mainChatId);
    expect(main.map((m) => (m.role, m.taskId, m.kind)),
        [('assistant', t.id, 'nudge')]);
    expect((await chats.listChats()).where((c) => c.isMain).single.id, 'main');
    expect(await chats.delivered(alertKey(r)), isTrue);

    await chats.deleteChat(ConversationRepo.mainChatId);
    expect(
        await chats.addProactive(alertKey(r), 'again', kind: 'nudge'), isFalse,
        reason: 'deleting the chat does not replay old occurrences');
    expect(
        await chats.addProactive(reviewKey(at), 'How was today?',
            kind: 'review'),
        isTrue);
    expect((await chats.messages('main')).single.content, 'How was today?');
    // A moved alert is a new occurrence.
    final moved =
        Reminder({'id': r.id, 'title': r.title, 'trigger_at': 1, 'enabled': 1});
    expect(alertKey(moved), isNot(alertKey(r)));
  });

  test('completed and deleted tasks lose every alarm with a durable cancel',
      () async {
    final a = await meeting(), b = await meeting();
    await tasks.complete(a.id);
    await tasks.delete(b.id);
    expect(await reminders.forTask(a.id), isEmpty);
    expect(await reminders.upcoming(), isEmpty);
    expect((await reminders.pending()).map((r) => (r.enabled, r.sync)).toSet(),
        {(false, 'cancel')});
  });

  test('meeting details: open question survives restart; end replaces estimate',
      () async {
    final t = await meeting();
    await tasks.setAwaiting(t.id, TaskRepo.details);
    // "Restart": fresh repos on the same file, any chat.
    final again = TaskRepo(db);
    expect((await again.awaitingAnswers(question: TaskRepo.details)).single.id,
        t.id);
    await expectLater(
        again.setEventDetails(t.id, endsAt: at), throwsArgumentError);

    final end = at.add(const Duration(minutes: 90));
    expect(await again.setEventDetails(t.id, endsAt: end, subject: ' Pricing '),
        isTrue);
    final saved = (await again.get(t.id))!;
    expect(
        (saved.endsAt, saved.subject, saved.awaiting), (end, 'Pricing', null));
    final follow = (await reminders.forTask(t.id))
        .firstWhere((r) => r.kind == 'follow_up');
    expect((follow.triggerAt, follow.sync), (end, 'schedule'));

    // Moving the meeting moves its end and the follow-up with it.
    await again.update(t.id,
        {'due_at': at.add(const Duration(days: 1)).millisecondsSinceEpoch});
    expect((await again.get(t.id))!.endsAt, end.add(const Duration(days: 1)));
    expect(
        (await reminders.forTask(t.id))
            .firstWhere((r) => r.kind == 'follow_up')
            .triggerAt,
        end.add(const Duration(days: 1)));

    // Unanswered details never block: the follow-up estimate stands.
    final other = await meeting();
    await tasks.setAwaiting(other.id, TaskRepo.details);
    expect((await reminders.forTask(other.id)).map((r) => r.kind),
        ['reminder', 'follow_up']);
  });

  test(
      'a known end replaces a quiet estimate and can restore a skipped follow-up',
      () async {
    final t = await meeting();
    final quietEnd = DateTime(at.year, at.month, at.day, 23);
    await tasks.setEventDetails(t.id, endsAt: quietEnd);
    expect((await reminders.forTask(t.id)).where((r) => r.kind == 'follow_up'),
        isEmpty,
        reason: 'do not leave the old 4 PM estimate after learning the end');
    final earlierEnd = DateTime(at.year, at.month, at.day, 19);
    await tasks.setEventDetails(t.id, endsAt: earlierEnd);
    expect(
        (await reminders.forTask(t.id))
            .singleWhere((r) => r.kind == 'follow_up')
            .triggerAt,
        earlierEnd);
  });

  test('reconciliation preserves a future snoozed daily occurrence', () async {
    final t = await tasks.create('Renew domain');
    final before = DateTime(at.year, at.month, at.day, 7);
    await tasks.setDaily(t.id, 8 * 60 + 46, now: before);
    final snoozed = DateTime(at.year, at.month, at.day, 11);
    await tasks.update(t.id, {'due_at': snoozed.millisecondsSinceEpoch});
    expect(await tasks.advanceDaily(t.id, before), snoozed);
    expect((await tasks.get(t.id))!.dueAt, snoozed);
  });

  test('an outcome closes its question so it is not asked again', () async {
    final t = await meeting();
    await tasks.complete(t.id);
    await tasks.setAwaiting(t.id, TaskRepo.outcomeQuestion);
    expect((await tasks.awaitingAnswers()).single.done, isTrue);
    await tasks.setOutcome(t.id, 'They signed; send the contract Friday');
    expect((await tasks.get(t.id))!.outcome,
        'They signed; send the contract Friday');
    expect(await tasks.awaitingAnswers(), isEmpty);
  });

  test('nextDaily: today or tomorrow, until is inclusive, months roll over',
      () {
    final m = 8 * 60 + 46;
    expect(
        nextDaily(m, DateTime(2026, 10, 15, 8)), DateTime(2026, 10, 15, 8, 46));
    expect(nextDaily(m, DateTime(2026, 10, 15, 8, 46)),
        DateTime(2026, 10, 16, 8, 46));
    expect(
        nextDaily(m, DateTime(2026, 10, 31, 9)), DateTime(2026, 11, 1, 8, 46));
    expect(
        nextDaily(m, DateTime(2026, 11, 4, 9), DateTime(2026, 11, 5, 23, 59)),
        DateTime(2026, 11, 5, 8, 46));
    expect(
        nextDaily(m, DateTime(2026, 11, 5, 9), DateTime(2026, 11, 5, 23, 59)),
        isNull);
  });

  test('daily until deadline: skips missed days, stops at deadline or done',
      () async {
    final t = await tasks.create('Renew domain');
    final start = DateTime(now.year, now.month, now.day, 7);
    final deadline = DateTime(now.year, now.month, now.day + 3, 23, 59);
    final first =
        await tasks.setDaily(t.id, 8 * 60 + 46, deadline: deadline, now: start);
    expect(first, DateTime(now.year, now.month, now.day, 8, 46));
    final alert = (await reminders.forTask(t.id)).single;
    expect((alert.kind, alert.triggerAt), ('reminder', first));

    // App closed two days: one next occurrence, same alert row, deadline kept.
    final later = DateTime(now.year, now.month, now.day + 2, 12);
    final next = await tasks.advanceDaily(t.id, later);
    expect(next, DateTime(now.year, now.month, now.day + 3, 8, 46));
    final row = (await reminders.forTask(t.id)).single;
    expect((row.id, row.triggerAt), (alert.id, next));
    expect((await tasks.get(t.id))!.deadlineAt, deadline);

    // Past the deadline: alerts stop, the task stays pending for the review.
    expect(
        await tasks.advanceDaily(
            t.id, deadline.add(const Duration(minutes: 1))),
        isNull);
    expect(await reminders.forTask(t.id), isEmpty);
    expect((await tasks.get(t.id))!.done, isFalse);

    // Completing a daily task ends its recurrence.
    final u = await tasks.create('Water plants');
    await tasks.setDaily(u.id, 9 * 60, now: start);
    await tasks.complete(u.id);
    expect((await tasks.get(u.id))!.dailyMinute, isNull);
    expect(await tasks.advanceDaily(u.id, later), isNull);
    expect(await reminders.forTask(u.id), isEmpty);
    expect(await tasks.setDaily(u.id, 9 * 60, now: start), isNull,
        reason: 'done task');
  });

  test('evening review keeps raising ignored tasks without rescheduling them',
      () async {
    final review = ReviewRepo(db);
    for (final t in await tasks.list()) {
      await tasks.delete(t.id); // the overdue legacy row would be raised too
    }
    final today = DateTime(now.year, now.month, now.day, 21, 30);
    DateTime day(int d, int h) => DateTime(now.year, now.month, now.day + d, h);
    final errand = await tasks.create('Buy milk', due: day(0, 17));
    final nextWeek = await tasks.create('Send report', due: day(7, 9));
    final tomorrow = await tasks.create('Dentist', due: day(1, 10));
    final done = await tasks.create('Call Kabir', due: day(0, 11));
    await tasks.complete(done.id);
    await tasks.create('Someday idea');

    var a = await review.agenda(today);
    expect(a.unresolved.map((t) => t.id), [errand.id]);
    expect(a.finished.map((t) => t.id), [done.id]);
    expect(a.tomorrow.map((t) => t.id), [tomorrow.id]);

    await review.record(today, [errand.id, nextWeek.id]);
    await review.record(today, [errand.id]); // idempotent
    final tonight = day(1, 21);
    a = await review.agenda(tonight);
    expect(
        a.unresolved.map((t) => t.id), containsAll([errand.id, nextWeek.id]));
    expect(await review.ignoredCounts(), {errand.id: 1, nextWeek.id: 1});
    expect((await tasks.get(nextWeek.id))!.dueAt, day(7, 9),
        reason: 'not moved');

    await review.answered(nextWeek.id);
    a = await review.agenda(tonight);
    expect(a.unresolved.map((t) => t.id), isNot(contains(nextWeek.id)));
    await tasks.delete(errand.id);
    expect(await review.ignoredCounts(), isEmpty);
  });
}
