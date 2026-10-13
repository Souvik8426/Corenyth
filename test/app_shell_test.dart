import 'package:assistant/theme/app_theme.dart';
import 'package:assistant/ui/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('dock switches screens without discarding their state',
      (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    var profiles = 0;
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: AppShell(
          onProfile: () => profiles++,
          onSettings: () {},
          pages: const [
            _Counter(),
            Text('Task content'),
            Text('Memory content')
          ],
        )));
    await t.tap(find.text('Count 0'));
    await t.pump();
    await t.tap(find.text('Tasks'));
    await t.pumpAndSettle();
    expect(find.text('Task content'), findsOneWidget);
    await t.tap(find.text('Chat'));
    await t.pumpAndSettle();
    expect(find.text('Count 1'), findsOneWidget);
    await t.tap(find.byTooltip('Your profile'));
    expect(profiles, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('narrow dock is accessible and moves away for the keyboard',
      (t) async {
    t.view.physicalSize = const Size(320, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!),
        home: AppShell(onProfile: () {}, onSettings: () {}, pages: const [
          TextField(),
          Text('Task content'),
          Text('Memory content')
        ])));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    t.view.viewInsets = const FakeViewPadding(bottom: 280);
    await t.pumpAndSettle();
    expect(find.text('Tasks'), findsNothing);
    expect(t.takeException(), isNull);
    t.view.resetViewInsets();
  });

  testWidgets('tablet uses a rail instead of stretched mobile navigation',
      (t) async {
    t.view.physicalSize = const Size(1024, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: AppShell(onProfile: () {}, onSettings: () {}, pages: const [
          Text('Chat content'),
          Text('Task content'),
          Text('Memory content')
        ])));
    expect(find.byType(NavigationRail), findsOneWidget);
    await t.tap(find.text('Memories'));
    await t.pumpAndSettle();
    expect(find.text('Memory content'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;
  @override
  Widget build(BuildContext context) => TextButton(
      onPressed: () => setState(() => count++), child: Text('Count $count'));
}
