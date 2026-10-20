import 'package:assistant/data/repos.dart';
import 'package:assistant/ui/chat_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('main chat explains where proactive messages arrive',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: ChatSidebar(
        chats: [ChatSummary(ConversationRepo.mainChatId, '', DateTime(2026))],
        onNewChat: () {},
        onSelect: (_) {},
        onDelete: (_) {},
      )),
    ));
    expect(find.text('Main chat'), findsOneWidget);
    expect(find.text('Daily reviews and check-ins'), findsOneWidget);
    expect(find.textContaining('Chats share context'), findsOneWidget);
  });

  testWidgets('lists chats, untitled as New chat, and routes actions',
      (tester) async {
    final selected = <String>[], deleted = <String>[];
    var created = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ChatSidebar(
      chats: [
        ChatSummary('a', '', DateTime(2026)),
        ChatSummary('b', 'Plan my day', DateTime(2026)),
      ],
      selectedId: 'a',
      onNewChat: () => created++,
      onSelect: selected.add,
      onDelete: (c) => deleted.add(c.id),
    ))));
    expect(find.text('New chat'), findsNWidgets(2)); // button + untitled chat
    await tester.tap(find.text('Plan my day'));
    await tester.tap(find.byKey(const ValueKey('delete-b')));
    await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
    expect(selected, ['b']);
    expect(deleted, ['b']);
    expect(created, 1);
  });

  testWidgets('busy disables actions', (tester) async {
    var created = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ChatSidebar(
      chats: [ChatSummary('a', 'x', DateTime(2026))],
      busy: true,
      onNewChat: () => created++,
      onSelect: (_) => fail('select while busy'),
      onDelete: (_) => fail('delete while busy'),
    ))));
    await tester.tap(find.text('x'));
    await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
    expect(created, 0);
  });

  testWidgets('the widget option shows only when wired and calls back',
      (tester) async {
    var asked = 0;
    Widget sidebar(VoidCallback? onAdd) => MaterialApp(
        home: Scaffold(
            body: ChatSidebar(
          chats: const [],
          onNewChat: () {},
          onSelect: (_) {},
          onDelete: (_) {},
          onAddWidget: onAdd,
        )));
    await tester.pumpWidget(sidebar(null));
    expect(find.text('Add home screen widget'), findsNothing);
    await tester.pumpWidget(sidebar(() => asked++));
    await tester.tap(find.text('Add home screen widget'));
    expect(asked, 1);
  });

  testWidgets('feedback sits above the widget option and calls back',
      (tester) async {
    var sent = 0;
    Widget sidebar(VoidCallback? onFeedback) => MaterialApp(
        home: Scaffold(
            body: ChatSidebar(
          chats: const [],
          onNewChat: () {},
          onSelect: (_) {},
          onDelete: (_) {},
          onFeedback: onFeedback,
          onAddWidget: () {},
        )));
    await tester.pumpWidget(sidebar(null));
    expect(find.text('Send feedback'), findsNothing);
    await tester.pumpWidget(sidebar(() => sent++));
    expect(tester.getTopLeft(find.text('Send feedback')).dy,
        lessThan(tester.getTopLeft(find.text('Add home screen widget')).dy));
    await tester.tap(find.text('Send feedback'));
    expect(sent, 1);
  });
}
