import 'package:assistant/data/repos.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/services/app_services.dart';
import 'package:assistant/services/proactive.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/v2_db.dart';

/// Records what would reach Android: notifications and the review alarm.
class _Native extends ReminderScheduler {
  final notices = <ProactiveNotice>[];
  final reviews = <DateTime?>[];
  bool refuse = false;
  @override
  Future<void> schedule(Reminder r) async {}
  @override
  Future<void> cancel(int id) async {}
  @override
  Future<void> notify(ProactiveNotice n) async {
    if (refuse) throw Exception('notifications turned off');
    notices.add(n);
  }

  @override
  Future<void> scheduleReview(DateTime? at) async => reviews.add(at);
}

void main() {
  late AppServices app;
  late _Native native;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow3pm = DateTime(now.year, now.month, now.day + 1, 15);

  setUp(() async {
    native = _Native();
    app = AppServices(await openMigratedV2(), native, '/m.gguf');
  });

  Future<List<Message>> mainChat() =>
      app.conversations.messages(ConversationRepo.mainChatId);
  int ms(DateTime t) => t.millisecondsSinceEpoch;

  Future<List<Reminder>> plan(
          String title, DateTime at, List<PlannedAlert> alerts) =>
      app.reminders.createPlan(title, at, alerts);

  test('widget completion works without a reminder and refreshes listeners', () async {
    final task = await app.tasks.create('A task from the widget');
    final before = app.proactiveChanged.value;
    await app.runProactive(['widgetDone', task.id]);
    expect((await app.tasks.get(task.id))!.done, isTrue);
    expect(app.proactiveChanged.value, before + 1);
    await app.runProactive(['widgetDone', task.id]);
    await app.runProactive(['widgetDone', -1]);
    expect((await app.tasks.get(task.id))!.done, isTrue);
  });

  test('widget completion cancels the task reminder plan', () async {
    final reminders = await plan('Widget completion', tomorrow3pm,
        [(kind: 'reminder', at: tomorrow3pm)]);
    final taskId = reminders.single.taskId!;
    await app.runProactive(['widgetDone', taskId]);
    expect((await app.tasks.get(taskId))!.done, isTrue);
    expect((await app.reminders.get(reminders.single.id))!.enabled, isFalse);
  });

  test('an empty-day review still invites a conversation about tomorrow',
      () async {
    await app.preferences.save(const ReminderPreferences(followUp: true));
    final evening = today.add(const Duration(hours: 21, minutes: 30));
    expect(await app.deliverReview(now: evening), isTrue);
    expect((await mainChat()).single.content, contains('How was your day?'));
    expect(native.notices.single.body, contains('tomorrow'));
  });

  test('reboot catch-up records a recent daily occurrence before advancing it',
      () async {
    final t = await app.tasks.create('Renew domain');
    await app.tasks
        .setDaily(t.id, 9 * 60, now: today.add(const Duration(hours: 8)));
    await app.catchUp(now: today.add(const Duration(hours: 9, minutes: 4)));
    expect(
        (await mainChat()).where((m) => m.taskId == t.id && m.kind == 'daily'),
        hasLength(1));
    expect((await app.tasks.get(t.id))!.dueAt,
        today.add(const Duration(days: 1, hours: 9)));
  });

  test('a late meeting is upcoming at review time, not already overdue',
      () async {
    await app.preferences.save(const ReminderPreferences(followUp: true));
    final meeting = await app.tasks.create('High on AI meeting',
        due: today.add(const Duration(hours: 22, minutes: 30)));
    final evening = today.add(const Duration(hours: 21, minutes: 30));
    await app.deliverReview(now: evening);
    final text = (await mainChat()).single.content;
    expect(text, contains('Later today:'));
    expect(text, isNot(contains('How did these go')));
    expect(await app.review.ignoredCounts(), isNot(contains(meeting.id)));
  });

  test('outcome notification asks the same question as its main-chat message',
      () async {
    final at = tomorrow3pm.add(const Duration(hours: 1));
    final r = (await plan(
            'Client meeting', tomorrow3pm, [(kind: 'follow_up', at: at)]))
        .single;
    await app.deliverAlert(r.id, ms(at), now: at);
    expect(native.notices.single.body, contains('How did'));
    expect(native.notices.single.body, (await mainChat()).single.content);
  });

  test('changing quiet hours restores optional alerts previously skipped',
      () async {
    await app.preferences.save(const ReminderPreferences(
        multiple: true, followUp: true, quietStart: 1320, quietEnd: 420));
    final at = today.add(const Duration(days: 1, hours: 5, minutes: 30));
    await app.executor().execute(
        ToolCall('create_reminder', {'title': 'Early meeting', 'at': at}));
    final meeting = (await app.tasks.byTitle('Early meeting')).single;
    expect((await app.reminders.forTask(meeting.id)).map((r) => r.kind),
        ['reminder']);
    await app.preferences.save(const ReminderPreferences(
        multiple: true, followUp: true, quietStart: 1380, quietEnd: 240));
    expect((await app.reminders.forTask(meeting.id)).map((r) => r.kind),
        containsAll(['pre', 'reminder', 'follow_up']));
  });

  test('event alarm: one main-chat message and one notification per occurrence',
      () async {
    final r = (await plan(
            'Dentist', tomorrow3pm, [(kind: 'reminder', at: tomorrow3pm)]))
        .single;
    expect(await app.deliverAlert(r.id, ms(tomorrow3pm), now: tomorrow3pm),
        isTrue);
    expect(await app.deliverAlert(r.id, ms(tomorrow3pm), now: tomorrow3pm),
        isFalse,
        reason: 'alarm and catch-up may both run');
    final m = (await mainChat()).single;
    expect(m.content, contains('Dentist'));
    expect((m.kind, m.taskId), ('reminder', r.taskId));
    final n = native.notices.single;
    expect((n.id, n.target), (r.id, 'task:${r.taskId}'));
    expect(n.actions, ['done', 'snooze']);
  });

  test('stale alarms are dropped: moved, done, deleted', () async {
    final r = (await plan(
            'Call Ana', tomorrow3pm, [(kind: 'reminder', at: tomorrow3pm)]))
        .single;
    final later = tomorrow3pm.add(const Duration(hours: 1));
    await app.tasks.update(r.taskId!, {'due_at': ms(later)});
    expect(await app.deliverAlert(r.id, ms(tomorrow3pm), now: tomorrow3pm),
        isFalse,
        reason: 'the old trigger time is not current any more');
    await app.tasks.complete(r.taskId!);
    expect(await app.deliverAlert(r.id, ms(later), now: later), isFalse);
    final d =
        (await plan('Gym', tomorrow3pm, [(kind: 'reminder', at: tomorrow3pm)]))
            .single;
    await app.tasks.delete(d.taskId!);
    expect(await app.deliverAlert(d.id, ms(tomorrow3pm), now: tomorrow3pm),
        isFalse);
    expect(await mainChat(), isEmpty);
    expect(native.notices, isEmpty);
  });

  test('nudge before the start only; follow-up opens the outcome question once',
      () async {
    final pre = tomorrow3pm.subtract(const Duration(minutes: 30));
    final follow = tomorrow3pm.add(const Duration(hours: 1));
    final rs = await plan('Standup', tomorrow3pm, [
      (kind: 'pre', at: pre),
      (kind: 'reminder', at: tomorrow3pm),
      (kind: 'follow_up', at: follow),
    ]);
    final nudge = rs.firstWhere((r) => r.kind == 'pre');
    expect(
        await app.deliverAlert(nudge.id, ms(pre),
            now: tomorrow3pm.add(const Duration(minutes: 1))),
        isFalse,
        reason: 'late nudge after the start is pointless');
    expect(await app.deliverAlert(nudge.id, ms(pre), now: pre), isTrue);
    expect((await mainChat()).last.kind, 'nudge');
    final f = rs.firstWhere((r) => r.kind == 'follow_up');
    expect(await app.deliverAlert(f.id, ms(follow), now: follow), isTrue);
    expect(
        (await app.tasks.get(f.taskId!))!.awaiting, TaskRepo.outcomeQuestion);
    expect(native.notices.last.target, 'chat:main');

    final rs2 = await plan('Retro', tomorrow3pm,
        [(kind: 'reminder', at: tomorrow3pm), (kind: 'follow_up', at: follow)]);
    final f2 = rs2.firstWhere((r) => r.kind == 'follow_up');
    await app.tasks.setOutcome(f2.taskId!, 'went fine');
    expect(await app.deliverAlert(f2.id, ms(follow), now: follow), isFalse,
        reason: 'an outcome already given is not asked again');
  });

  test('optional check-ins respect quiet hours; the event alarm does not',
      () async {
    final night = DateTime(now.year, now.month, now.day + 1, 23);
    final rs = await plan('Night call', night, [
      (kind: 'pre', at: night.subtract(const Duration(minutes: 10))),
      (kind: 'reminder', at: night),
    ]); // as if saved before quiet hours applied (no preferences row = 22:00-07:00)
    final pre = rs.firstWhere((r) => r.kind == 'pre');
    expect(
        await app.deliverAlert(pre.id, ms(pre.triggerAt), now: pre.triggerAt),
        isFalse);
    final event = rs.firstWhere((r) => r.kind == 'reminder');
    expect(await app.deliverAlert(event.id, ms(night), now: night), isTrue);
  });

  test(
      'daily: occurrence advances, snooze adds one alert, deadline never moves',
      () async {
    final t = await app.tasks.create('Take medicine');
    final deadline = DateTime(now.year, now.month, now.day + 5, 23, 59);
    final first = (await app.tasks
        .setDaily(t.id, 8 * 60 + 46, deadline: deadline, now: now))!;
    final r = (await app.reminders.forTask(t.id)).single;
    expect(await app.deliverAlert(r.id, ms(first), now: first), isTrue);
    expect((await mainChat()).single.kind, 'daily');
    final moved = (await app.reminders.get(r.id))!;
    expect(moved.triggerAt,
        DateTime(first.year, first.month, first.day + 1, 8, 46));
    expect(moved.enabled, isTrue, reason: 'same row, same notification id');

    expect(await app.act('snooze', t.id, r.id, now: first), isTrue);
    final after = (await app.tasks.get(t.id))!;
    expect(after.deadlineAt, deadline);
    expect(after.dueAt, moved.triggerAt,
        reason: 'snooze does not move the task');
    final alerts = await app.reminders.forTask(t.id);
    expect(alerts.map((a) => a.triggerAt),
        contains(first.add(const Duration(minutes: 10))));
    expect(await app.deliverAlert(r.id, ms(first), now: first), isFalse);
  });

  test('done action checks task identity; a meeting asks its outcome',
      () async {
    final follow = tomorrow3pm.add(const Duration(hours: 1));
    final rs = await plan('Client sync', tomorrow3pm,
        [(kind: 'reminder', at: tomorrow3pm), (kind: 'follow_up', at: follow)]);
    final other = await app.tasks.create('Unrelated');
    final r = rs.first;
    expect(await app.act('done', other.id, r.id), isFalse,
        reason: 'reminder belongs to another task');
    expect((await app.tasks.get(other.id))!.done, isFalse);
    expect(await app.act('done', r.taskId!, r.id), isTrue);
    final t = (await app.tasks.get(r.taskId!))!;
    expect(t.done, isTrue);
    expect(t.awaiting, TaskRepo.outcomeQuestion);
    expect((await mainChat()).single.content, contains('How did it go'));
    expect(await app.act('done', r.taskId!, r.id), isFalse,
        reason: 'already done');
    expect(await app.reminders.forTask(r.taskId!), isEmpty,
        reason: 'follow-up cancelled');
  });

  test('refused notification keeps the saved message and is not retried',
      () async {
    native.refuse = true;
    final r = (await plan(
            'Pay rent', tomorrow3pm, [(kind: 'reminder', at: tomorrow3pm)]))
        .single;
    expect(await app.deliverAlert(r.id, ms(tomorrow3pm), now: tomorrow3pm),
        isTrue);
    expect(await mainChat(), hasLength(1));
  });

  test(
      'evening review: one combined message, ignored items return, dates untouched',
      () async {
    await app.preferences.save(const ReminderPreferences(
        followUp: true, quietStart: 1320, quietEnd: 420));
    final yesterday10 = today.subtract(const Duration(hours: 14));
    final bank = await app.tasks.create('Call bank', due: yesterday10);
    final meeting = await app.tasks
        .create('Team meeting', due: today.add(const Duration(hours: 11)));
    await app.tasks.complete(meeting.id);
    final client = await app.tasks
        .create('Client meeting', due: today.add(const Duration(hours: 13)));
    await app.tasks.complete(client.id);
    await app.tasks.setOutcome(client.id, 'they signed');
    final milk = await app.tasks
        .create('Buy milk', due: today.add(const Duration(hours: 9)));
    await app.tasks.complete(milk.id);
    await app.tasks
        .create('Dentist', due: today.add(const Duration(days: 1, hours: 9)));

    final evening = today.add(const Duration(hours: 21, minutes: 30));
    expect(await app.deliverReview(now: today.add(const Duration(hours: 20))),
        isFalse,
        reason: 'not before 21:30');
    expect(await app.deliverReview(now: evening), isTrue);
    expect(
        await app.deliverReview(now: evening.add(const Duration(minutes: 5))),
        isFalse);
    final m = (await mainChat()).single;
    expect(m.kind, 'review');
    expect(
        m.content,
        allOf(contains('Call bank'), contains('Dentist'), contains('Buy milk'),
            contains('How did Team meeting go?'), contains('they signed')));
    expect(m.content, isNot(contains('How did Client meeting go?')),
        reason: 'an outcome already discussed is not asked again');
    expect(native.notices.single.id, reviewNotificationId);
    expect(native.notices.single.target, 'chat:main');

    final next = evening.add(const Duration(days: 1));
    expect(await app.deliverReview(now: next), isTrue);
    expect((await mainChat()).last.content, contains('Call bank'));
    expect(
        (await mainChat()).last.content, contains('since an earlier check-in'),
        reason: 'ignored items come back');
    expect((await app.tasks.get(bank.id))!.dueAt, yesterday10,
        reason: 'never rescheduled');
  });

  test('switches: follow-ups gate the review, nudges are independent',
      () async {
    final evening = today.add(const Duration(hours: 21, minutes: 30));
    await app.tasks
        .create('Call bank', due: today.subtract(const Duration(hours: 3)));
    await app.preferences.save(const ReminderPreferences(
        multiple: true, quietStart: 1320, quietEnd: 420));
    expect(native.reviews.last, isNull,
        reason: 'follow-ups off: no review alarm');
    expect(await app.deliverReview(now: evening), isFalse);

    final pre = tomorrow3pm.subtract(const Duration(minutes: 30));
    final rs = await app.reminders.createPlan('Talk', tomorrow3pm,
        [(kind: 'pre', at: pre), (kind: 'reminder', at: tomorrow3pm)],
        intent: (lead: const [30], follow: null));
    expect(await app.deliverAlert(rs.first.id, ms(pre), now: pre), isTrue,
        reason: 'nudges deliver with follow-ups off');

    await app.preferences.save(const ReminderPreferences(
        followUp: true, quietStart: 1320, quietEnd: 420));
    final armed = native.reviews.last!;
    expect((armed.hour, armed.minute), (21, 30));
    final left = await app.reminders.forTask(rs.first.taskId!);
    expect(left.map((r) => r.kind), ['reminder'],
        reason: 'turning nudges off cancels pending ones');
    final intent =
        AlertIntentJson.decode(await app.reminders.planOf(rs.first.taskId!));
    expect(intent!.lead, isEmpty,
        reason: 'a later move does not bring them back');
  });

  test('catch-up files the latest missed check-in per task, silently, no flood',
      () async {
    final h2 = now.subtract(const Duration(hours: 2));
    await plan('Missed call', h2.add(const Duration(minutes: 30)), [
      (kind: 'reminder', at: h2.subtract(const Duration(hours: 1))),
      (kind: 'reminder', at: h2),
    ]);
    await plan('Ancient', now.subtract(const Duration(hours: 20)),
        [(kind: 'reminder', at: now.subtract(const Duration(hours: 20)))]);
    await plan('Just now', now.subtract(const Duration(minutes: 5)),
        [(kind: 'reminder', at: now.subtract(const Duration(minutes: 5)))]);
    await app.catchUp(now: now);
    await app.catchUp(now: now);
    final msgs = await mainChat();
    expect(msgs.map((m) => m.content).toList(), [contains('Missed call')],
        reason:
            '20h old skipped; 5 min old left to its own alarm; repeat adds nothing');
    expect(native.notices, isEmpty);
  });

  test('notification targets route to Tasks or the main chat', () {
    openTarget('task:7');
    expect(notificationTaps.value, 7);
    openTarget('chat:main');
    expect(chatTaps.value, 'main');
    notificationTaps.value = null;
    chatTaps.value = null;
  });
}
