import 'dart:async';

import 'package:assistant/main.dart';
import 'package:assistant/services/app_services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('startup paints while services have not finished opening',
      (tester) async {
    final opening = Completer<AppServices>();
    await tester.pumpWidget(
        MaterialApp(home: ServiceStartup(open: () => opening.future)));
    expect(find.text('Opening Corenyth…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 31)); // let the startup timeout run out
  });

  testWidgets('a startup that never finishes ends on Retry, not a spinner',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: ServiceStartup(
      open: () => Completer<AppServices>().future,
      timeout: const Duration(seconds: 2),
    )));
    expect(find.text('Opening Corenyth…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Could not open Corenyth. Your saved data is kept.'),
        findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('startup failure is visible and Retry starts a new attempt',
      (tester) async {
    final first = Completer<AppServices>();
    final retry = Completer<AppServices>();
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
        home: ServiceStartup(
      open: () => ++attempts == 1 ? first.future : retry.future,
    )));
    first.completeError(StateError('database unavailable'));
    await tester.pump();
    expect(find.text('Could not open Corenyth. Your saved data is kept.'),
        findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(attempts, 2);
    expect(find.text('Opening Corenyth…'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 31)); // let the startup timeout run out
  });
}
