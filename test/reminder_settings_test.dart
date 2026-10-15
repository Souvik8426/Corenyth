import 'package:assistant/data/repos.dart';
import 'package:assistant/ui/reminder_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

class _NoDb implements Database {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError();
}

class _FakePrefs extends ReminderPreferencesRepo {
  ReminderPreferences value = const ReminderPreferences();
  bool fail = false;
  _FakePrefs() : super(_NoDb());
  @override
  Future<ReminderPreferences> get() async => value;
  @override
  Future<void> save(ReminderPreferences v) async {
    if (fail) throw Exception('disk');
    value = v.validated();
  }
}

void main() {
  Future<_FakePrefs> pump(WidgetTester tester) async {
    final repo = _FakePrefs();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(child: ReminderSettings(repo)))));
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('off by default; toggles save and reveal options',
      (tester) async {
    final repo = await pump(tester);
    final switches = find.byType(Switch);
    expect(switches, findsNWidgets(3));
    expect(tester.widgetList<Switch>(switches).take(2).map((s) => s.value),
        [false, false]);
    await tester.tap(find.text('Nudge mode'));
    await tester.pumpAndSettle();
    expect(repo.value.multiple, isTrue);
    expect(find.text('30 min before'), findsOneWidget);
    await tester.tap(find.text('5 min before'));
    await tester.pumpAndSettle();
    expect(repo.value.leadMinutes, [30, 10, 5]);
    await tester.tap(find.text('60 min before'));
    await tester.pumpAndSettle();
    expect(find.text('Choose 1 to 3 early alerts.'), findsOneWidget);
    expect(repo.value.leadMinutes, [30, 10, 5]);
    await tester.tap(find.text('Follow-ups'));
    await tester.pumpAndSettle();
    expect(repo.value.followUp, isTrue);
    expect(find.text('Estimated event duration'), findsOneWidget);
    expect(find.textContaining('Unfinished tasks stay'), findsOneWidget);
    if (!repo.value.hasQuietHours) {
      await tester.tap(find.text('Do not disturb'));
      await tester.pumpAndSettle();
    }
    expect((repo.value.quietStart, repo.value.quietEnd), (22 * 60, 7 * 60));
    expect(find.textContaining('still rings'), findsOneWidget);
  });

  testWidgets('failed save is reported and not shown as saved', (tester) async {
    final repo = await pump(tester);
    repo.fail = true;
    await tester.tap(find.text('Follow-ups'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Couldn’t save'), findsOneWidget);
    expect(tester.widgetList<Switch>(find.byType(Switch)).elementAt(1).value,
        isFalse);
  });
}
