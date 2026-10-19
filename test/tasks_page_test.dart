import 'dart:async';

import 'package:assistant/data/repos.dart';
import 'package:assistant/theme/app_theme.dart';
import 'package:assistant/ui/tasks_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';

class _UnusedDatabase implements Database {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Tests must not access the database');
}

class _TaskRepo extends TaskRepo {
  _TaskRepo([List<Map<String, Object?>>? seed]) : super(_UnusedDatabase()) {
    for (final row in seed ?? <Map<String, Object?>>[]) {
      rows[row['id'] as int] = Map.of(row);
    }
  }

  final rows = <int, Map<String, Object?>>{};
  int reads = 0;
  int writes = 0;
  bool failRead = false;
  bool failWrite = false;
  bool missingWrite = false;
  Completer<void>? readGate;
  Completer<void>? writeGate;
  Map<String, Object?>? lastUpdate;

  @override
  Future<List<Task>> list(
      {DateTime? from, DateTime? to, bool includeDone = false}) async {
    reads++;
    await readGate?.future;
    if (failRead) throw StateError('Database unavailable');
    return rows.values
        .map(Task.new)
        .where((t) => includeDone || !t.done)
        .toList();
  }

  Future<void> _beforeWrite() async {
    writes++;
    await writeGate?.future;
    if (failWrite) throw StateError('Write failed');
  }

  @override
  Future<Task> create(String title,
      {String? notes, DateTime? due, int priority = 1, String? opId}) async {
    await _beforeWrite();
    final id = rows.isEmpty ? 1 : rows.keys.reduce((a, b) => a > b ? a : b) + 1;
    final row = _row(id, title, notes: notes, due: due, priority: priority);
    rows[id] = row;
    return Task(row);
  }

  @override
  Future<bool> update(int id, Map<String, Object?> values) async {
    await _beforeWrite();
    lastUpdate = Map.of(values);
    if (missingWrite || !rows.containsKey(id)) return false;
    rows[id]!.addAll(values);
    return true;
  }

  @override
  Future<bool> delete(int id) async {
    await _beforeWrite();
    if (missingWrite) return false;
    return rows.remove(id) != null;
  }
}

Map<String, Object?> _row(int id, String title,
        {bool done = false, String? notes, DateTime? due, int priority = 1}) =>
    {
      'id': id,
      'title': title,
      'notes': notes,
      'status': done ? 'done' : 'pending',
      'due_at': due?.millisecondsSinceEpoch,
      'priority': priority,
      'completed_at': done ? 123 : null,
    };

