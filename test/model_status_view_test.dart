import 'package:assistant/services/model_status.dart';
import 'package:assistant/theme/app_theme.dart';
import 'package:assistant/ui/model_status_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('missing model is accurately labeled as built-in rules',
      (t) async {
    var taps = 0;
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
            body: ModelStatusView(
                modelState: ModelState.missing,
                load: ModelLoad.idle,
                onTap: () => taps++))));
    expect(find.text('Built-in rules · On device'), findsOneWidget);
    await t.tap(find.text('Set up'));
    expect(taps, 1);
    expect(t.takeException(), isNull);
  });
}
