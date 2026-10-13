import 'package:assistant/data/repos.dart';
import 'package:assistant/theme/app_theme.dart';
import 'package:assistant/ui/chat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('chat composer sends typed text and preserves readable messages',
      (t) async {
    final input = TextEditingController();
    final scroll = ScrollController();
    addTearDown(input.dispose);
    addTearDown(scroll.dispose);
    var sent = 0;
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
            body: ChatView(
          name: 'Ari',
          messages: [
            Message('user', 'List my tasks'),
            Message('assistant', 'No tasks.')
          ],
          input: input,
          scroll: scroll,
          busy: false,
          ready: true,
          onSend: () => sent++,
        ))));
    expect(find.text('List my tasks'), findsOneWidget);
    expect(find.text('No tasks.'), findsOneWidget);
    expect(find.text('> List my tasks'), findsNothing);
    await t.enterText(find.byType(TextField), 'Add task buy milk');
    await t.pump();
    await t.tap(find.byTooltip('Send message'));
    expect(sent, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('empty chat offers prompts and disabled send while thinking',
      (t) async {
    final input = TextEditingController();
    final scroll = ScrollController();
    addTearDown(input.dispose);
    addTearDown(scroll.dispose);
    var sent = 0;
    Widget view(bool busy) => MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
            body: ChatView(
                name: 'Ari',
                messages: const [],
                input: input,
                scroll: scroll,
                busy: busy,
                ready: true,
                onSend: () => sent++)));
    await t.pumpWidget(view(false));
    await t.tap(find.text('What tasks do I have?'));
    expect(input.text, 'What tasks do I have?');
    expect(sent, 1);
    await t.pumpWidget(view(true));
    await t.pump();
    await t.tap(find.byTooltip('Send message'));
    expect(sent, 1);
    expect(find.text('Corenyth is thinking…'), findsOneWidget);
  });

  testWidgets(
      'composer stays below scrolling content at narrow width and large text',
      (t) async {
    t.view.physicalSize = const Size(320, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final input = TextEditingController();
    final scroll = ScrollController();
    addTearDown(input.dispose);
    addTearDown(scroll.dispose);
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!),
        home: Scaffold(
            body: ChatView(
                name: 'Ari',
                messages: const [],
                input: input,
                scroll: scroll,
                busy: false,
                ready: true,
                onSend: () {}))));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await t.enterText(find.byType(TextField),
        'A long message\nwith multiple lines\nand another line.');
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(t.getRect(find.byType(TextField)).bottom, lessThanOrEqualTo(640));
  });
}
