import 'package:assistant/data/repos.dart';
import 'package:assistant/theme/app_theme.dart';
import 'package:assistant/ui/assistant_message.dart';
import 'package:assistant/ui/chat_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _md = '''
## Today

Here is **bold** and `inline` code with a [docs link](https://example.com/a) and [bad](javascript:alert(1)).

- first item
- second item

> a quiet quote

| Task | When | Notes |
| --- | --- | --- |
| Buy oat milk from the corner shop | tomorrow morning before work | remember the reusable bag please |

```dart
final veryLongLineThatShouldScrollHorizontallyInsteadOfOverflowing = List.generate(100, (i) => i * i);
```

![remote cat](https://example.com/cat.png)
''';

List<InlineSpan> _spans(WidgetTester t) => [
      for (final w in t.widgetList<RichText>(find.byType(RichText))) w.text,
      for (final w in t.widgetList<SelectableText>(find.byType(SelectableText)))
        w.textSpan ?? TextSpan(text: w.data),
    ];

String _allText(WidgetTester t) =>
    _spans(t).map((s) => s.toPlainText()).join('\n');

Future<void> _pumpChat(WidgetTester t, List<Message> messages,
    {String? streaming}) async {
  final input = TextEditingController();
  final scroll = ScrollController();
  addTearDown(input.dispose);
  addTearDown(scroll.dispose);
  await t.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(
          body: ChatView(
              name: 'Ari',
              messages: messages,
              input: input,
              scroll: scroll,
              busy: streaming != null,
              ready: true,
              onSend: () {},
              onStop: () {},
              streamingText: streaming))));
  await t.pump();
}

void main() {
  testWidgets('assistant markdown is styled, user markdown stays literal',
      (t) async {
    await _pumpChat(t, [
      Message('user', '**not bold** and - [x](y)'),
      Message('assistant', _md),
    ]);
    final text = _allText(t);
    expect(text, contains('**not bold** and - [x](y)'));
    expect(text, contains('Today'));
    expect(text, isNot(contains('## Today')));
    expect(text, isNot(contains('**bold**')));
    expect(text, isNot(contains('- first item')));
    expect(text, contains('first item'));
    expect(text, contains('Image: remote cat'));
    expect(find.byType(Table), findsOneWidget);
    // Markdown images never become Image widgets (the imageBuilder shows
    // a label); the bubble's own branding asset is the only Image.
    expect(
        find.byWidgetPredicate((w) =>
            w is Image &&
            !(w.image is AssetImage &&
                (w.image as AssetImage).assetName.endsWith('corenyth-logo-dark.png'))),
        findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('narrow phone: tables and code scroll, no overflow',
      (t) async {
    t.view.physicalSize = const Size(320, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await _pumpChat(t, [Message('assistant', _md)]);
    expect(t.takeException(), isNull);
    expect(
        find.byWidgetPredicate((w) =>
            w is SingleChildScrollView &&
            w.scrollDirection == Axis.horizontal),
        findsNWidgets(2));
  });

  testWidgets('partial streaming markdown renders without errors',
      (t) async {
    const chunks = ['**bo', '**bold** | a |\n| -', '```\nunclosed code', '- li'];
    for (final c in chunks) {
      await _pumpChat(t, [Message('user', 'hi')], streaming: c);
      expect(t.takeException(), isNull);
      expect(find.text('Stop'), findsOneWidget);
    }
  });

  const channel = MethodChannel('assistant/native');

  Future<List<MethodCall>> tapAllLinks(WidgetTester t, String md,
      {bool fail = false}) async {
    final calls = <MethodCall>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call);
      if (fail) throw PlatformException(code: 'no_browser');
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(body: AssistantMessage(md))));
    // Fire the link recognizers directly; selectable text gesture plumbing
    // isn't simulated in widget tests.
    for (final r in _spans(t)) {
      r.visitChildren((s) {
        if (s is TextSpan && s.recognizer is TapGestureRecognizer) {
          (s.recognizer as TapGestureRecognizer).onTap?.call();
        }
        return true;
      });
    }
    await t.pumpAndSettle();
    return calls;
  }

  testWidgets('https link invokes openExternalLink', (t) async {
    final calls = await tapAllLinks(t, '[ok](https://example.com/a)');
    expect(calls.map((c) => '${c.method} ${c.arguments}'),
        ['openExternalLink https://example.com/a']);
    expect(find.text('Could not open link'), findsNothing);
  });

  testWidgets('unsafe links never reach the platform', (t) async {
    final calls = await tapAllLinks(
        t,
        '[a](javascript:alert(1)) [b](file:///etc/passwd) [c](intent://x) '
        '[d](content://x) [e](myapp://x) [f](http://example.com) [g](https://)');
    expect(calls, isEmpty);
  });

  testWidgets('platform failure shows a snackbar', (t) async {
    final calls =
        await tapAllLinks(t, '[ok](https://example.com)', fail: true);
    expect(calls, hasLength(1));
    expect(find.text('Could not open link'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('images show neutral alt label, never the source', (t) async {
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
            body: AssistantMessage(
                '![](data:image/png;base64,${'A' * 5000}) ![a cat](https://x.y/c.png)'))));
    final text = _allText(t);
    expect(text, contains('Image: a cat'));
    expect(text, isNot(contains('base64')));
    expect(text, isNot(contains('x.y')));
    // Markdown images never become Image widgets (the imageBuilder shows
    // a label); the bubble's own branding asset is the only Image.
    expect(
        find.byWidgetPredicate((w) =>
            w is Image &&
            !(w.image is AssetImage &&
                (w.image as AssetImage).assetName.endsWith('corenyth-logo-dark.png'))),
        findsNothing);
  });
}
