import 'package:assistant/data/repos.dart';
import 'package:assistant/ui/chat_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
