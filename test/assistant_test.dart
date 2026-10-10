import 'dart:convert';
import 'dart:io';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/main.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/services/model_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseToolCall accepts valid and rejects malformed output', () {
    final c = parseToolCall(
        '<think>x</think>```json\n{"type":"tool","tool":"create_task","arguments":{"title":"A {b}","due":"2026-10-09T17:00:00"}}```');
    expect(c.tool, 'create_task');
    expect(c.args['title'], 'A {b}');
    expect(c.args['due'], isA<DateTime>());
    for (final bad in [
      'hello',
      '{"type":"tool","tool":"drop_db","arguments":{}}',
      '{"type":"tool","tool":"complete_task","arguments":{"id":"x"}}',
      '{"type":"tool","tool":"create_reminder","arguments":{"title":"a","at":"soon"}}',
      '{"type":"tool","tool":"create_task","arguments":{"title":"a","priority":9}}',
      '{"type":"tool","tool":"delete_task"',
    ]) {
      expect(() => parseToolCall(bad), throwsA(isA<ToolError>()), reason: bad);
    }
  });

  test('rule engine output always passes the validator', () async {
    final e = RuleEngine(clock: () => DateTime(2026, 10, 7, 10));
    Map<String, Object?> plan(String s) => e.plan(s);
    for (final s in [
      'Remind me tomorrow at 8 to bring my laptop.',
      'remind me at 7 to call Mom',
      'remind me in 20 minutes to stretch',
      'add task submit report tomorrow',
      'complete task 3',
      'what tasks do I have today?',
      'what did I tell you about Alex?',
      'hi',
    ]) {
      final c = parseToolCall(jsonEncode(plan(s)));
      expect(c.tool, isNotEmpty, reason: s);
    }
    final r = parseToolCall(jsonEncode(plan('remind me tomorrow at 8 to bring my laptop')));
    expect(r.args['at'], DateTime(2026, 10, 8, 8));
    expect(r.args['title'], 'bring my laptop');
  });

  test('checkModel: access, missing, unfinished, complete', () {
    final dir = Directory.systemTemp.createTempSync('localmodels');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/m.gguf';
    ModelState st({bool granted = true}) => checkModel(path, granted: granted, expectedBytes: 4);
    expect(st(granted: false), ModelState.noAccess);
    expect(st(), ModelState.missing);
    File(path).writeAsBytesSync([1, 2, 3]);
    expect(st(), ModelState.incomplete);
    File(path).writeAsBytesSync([1, 2, 3, 4]);
    expect(st(), ModelState.ready);
  });

  testWidgets('model load dialog: spinner, success, failure + retry', (t) async {
    final load = ValueNotifier(ModelLoad.loading);
    var retried = 0;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: ModelLoadDialog(load, onRetry: () => retried++))));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('OK'), findsNothing);
    load.value = ModelLoad.loaded;
    await t.pump();
    expect(find.text('Model loaded successfully'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    load.value = ModelLoad.failed;
    await t.pump();
    await t.tap(find.text('Retry'));
    expect(retried, 1);
  });

  test('grammar covers every tool; few-shot examples and prompt are valid', () {
    for (final t in toolSchemas.keys.where((t) => t != 'respond')) {
      expect(toolGrammar, contains('tool-${t.replaceAll('_', '-')} ::='), reason: t);
    }
    for (final g in [toolGrammar, Prompt.memoryGrammar]) {
      expect(g.codeUnits.where((c) => c < 0x20 && c != 0x0A), isEmpty);
    }
    final now = DateTime(2026, 10, 10, 11);
    for (final m in Prompt.examples(now).where((m) => m.role == 'assistant')) {
      parseToolCall(m.content); // throws if an example would fail validation
    }
    final r = Prompt(PromptKind.action, 'hi').render(now: now);
    expect(r, endsWith('<|im_start|>assistant\n<think>\n\n</think>\n\n'));
    expect(r, contains('2026-10-11T08:00:00'));
    final c = parseToolCall(
        '{"type":"tool","tool":"create_task","arguments":{"title":"a","priority":"high"}}');
    expect(c.args['priority'], 2);
  });
}