Future<void> _show(WidgetTester tester, TaskRepo repo,
    {double textScale = 1}) async {
  await tester.pumpWidget(MaterialApp(
    theme: AppTheme.dark,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(
          alwaysUse24HourFormat: true,
          textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Scaffold(body: TasksPage(repo)),
  ));
  await tester.pumpAndSettle();
}

Future<void> _tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final nativeCalls = <String>[];
  setUp(() {
    nativeCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('assistant/native'),
            (call) async {
      nativeCalls.add(call.method);
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('assistant/native'), null);
  });

  testWidgets('notification focus shows the linked completed task first',
      (tester) async {
    final repo = _TaskRepo([
      _row(1, 'Another task'),
      _row(2, 'The linked meeting', done: true),
    ]);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
      body: TasksPage(repo, focusTaskId: 2),
    )));
    await tester.pumpAndSettle();
    expect(find.text('The linked meeting'), findsOneWidget);
    expect(find.text('From reminder'), findsOneWidget);
    expect(find.text('Another task'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loads real task data with counted Active and Completed filters',
      (tester) async {
    final repo = _TaskRepo([
      _row(1, 'Review the research notes',
          notes: 'Check the sources',
          due: DateTime(2026, 10, 12, 15, 30),
          priority: 2),
      _row(2, 'Archive the draft', done: true),
    ]);
    await _show(tester, repo);
    expect(find.text('Tasks'), findsOneWidget);
    expect(find.text('1 task pending'), findsOneWidget);
    expect(find.text('Active (1)'), findsOneWidget);
    expect(find.text('Completed (1)'), findsOneWidget);
    expect(find.text('Review the research notes'), findsOneWidget);
    expect(find.text('Check the sources'), findsOneWidget);
    expect(find.text('High priority'), findsOneWidget);
    expect(find.textContaining('Oct 12, 2026'), findsOneWidget);
    expect(find.text('Archive the draft'), findsNothing);
    await tester.tap(find.text('Completed (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Archive the draft'), findsOneWidget);
    expect(find.text('Review the research notes'), findsNothing);
    expect(repo.reads, 1);
    expect(nativeCalls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loading failures are recoverable and refresh reloads empty data',
      (tester) async {
    final repo = _TaskRepo()
      ..failRead = true
      ..readGate = Completer<void>();
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark, home: Scaffold(body: TasksPage(repo))));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading tasks…'), findsOneWidget);
    repo.readGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t load tasks.'), findsOneWidget);
    repo.failRead = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No active tasks'), findsOneWidget);
    repo.rows[1] = _row(1, 'Added elsewhere');
    await tester.tap(find.byTooltip('Refresh tasks'));
    await tester.pumpAndSettle();
    expect(find.text('Added elsewhere'), findsOneWidget);
    await tester.tap(find.text('Completed (0)'));
    await tester.pumpAndSettle();
    expect(find.text('No completed tasks'), findsOneWidget);
    expect(repo.reads, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refreshToken reloads changed data without resetting the filter',
      (tester) async {
    final repo = _TaskRepo([_row(1, 'Finished', done: true)]);
    Future<void> render(int token, TaskRepo tasks) async {
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(body: TasksPage(tasks, refreshToken: token))));
      await tester.pumpAndSettle();
    }

    await render(0, repo);
    await tester.tap(find.text('Completed (1)'));
    await tester.pumpAndSettle();
    repo.rows[2] = _row(2, 'Finished elsewhere', done: true);
    await render(1, repo);
    expect(find.text('Finished elsewhere'), findsOneWidget);
    expect(find.text('Completed (2)'), findsOneWidget);
    expect(repo.reads, 2);
    await render(1, repo);
    expect(repo.reads, 2);
    final replacement = _TaskRepo([_row(3, 'Replacement', done: true)]);
    await render(1, replacement);
    expect(find.text('Replacement'), findsOneWidget);
    expect(find.text('Finished'), findsNothing);
    expect(replacement.reads, 1);
  });

  testWidgets('completion awaits persistence then supports restoring a task',
      (tester) async {
    final repo = _TaskRepo([_row(1, 'Send the draft')]);
    await _show(tester, repo);
    repo.writeGate = Completer<void>();
    await tester.tap(find.byTooltip('Complete task'));
    await tester.pump();
    expect(repo.rows[1]!['status'], 'pending');
    expect(find.text('Send the draft'), findsOneWidget);
    await tester.tap(find.byTooltip('Complete task'));
    await tester.pump();
    expect(repo.writes, 1);
    expect(nativeCalls, isEmpty);
    repo.writeGate!.complete();
    await tester.pumpAndSettle();
    expect(repo.rows[1]!['status'], 'done');
    expect(find.text('No active tasks'), findsOneWidget);
    expect(find.text('Completed (1)'), findsOneWidget);
    expect(repo.reads, 2);
    expect(nativeCalls, ['refreshWidget']);
    await tester.tap(find.text('Completed (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Restore task'));
    await tester.pumpAndSettle();
    expect(repo.lastUpdate, {'status': 'pending', 'completed_at': null});
    expect(find.text('No completed tasks'), findsOneWidget);
    await tester.tap(find.text('Active (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Send the draft'), findsOneWidget);
    expect(repo.reads, 3);
    expect(nativeCalls, ['refreshWidget', 'refreshWidget']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed mutations retain data and offer a safe retry',
      (tester) async {
    final repo = _TaskRepo([_row(1, 'Keep this task')])..failWrite = true;
    await _show(tester, repo);
    await tester.tap(find.byTooltip('Complete task'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t update task. Try again.'), findsOneWidget);
    expect(find.text('Keep this task'), findsOneWidget);
    expect(nativeCalls, isEmpty);
    repo.failWrite = false;
    await tester.tap(find.text('Retry action'));
    await tester.pumpAndSettle();
    expect(repo.rows[1]!['status'], 'done');
    expect(find.text('Couldn’t update task. Try again.'), findsNothing);
    expect(nativeCalls, ['refreshWidget']);
    await tester.tap(find.text('Completed (1)'));
    await tester.pumpAndSettle();
    repo.missingWrite = true;
    await tester.tap(find.byTooltip('Restore task'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t update task. Try again.'), findsOneWidget);
    expect(find.text('Keep this task'), findsOneWidget);
    expect(repo.rows[1]!['status'], 'done');
    expect(nativeCalls, ['refreshWidget']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('add sheet validates title and awaits the exact saved task',
      (tester) async {
    final repo = _TaskRepo();
    await _show(tester, repo);
    await tester.tap(find.text('Add task'));
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.text('Save task'));
    expect(find.text('Give your task a title.'), findsOneWidget);
    expect(repo.writes, 0);
    await tester.enterText(
        find.byKey(const ValueKey('task-title')), '  Read the paper  ');
    await tester.enterText(
        find.byKey(const ValueKey('task-notes')), '  Compare the results  ');
    await _tapVisible(tester, find.text('High'));
    repo.writeGate = Completer<void>();
    await tester.ensureVisible(find.text('Save task'));
    await tester.tap(find.text('Save task'));
    await tester.pump();
    expect(repo.rows, isEmpty);
    expect(find.text('Saving…'), findsOneWidget);
    expect(nativeCalls, isEmpty);
    repo.writeGate!.complete();
    await tester.pumpAndSettle();
    expect(repo.rows[1]!['title'], 'Read the paper');
    expect(repo.rows[1]!['notes'], 'Compare the results');
    expect(repo.rows[1]!['priority'], 2);
    expect(repo.rows[1]!['due_at'], isNull);
    expect(find.text('Read the paper'), findsOneWidget);
    expect(find.byKey(const ValueKey('task-title')), findsNothing);
    expect(repo.reads, 2);
    expect(nativeCalls, ['refreshWidget']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('widget refresh failure after a saved create offers no retry',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('assistant/native'),
            (call) async => throw PlatformException(code: 'widget_error'));
    final repo = _TaskRepo();
    await _show(tester, repo);
    await tester.tap(find.text('Add task'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('task-title')), 'Only once');
    await _tapVisible(tester, find.text('Save task'));
    expect(repo.rows.length, 1);
    expect(find.byKey(const ValueKey('task-title')), findsNothing,
        reason: 'sheet closed: the write is committed, nothing to retry');
    expect(find.text('Only once'), findsOneWidget);
    await _tapVisible(tester, find.byTooltip('Complete task'));
    expect(find.text('Couldn’t update task. Try again.'), findsNothing);
    expect(repo.rows[1]!['status'], 'done');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'optional due date and time are picked without scheduling reminders',
      (tester) async {
    final repo = _TaskRepo();
    await _show(tester, repo);
    await tester.tap(find.text('Add task'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('task-title')), 'Review on time');
    await _tapVisible(tester, find.text('Set due date'));
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.byTooltip('Switch to input'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(
            of: find.byType(DatePickerDialog),
            matching: find.byType(TextField)),
        '10/14/2026');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.text('Set due time'));
    expect(find.byType(TimePickerDialog), findsOneWidget);
    final fields = find.descendant(
        of: find.byType(TimePickerDialog), matching: find.byType(TextField));
    await tester.enterText(fields.at(0), '17');
    await tester.enterText(fields.at(1), '45');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Oct 14, 2026'), findsOneWidget);
    await _tapVisible(tester, find.text('Save task'));
    expect(repo.rows[1]!['due_at'],
        DateTime(2026, 10, 14, 17, 45).millisecondsSinceEpoch);
    expect(find.textContaining('17:45'), findsOneWidget);
    expect(nativeCalls, ['refreshWidget']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edit sheet preserves data until save and clears optional values',
      (tester) async {
    final due = DateTime(2026, 10, 16, 11, 20);
    final repo = _TaskRepo([
      _row(1, 'Original title',
          notes: 'Original notes', due: due, priority: 2, done: true)
    ]);
    await _show(tester, repo);
    await tester.tap(find.text('Completed (1)'));
    await tester.pumpAndSettle();
    await _tapVisible(tester, find.byTooltip('Edit task'));
    expect(find.text('Edit task'), findsOneWidget);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('task-title')))
            .controller!
            .text,
        'Original title');
    expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('task-notes')))
            .controller!
            .text,
        'Original notes');
    expect(
        find.descendant(
            of: find.byType(Form),
            matching: find.textContaining('Oct 16, 2026')),
        findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('task-title')), 'Discard this change');
    await _tapVisible(tester, find.text('Cancel'));
    expect(repo.writes, 0);
    await _tapVisible(tester, find.byTooltip('Edit task'));
    await tester.enterText(
        find.byKey(const ValueKey('task-title')), '  Revised title  ');
    await tester.enterText(find.byKey(const ValueKey('task-notes')), '  ');
    await _tapVisible(tester, find.text('Remove due date'));
    await _tapVisible(tester, find.text('Low'));
    await _tapVisible(tester, find.text('Save task'));
    expect(repo.lastUpdate, {
      'title': 'Revised title',
      'notes': null,
      'due_at': null,
      'priority': 0
    });
    expect(repo.rows[1]!['status'], 'done');
    expect(find.text('Revised title'), findsOneWidget);
    expect(find.text('Low priority'), findsOneWidget);
    expect(find.text('No due date'), findsOneWidget);
    expect(repo.reads, 2);
    expect(nativeCalls, ['refreshWidget']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('save failure keeps the draft open for retry', (tester) async {
    final repo = _TaskRepo()..failWrite = true;
    await _show(tester, repo);
    await tester.tap(find.text('Add task'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('task-title')), 'Keep my draft');
    await tester.enterText(
        find.byKey(const ValueKey('task-notes')), 'Still here');
    await _tapVisible(tester, find.text('High'));
    await _tapVisible(tester, find.text('Save task'));
    expect(find.text('Couldn’t save task. Try again.'), findsOneWidget);
    expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('task-title')))
            .controller!
            .text,
        'Keep my draft');
    expect(repo.rows, isEmpty);
    expect(nativeCalls, isEmpty);
    repo.failWrite = false;
    await _tapVisible(tester, find.text('Try again'));
    expect(repo.rows[1]!['title'], 'Keep my draft');
    expect(repo.rows[1]!['notes'], 'Still here');
    expect(repo.rows[1]!['priority'], 2);
    expect(find.byKey(const ValueKey('task-title')), findsNothing);
    expect(repo.writes, 2);
    expect(nativeCalls, ['refreshWidget']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('delete requires confirmation and failed delete is retryable',
      (tester) async {
    final repo = _TaskRepo([_row(1, 'Delete only when confirmed')]);
    await _show(tester, repo);
    await _tapVisible(tester, find.byTooltip('Delete task'));
    expect(find.text('Delete task?'), findsOneWidget);
    expect(repo.writes, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.rows, hasLength(1));
    expect(repo.writes, 0);
    await _tapVisible(tester, find.byTooltip('Delete task'));
    repo.failWrite = true;
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn’t update task. Try again.'), findsOneWidget);
    expect(repo.rows, hasLength(1));
    expect(nativeCalls, isEmpty);
    repo.failWrite = false;
    await _tapVisible(tester, find.text('Retry action'));
    expect(repo.rows, isEmpty);
    expect(find.text('No active tasks'), findsOneWidget);
    expect(repo.reads, 2);
    expect(nativeCalls, ['refreshWidget']);
    expect(tester.takeException(), isNull);
  });
}
