import 'dart:convert';

import 'package:assistant/assistant/engine.dart';
import 'package:assistant/assistant/rule_engine.dart';
import 'package:assistant/assistant/session.dart';
import 'package:assistant/assistant/tools.dart';
import 'package:assistant/services/reminder_scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'backend_test.dart'
    show FakeTasks, FakeReminders, FakeMemory, FakeProfile, FakeConversations;
import 'screenshot_replies_test.dart' show ScriptedEngine;

/// P0 instrumentation: every turn names its route, fallback code, prompt
/// version and the build/model identity, without any message text.
void main() {
  final now = DateTime(2026, 10, 19, 7, 41);

  Future<AssistantSession> open(LlmEngine engine,
      {Map<String, String> Function()? identity,
      Interpreter? interpreter}) async {
    final tasks = FakeTasks();
    final memory = FakeMemory();
    final s = AssistantSession(
      engine: engine,
      tools: ToolExecutor(tasks, FakeReminders(), memory, NoopScheduler(),
          clock: () => now),
      memory: memory,
      profile: FakeProfile(),
      taskRepo: tasks,
      conversations: FakeConversations(),
      clock: () => now,
      modelDiagnostics: identity,
      interpreter: interpreter,
    );
    await s.start();
    addTearDown(s.close);
    return s;
  }

  test('prompt fingerprint is stable 12-hex for both plan-v1 and plan-v2', () {
    expect(promptFingerprint, matches(RegExp(r'^[0-9a-f]{12}$')));
    expect(promptFingerprintV2, matches(RegExp(r'^[0-9a-f]{12}$')));
    expect(promptContractVersion, 'plan-v1');
    expect(planContractV2, 'plan-v2');
  });

  test('semantic route records prompt version and model identity for legacy (plan-v1)', () async {
    final model = ScriptedEngine();
    model.outputs[PromptKind.plan] =
        jsonEncode({'intent': 'create_task', 'title': 'buy milk'});
    final s = await open(model,
        identity: () => {'build': 'abc1234', 'selected': 'qwen3-1.7b'},
        interpreter: Interpreter.legacy);
    await s.handle('I need to buy milk');
    final d = s.lastDiagnostics;
    expect(d['route'], 'semantic');
    expect(d['model'], 'called');
    expect(d['prompt'], '$promptContractVersion:$promptFingerprint');
    expect(d['build'], 'abc1234');
    expect(d['selected'], 'qwen3-1.7b');
    expect(d.values.join(' '), isNot(contains('milk')),
        reason: 'no message text in diagnostics');
  });

  test('semantic route records prompt version and model identity for unified (plan-v2)', () async {
    final model = ScriptedEngine();
    model.outputs[PromptKind.plan] =
        jsonEncode({'intent': 'create_task', 'title': 'buy milk'});
    final s = await open(model,
        identity: () => {'build': 'abc1234', 'selected': 'qwen3-1.7b'},
        interpreter: Interpreter.unified);
    await s.handle('I need to buy milk');
    final d = s.lastDiagnostics;
    expect(d['route'], 'semantic');
    expect(d['model'], 'called');
    expect(d['prompt'], '$planContractV2:$promptFingerprintV2');
    expect(d['build'], 'abc1234');
    expect(d['selected'], 'qwen3-1.7b');
    expect(d.values.join(' '), isNot(contains('milk')),
        reason: 'no message text in diagnostics');
  });

  test('invalid model output falls back with a code', () async {
    final model = ScriptedEngine()..output = 'not json';
    final s = await open(model);
    await s.handle('I need to buy milk');
    expect(s.lastDiagnostics['fallback'], 'invalid_plan');
    expect(s.lastDiagnostics['route'], anyOf('rules', 'rule_plan'));
  });

  test('no model: route is rules and fallback says why', () async {
    final s = await open(RuleEngine(clock: () => now));
    await s.handle('remind me to call mum tomorrow at 5pm');
    expect(s.lastDiagnostics['model'], 'unavailable');
    expect(s.lastDiagnostics['fallback'], 'engine_not_in_use');
    expect(s.lastDiagnostics['route'], 'rules');
  });

  test('a calculation is settled early', () async {
    final s = await open(RuleEngine(clock: () => now));
    await s.handle('90+24-10*89898');
    expect(s.lastDiagnostics['route'], 'early');
  });

  test('LlamaChannelEngine records why a load failed', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    const ch = MethodChannel('assistant/llm');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(ch, null));
    final e = LlamaChannelEngine('m');

    messenger.setMockMethodCallHandler(ch, (_) async => false);
    expect(await e.load(), isFalse);
    expect(e.lastLoadError, 'native_false');

    messenger.setMockMethodCallHandler(
        ch, (_) async => throw PlatformException(code: 'llama_unavailable'));
    expect(await e.load(), isFalse);
    expect(e.lastLoadError, 'llama_unavailable');

    messenger.setMockMethodCallHandler(ch, (_) async => true);
    expect(await e.load(), isTrue);
    expect(e.lastLoadError, isNull);
  });
}
