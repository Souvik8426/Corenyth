import 'package:assistant/data/repos.dart';
import 'package:assistant/services/app_services.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:assistant/ui/reminder_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/v2_db.dart';

class _Scheduler extends ReminderScheduler {
  bool fail = true;
  String? issue;
  Duration? tested;
  @override
  Future<void> schedule(Reminder r) async {
    if (fail) throw Exception('exact alarm denied');
  }

  @override
  Future<void> cancel(int id) async {}
  @override
  Future<String?> deliveryIssue() async => issue;
  @override
  Future<DateTime> scheduleTest(Duration delay) async {
    tested = delay;
    return DateTime.now().add(delay);
  }
}

void main() {
  test('failed alarm intents are shown, retried on resume, then cleared', () async {
    final db = await openMigratedV2();
    final sch = _Scheduler();
    final app = AppServices(db, sch, '/m.gguf');
    await app.reminders.create('call Mum', DateTime(2099)); // pending 'schedule'
    expect(await app.syncReminders(), [1]);
    expect(app.reminderIssue.value, contains('#1'));
    sch.fail = false;
    expect(await app.syncReminders(), isEmpty); // next write succeeds
    expect(app.reminderIssue.value, isNull, reason: 'no stale failure after recovery');
    await app.checkReminders(); // app resumed
    expect(app.reminderIssue.value, isNull);
    expect(await app.reminders.pending(), isEmpty);
    sch.issue = 'notifications are turned off for this app';
    await app.checkReminders();
    expect(app.reminderIssue.value, contains('turned off'));
  });

  test('test notification is honest about permissions and delivery', () async {
    final db = await openMigratedV2();
    final sch = _Scheduler()..issue = 'exact alarms are not allowed';
    final app = AppServices(db, sch, '/m.gguf');
    expect(await app.testNotification(), startsWith('Not scheduled'));
    expect(sch.tested, isNull);
    sch.issue = null;
    final ok = await app.testNotification();
    expect(ok, allOf(contains('Android accepted it'), contains('check that it actually appears')));
    expect(sch.tested, const Duration(seconds: 10));
    expect(await AppServices(db, NoopScheduler(), '/m.gguf').testNotification(),
        startsWith("Couldn't"), reason: 'no native alarms: never claims success');
  });

  testWidgets('settings test button shows the result', (t) async {
    final db = await t.runAsync(() => openMigratedV2());
    await t.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
        child: ReminderSettings(ReminderPreferencesRepo(db!),
            onTest: () async => 'Test notification scheduled')))));
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await t.pump();
    await t.tap(find.text('Send a test notification'));
    await t.pump();
    expect(find.text('Test notification scheduled'), findsOneWidget);
  });
}
