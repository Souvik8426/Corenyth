import 'package:flutter/services.dart';

import '../data/repos.dart';
import 'tools.dart';

enum PromptKind { action, memory }

class Prompt {
  final PromptKind kind;
  final String user;
  final List<String> memories; // retrieved, already relevant
  final String? tasks; // only when the router decided they are needed
  final List<Message> history;
  Prompt(this.kind, this.user,
      {this.memories = const [], this.tasks, this.history = const []});

  static const actionSystem = '''You are a concise personal assistant.
Reply with ONE JSON object and nothing else. Never invent task IDs, dates or facts.
Tools: create_task{title,notes?,due?,priority?} edit_task{id,...} complete_task{id} delete_task{id} list_tasks{from?,to?,include_done?}
create_reminder{title,at} edit_reminder{id,title?,at?} cancel_reminder{id} search_memory{query}
Format: {"type":"tool","tool":"<name>","arguments":{...}} or {"type":"respond","text":"<reply>"}
Datetimes are ISO-8601 local (YYYY-MM-DDTHH:MM:SS). priority is 0 low, 1 normal, 2 high.
Only use a tool when the user asks for that action. Greetings, questions and chat get "respond".''';

  /// Few-shot turns (dates relative to [now]) so a 0.6B model sees when NOT to call a tool.
  static List<Message> examples(DateTime now) {
    final t = DateTime(now.year, now.month, now.day + 1, 8).toIso8601String().substring(0, 19);
    return [
      Message('user', 'hello'),
      Message('assistant', '{"type":"respond","text":"Hi! How can I help?"}'),
      Message('user', 'add task buy milk'),
      Message('assistant', '{"type":"tool","tool":"create_task","arguments":{"title":"buy milk"}}'),
      Message('user', 'remind me tomorrow at 8 to call mom'),
      Message('assistant', '{"type":"tool","tool":"create_reminder","arguments":{"title":"call mom","at":"$t"}}'),
    ];
  }

  static const memoryGrammar = r'root ::= "{\"remember\":false}" | "{\"remember\":true,\"memory\":" str '
      r'",\"category\":" ("\"preference\"" | "\"fact\"" | "\"person\"") "}"'
      '\n$jsonStrRule';

  static const memorySystem ='''Extract one durable fact or preference about the user from their message, if any.
Reply with ONE JSON object: {"remember":true,"memory":"User ...","category":"preference|fact|person"} or {"remember":false}.''';

  /// Plain prompt text (ChatML for Qwen3). Thinking is off: /no_think plus a pre-filled
  /// empty think block, so generation starts directly at the JSON object.
  String render({DateTime? now}) {
    final b = StringBuffer('<|im_start|>system\n')
      ..writeln(kind == PromptKind.action ? actionSystem : memorySystem);
    if (kind == PromptKind.action) {
      b.writeln('Now: ${(now ?? DateTime.now()).toIso8601String().substring(0, 19)}');
      if (memories.isNotEmpty) b.writeln('Relevant memories:\n- ${memories.join('\n- ')}');
      if (tasks != null) b.writeln('Tasks:\n$tasks');
    }
    b.write('<|im_end|>\n');
    final shots = kind == PromptKind.action ? examples(now ?? DateTime.now()) : const <Message>[];
    for (final m in [...shots, ...history]) {
      b.write('<|im_start|>${m.role}\n${m.content}<|im_end|>\n');
    }
    b.write('<|im_start|>user\n$user /no_think<|im_end|>\n'
        '<|im_start|>assistant\n<think>\n\n</think>\n\n');
    return b.toString();
  }
}

/// Anything that turns a [Prompt] into raw text (ideally one JSON object).
abstract class LlmEngine {
  String get name;

  /// Returns false if the engine cannot run (missing model / native lib).
  Future<bool> load();
  Future<String> complete(Prompt p);
  Future<void> unload();
}

/// Bridge to the native llama.cpp worker (android/.../LlamaBridge.kt + cpp/llama_jni.cpp):
///   assistant/llm: load{path,contextSize}->bool, generate{prompt,maxTokens}->String,
///   cancel, unload
class LlamaChannelEngine implements LlmEngine {
  static const _ch = MethodChannel('assistant/llm');
  final String modelPath;
  final int contextSize;
  LlamaChannelEngine(this.modelPath, {this.contextSize = 2048});

  @override
  String get name => 'llama.cpp';

  @override
  Future<bool> load() async {
    try {
      return await _ch.invokeMethod<bool>(
              'load', {'path': modelPath, 'contextSize': contextSize}) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<String> complete(Prompt p) async =>
      await _ch.invokeMethod<String>('generate', {
        'prompt': p.render(),
        'maxTokens': p.kind == PromptKind.action ? 160 : 80,
        'grammar': p.kind == PromptKind.action ? toolGrammar : Prompt.memoryGrammar,
      }) ??
      '';

  @override
  Future<void> unload() async {
    try {
      await _ch.invokeMethod('unload');
    } on MissingPluginException {
      // nothing loaded
    } on PlatformException {
      // unload is best-effort; close() must not fail on it
    }
  }
}
