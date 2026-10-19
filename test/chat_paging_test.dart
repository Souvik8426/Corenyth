import 'package:assistant/data/repos.dart';
import 'package:assistant/mascot/mascot_emotion.dart';
import 'package:assistant/ui/chat_view.dart';
import 'package:assistant/ui/ghost_mascot.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('exchange paging changes emotion and streaming preserves history',
      (t) async {
    final input = TextEditingController();
    final scroll = ScrollController();
    addTearDown(input.dispose);
    addTearDown(scroll.dispose);
    final messages = [
      Message('user', 'I feel happy'),
      Message('assistant', 'Wonderful!'),
      Message('user', 'I feel sad'),
      Message('assistant', 'I am here.')
    ];
    MascotEmotion? viewed;
    Widget scene({String? stream}) => MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!),
        home: Scaffold(
            body: ChatView(
                name: 'Ari',
                messages: messages,
                input: input,
                scroll: scroll,
                busy: false,
                ready: true,
                streamingText: stream,
                onEmotionChanged: (value) => viewed = value,
                onSend: () {})));
    await t.pumpWidget(scene());
    expect(find.text('Exchange 2 of 2'), findsOneWidget);
    expect(
        t.getSize(find.byKey(const ValueKey('exchange-pager'))).height,
        greaterThan(
            t.getSize(find.byKey(const ValueKey('mascot-stage'))).height * 2));
    expect(t.getSize(find.byKey(const ValueKey('conversation-mascot'))).height,
        closeTo(116, 1));
    await t.tap(find.byTooltip('Previous exchange'));
    await t.pumpAndSettle();
    expect(find.text('Exchange 1 of 2'), findsOneWidget);
    expect(viewed?.mood, MascotMood.happy);
    await t.pumpWidget(scene(stream: 'Another thought'));
    await t.pumpAndSettle();
    expect(find.text('Exchange 1 of 3'), findsOneWidget);
    // New submission returns to the latest exchange, even when browsing history.
    messages.add(Message('user', 'I am worried'));
    await t.pumpWidget(scene());
    await t.pumpAndSettle();
    expect(find.text('Exchange 3 of 3'), findsOneWidget,
        reason: t
            .widgetList<Text>(find.byType(Text))
            .map((w) => w.data)
            .toString());
    expect(t.widget<PageView>(find.byType(PageView)).controller!.page,
        closeTo(2, 0.01));
    expect(viewed?.mood, MascotMood.concerned);
    expect(find.byType(GhostMascot), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets(
      'edge drag snaps to previous exchange and long reply scrolls inside',
      (t) async {
    final input = TextEditingController();
    final scroll = ScrollController();
    addTearDown(input.dispose);
    addTearDown(scroll.dispose);
    await t.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!),
        home: Scaffold(
            body: ChatView(
                name: '',
                messages: [
                  Message('user', 'First'),
                  Message('assistant', 'First reply'),
                  Message('user', 'Second'),
                  Message(
                      'assistant', List.filled(80, 'Long reply.').join('\n')),
                ],
                input: input,
                scroll: scroll,
                busy: false,
                ready: true,
                onSend: () {}))));
    final pager = find.byKey(const ValueKey('exchange-pager'));
    await t.drag(pager, const Offset(0, -70));
    await t.pumpAndSettle();
    expect(find.text('Exchange 2 of 2'), findsOneWidget);
    // Return the nested reply to its top, then overscroll into the earlier turn.
    await t.drag(pager, const Offset(0, 600));
    await t.pumpAndSettle();
    await t.drag(pager, const Offset(0, 110));
    await t.pumpAndSettle();
    expect(find.text('Exchange 1 of 2'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('keyboard layout keeps composer visible with a long draft',
      (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.view.resetViewInsets);
    final input = TextEditingController();
    final scroll = ScrollController();
    addTearDown(input.dispose);
    addTearDown(scroll.dispose);
    await t.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!),
        home: Scaffold(
            body: ChatView(
                name: '',
                messages: [
                  Message('user', 'Hello'),
                  Message('assistant', 'Hi')
                ],
                input: input,
                scroll: scroll,
                busy: false,
                ready: true,
                onSend: () {}))));
    final restingSize =
        t.getSize(find.byKey(const ValueKey('conversation-mascot')));
    t.view.viewInsets = const FakeViewPadding(bottom: 320);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'One\nTwo\nThree');
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    expect(t.getSize(find.byKey(const ValueKey('conversation-mascot'))),
        restingSize);
    expect(t.getRect(find.byType(TextField)).bottom, lessThanOrEqualTo(524));
  });
}
