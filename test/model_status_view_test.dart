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

  testWidgets('shows selected vs active and unmeasured disclaimer', (t) async {
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
            body: ModelStatusView(
                modelState: ModelState.ready,
                load: ModelLoad.loaded,
                selectedLabel: model17b.label,
                activeLabel: model06b.label,
                fellBack: true,
                onTap: () {}))));
    expect(find.text('Loaded · ${model06b.label}'), findsOneWidget);
    expect(
        find.text(
            'Fell back from selected model. RAM/latency not measured on this device.'),
        findsOneWidget);
    expect(find.text('Details'), findsOneWidget);
  });
  testWidgets('narrow display distinguishes resident model from last answer',
      (t) async {
    t.view.physicalSize = const Size(320, 740);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(
            body: ModelStatusView(
                modelState: ModelState.ready,
                load: ModelLoad.loaded,
                activeLabel: model06b.label,
                lastAnswerSource: 'Built-in assistant logic',
                onTap: () {}))));
    expect(find.text('Last answer: Built-in assistant logic'), findsOneWidget);
    expect(find.text('Loaded · ${model06b.label}'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
