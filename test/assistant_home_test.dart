import 'package:assistant/data/repos.dart';
import 'package:assistant/main.dart';
import 'package:assistant/services/app_services.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:assistant/ui/chat_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/v2_db.dart';

/// Real AssistantHome + ChatPage + sessions on a real (FFI) SQLite database,
/// with rules as the engine (no model file at the path).
void main() {
  late AppServices services;
  const native = MethodChannel('assistant/native');

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 15; i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await t.pump(const Duration(milliseconds: 50));
    }
  }

  Finder inSidebar(String text) =>
      find.descendant(of: find.byType(ChatSidebar), matching: find.text(text));

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            native,
            (call) async => call.method == 'modelsDir'
                ? {'path': '/nonexistent', 'granted': true}
                : null);
  });
  tearDown(() => TestDefaultBinaryMessengerBinding
      .instance.defaultBinaryMessenger
      .setMockMethodCallHandler(native, null));

  testWidgets('initial chat, send, new chat, switch with history, delete',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900); // persistent sidebar
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      services = AppServices(
          await openMigratedV2(), NoopScheduler(), '/nonexistent/model.gguf');
    });
    final convs = services.conversations;
    Future<int> chatCount() async =>
        (await tester.runAsync(convs.listChats))!.length;

    await tester.pumpWidget(MaterialApp(home: AssistantHome(services)));
    await settle(tester);
    // (initial) the stable main chat is the default, listed immediately
    const main = ConversationRepo.mainChatId;
    expect((await tester.runAsync(convs.listChats))!.single.id, main);
    expect(inSidebar('Main chat'), findsOneWidget);

    await tester.enterText(
        find.byKey(const ValueKey('chat-composer')), 'add task Buy milk');
    await tester.pump();
    await tester.tap(find.byTooltip('Send message'));
    await settle(tester);
    expect(find.text('Added task Buy milk.'), findsOneWidget);

    // new chat: empty conversation, both listed
    await tester.tap(find.widgetWithText(FilledButton, 'New chat'));
    await settle(tester);
    expect(await chatCount(), 2);
    expect(find.text('Added task Buy milk.'), findsNothing);

    // reopen the main chat: its history is loaded
    await tester.tap(inSidebar('Main chat'));
    await settle(tester);
    expect(find.text('Added task Buy milk.'), findsOneWidget);

    // delete the other chat, with confirmation; cancel first changes nothing
    final other = (await tester.runAsync(convs.listChats))!
        .firstWhere((c) => c.id != main);
    await tester.tap(find.byKey(ValueKey('delete-${other.id}')));
    await settle(tester);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(await chatCount(), 2);
    await tester.tap(find.byKey(ValueKey('delete-${other.id}')));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);
    expect(await chatCount(), 1);
    expect(find.text('Added task Buy milk.'), findsOneWidget,
        reason: 'main chat still open');

    // a check-in written in the background appears in the open main chat
    await tester.runAsync(() => convs.addProactive(
        'alert:test', 'Heads-up: standup starts at 3:00 PM.',
        kind: 'nudge'));
    services.proactiveChanged.value++;
    await settle(tester);
    expect(find.textContaining('Heads-up: standup'), findsOneWidget);

    // deleting the main chat clears its history; it comes back empty
    await tester.tap(find.byKey(const ValueKey('delete-$main')));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await settle(tester);
    expect((await tester.runAsync(convs.listChats))!.single.id, main);
    expect(find.text('Added task Buy milk.'), findsNothing);
    expect(find.byKey(const ValueKey('delete-$main')), findsOneWidget);

    // tasks survive chat deletion
    expect(
        (await tester.runAsync(services.tasks.list))!.single.title, 'Buy milk');

    // selecting the already-open chat from the Tasks tab goes back to Chat
    await tester.tap(find.descendant(
        of: find.byType(NavigationRail), matching: find.text('Tasks')));
    await settle(tester);
    expect(find.byKey(const ValueKey('chat-composer')), findsNothing);
    await tester.tap(find.byKey(ValueKey('chat-$main')));
    await settle(tester);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);

    // a tapped review/check-in notification opens the main chat from Tasks
    await tester.tap(find.descendant(
        of: find.byType(NavigationRail), matching: find.text('Tasks')));
    await settle(tester);
    expect(find.byKey(const ValueKey('chat-composer')), findsNothing);
    chatTaps.value = main;
    await settle(tester);
    expect(find.byKey(const ValueKey('chat-composer')), findsOneWidget);
    expect(chatTaps.value, isNull, reason: 'consumed once');

    await tester.pumpWidget(const SizedBox()); // dispose: closes the session
    await settle(tester);
  });
}
