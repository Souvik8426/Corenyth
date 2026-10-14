import 'dart:convert';

import 'package:flutter/services.dart';

import '../data/repos.dart';
import 'semantic.dart';
import 'tools.dart';

/// action: legacy tool-call prompt (kept for the rules engine contract);
/// plan: the model-first semantic plan (see semantic.dart); memory: fact extraction.
enum PromptKind { action, plan, memory }

/// Breaks ChatML control markers (`<|im_start|>`, `<|im_end|>`, ...) in untrusted text:
/// the native tokenizer parses special tokens, so a literal marker would forge a turn.
String neutralizeChatMl(String s) => s.replaceAll('<|', '<​|');

class Prompt {
  final PromptKind kind;
  final String user;
  final List<String> memories; // retrieved, already relevant
  final String? tasks; // only when the router decided they are needed
  final String? reminders; // likewise, upcoming enabled reminders
  final String personalContext;
  final List<Message> history;

  /// plan only: the open clarification question, if any.
  final String? pending;

  /// plan only: labelled facts from SQLite and the user's own earlier
  /// messages (never assistant replies).
  final String? context;

  /// The app's clock for `Now:` (tests inject it); null = the device clock.
  final DateTime? now;
  Prompt(this.kind, this.user,
      {this.memories = const [],
      this.tasks,
      this.reminders,
      this.personalContext = '',
      this.history = const [],
      this.pending,
      this.context,
      this.now});

  /// Stable (KV-cache friendly). Untrusted text only ever appears in the user turn.
  static const planSystem =
      '''Turn the user's message into ONE JSON plan for an offline task assistant. The app reads and writes the database; you never state facts about the user's tasks.
intent: create_task (something to do) | create_reminder (asks to be reminded/notified) | complete (says something is done) | delete | postpone (move a task later) | list (asks what is planned/pending) | recall (asks what they told you) | answer_pending (only gives the time the Pending question asked for) | cancel_pending | chat (small talk or a general question).
title: the action itself, short, as the user said it, without filler like "too", "also", "pls", "I have to". For recall: what to look up.
ref: for complete/delete/postpone, the #id from Current tasks or the task's words.
when: copy the user's own time words exactly (e.g. "tomo", "morning 8:10", "in 20 min", "by 2h"); never turn them into a date. Omit if none.
range (list only): today | tomorrow | overdue | all.
multiple / follow_up: only if the user asks for extra alerts or a follow-up (true) or refuses them (false).
negated: true if the user says not to, or is only asking or supposing.
reply (chat only): one short friendly sentence; never mention tasks, times or reminders.''';

  /// Stable across turns, so the native KV cache can reuse it (no dates in here).
  static const actionSystem =
      '''You are a capable personal assistant for tasks and reminders. Reply with ONE JSON object only. Never invent task IDs, dates, or facts.
Tools: create_task{title,notes?,due?,priority?} edit_task{id|target_title,title?,notes?,due?,priority?} complete_task{id|title} delete_task{id|title} list_tasks{from?,to?,include_done?}
create_reminder{title,at,multiple?,follow_up?} edit_reminder{id|target_title,title?,at?} cancel_reminder{id|title} list_reminders{} search_memory{query}
Pick by #id from the supplied list or exact title (target_title for edits). If unclear or the list is partial, ask — never guess.
Format: {"type":"tool","tool":"<name>","arguments":{...}} or {"type":"respond","text":"<reply>"}
Datetimes are ISO-8601 local relative to "Now". priority: 0 low, 1 normal, 2 high.
Use a tool only with clear evidence in the request. "remind me what…" / catch-up → list_tasks, never create_reminder. Missing time → ask when (today/tomorrow/tonight, morning=9/afternoon=15/evening=19, "in 20 minutes", 5pm). Arithmetic and casual chat → respond. Do not search memories for general knowledge. multiple/follow_up only when the user asks. Be natural; if you cannot help, say so honestly.''';

  static const memoryGrammar =
      r'root ::= "{\"remember\":false}" | "{\"remember\":true,\"memory\":" str '
      r'",\"category\":" ("\"preference\"" | "\"fact\"" | "\"person\"") "}"'
      '\n$jsonStrRule';

  static const memorySystem =
      '''Extract one durable personal fact or preference explicitly stated by the user, if any. Ignore greetings, casual chat, requests, chores, meetings, reminders, temporary plans, and facts about the assistant or a language model.
Reply with ONE JSON object: {"remember":true,"memory":"User ...","category":"preference|fact|person"} or {"remember":false}.''';

  /// Plain prompt text (ChatML for Qwen3). Layout, most stable first for KV reuse:
  /// system (fixed instructions + personal context), history, then the user turn carrying
  /// the variable parts (Now, memories, tasks). Thinking is off: /no_think plus a
  /// pre-filled empty think block, so generation starts directly at the JSON object.
  String render({DateTime? now}) {
    if (kind == PromptKind.plan) return _renderPlan(now ?? this.now ?? DateTime.now());
    final action = kind == PromptKind.action;
    final b = StringBuffer('<|im_start|>system\n')
      ..write(action ? actionSystem : memorySystem);
    if (action && personalContext.isNotEmpty) {
      b.write('\nPersonal context:\n${neutralizeChatMl(personalContext)}');
    }
    b.write('<|im_end|>\n');
    for (final m in history) {
      // Assistant turns are stored as plain replies; show them in the reply format.
      final c = m.role == 'assistant' && !m.content.trimLeft().startsWith('{')
          ? jsonEncode({'type': 'respond', 'text': m.content})
          : m.content;
      b.write('<|im_start|>${m.role == 'assistant' ? 'assistant' : 'user'}\n'
          '${neutralizeChatMl(c)}<|im_end|>\n');
    }
    b.write('<|im_start|>user\n');
    if (action) {
      b.writeln(
          'Now: ${(now ?? DateTime.now()).toIso8601String().substring(0, 19)}');
      if (memories.isNotEmpty) {
        b.writeln(
            'Relevant memories:\n- ${neutralizeChatMl(memories.join('\n- '))}');
      }
      if (tasks != null) b.writeln('Tasks:\n${neutralizeChatMl(tasks!)}');
      if (reminders != null) {
        b.writeln('Reminders:\n${neutralizeChatMl(reminders!)}');
      }
      b.write('Request: ');
    }
    b.write('${neutralizeChatMl(user)} /no_think<|im_end|>\n'
        '<|im_start|>assistant\n<think>\n\n</think>\n\n');
    return b.toString();
  }

  /// No chat history: old assistant replies (e.g. earlier task lists) must never
  /// reach the model as current facts. Current tasks come fresh from SQLite.
  String _renderPlan(DateTime now) {
    final b = StringBuffer('<|im_start|>system\n$planSystem');
    if (personalContext.isNotEmpty) {
      b.write('\nAbout the user:\n${neutralizeChatMl(personalContext)}');
    }
    b.write('<|im_end|>\n<|im_start|>user\n');
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    b.writeln('Now: ${days[now.weekday - 1]} ${now.toIso8601String().substring(0, 16)}');
    if (pending != null) b.writeln('Pending: ${neutralizeChatMl(pending!)}');
    if (tasks != null) b.writeln('Current tasks:\n${neutralizeChatMl(tasks!)}');
    if (context != null && context!.isNotEmpty) b.writeln(neutralizeChatMl(context!));
    b.write('Message: ${neutralizeChatMl(user)} /no_think<|im_end|>\n'
        '<|im_start|>assistant\n<think>\n\n</think>\n\n');
    return b.toString();
  }

  Prompt _with({List<Message>? history, bool dropOptional = false}) => Prompt(
      kind, user,
      memories: dropOptional ? const [] : memories,
      tasks: tasks,
      reminders: reminders,
      personalContext: dropOptional ? '' : personalContext,
      history: history ?? this.history,
      pending: pending,
      context: context,
      now: now);

  /// Candidate renders from fullest to smallest: drop oldest history first, then
  /// optional context (memories, personal context; tasks answer the request so stay).
  /// The current user text is never cut; if even the last candidate is too long the
  /// native side rejects with `prompt_too_long`.
  List<String> candidates({DateTime? now}) {
    final out = <String>[];
    for (var i = 0; i <= history.length; i++) {
      out.add(_with(history: history.sublist(i)).render(now: now));
    }
    if (memories.isNotEmpty || personalContext.isNotEmpty) {
      out.add(_with(history: const [], dropOptional: true).render(now: now));
    }
    return out;
  }

  /// Candidates worth sending to the native tokenizer for an [nCtx] window: a prompt
  /// never has more tokens than UTF-8 bytes (+1 for a possible BOS), so stop after the
  /// first candidate that provably fits. Usually that is the first one: one tokenization.
  List<String> budgeted(int nCtx, int maxTokens, {DateTime? now}) {
    final all = candidates(now: now);
    final i = all.indexWhere((c) => utf8.encode(c).length + 1 + maxTokens <= nCtx);
    return i < 0 ? all : all.sublist(0, i + 1);
  }
}

/// Anything that turns a [Prompt] into raw text (ideally one JSON object).
/// Implementations with no streaming/cancel should `extends` this to inherit the defaults.
abstract class LlmEngine {
  String get name;

  /// Returns false if the engine cannot run (missing model / native lib).
  Future<bool> load();
  Future<String> complete(Prompt p);
  Future<void> unload();

  /// Like [complete], also reporting cumulative user-visible reply text as it grows.
  Future<String> completeStreaming(Prompt p,
          {void Function(String text)? onText}) =>
      complete(p);

  /// Cancels this engine's in-flight/queued requests; they throw instead of returning.
  Future<void> cancel() async {}
}

/// Cumulative visible text of a (possibly partial) `{"type":"respond","text":"...` reply,
/// or null while it is not (yet) a respond object; tool calls never surface. A trailing
/// partial escape or lone high surrogate is withheld until complete.
String? visibleRespondText(String raw) {
  final m = RegExp(r'^\s*\{\s*"type"\s*:\s*"respond"\s*,\s*"text"\s*:\s*"')
      .firstMatch(raw);
  if (m == null) return null;
  final b = StringBuffer();
  var i = m.end;
  while (i < raw.length) {
    final c = raw[i];
    if (c == '"') break;
    if (c != r'\') {
      b.write(c);
      i++;
      continue;
    }
    if (i + 1 >= raw.length) break;
    final e = raw[i + 1];
    if (e == 'u') {
      if (i + 6 > raw.length) break;
      final cu = int.tryParse(raw.substring(i + 2, i + 6), radix: 16);
      if (cu == null) break;
      if (cu >= 0xD800 && cu < 0xDC00) {
        // high surrogate: emit only together with its low half; wait while it may still come
        final rest = raw.substring(i + 6, i + 12 < raw.length ? i + 12 : null);
        if (rest.length < 6 && r'\u'.startsWith(rest.length < 2 ? rest : rest.substring(0, 2))) break;
        final lo = rest.startsWith(r'\u') ? int.tryParse(rest.substring(2), radix: 16) : null;
        if (lo != null && lo >= 0xDC00 && lo < 0xE000) {
          b.writeCharCode(0x10000 + ((cu - 0xD800) << 10) + (lo - 0xDC00));
          i += 12;
        } else {
          b.writeCharCode(0xFFFD); // unpaired high surrogate
          i += 6;
        }
      } else if (cu >= 0xDC00 && cu < 0xE000) {
        b.writeCharCode(0xFFFD); // lone low surrogate
        i += 6;
      } else {
        b.writeCharCode(cu);
        i += 6;
      }
      continue;
    }
    b.write(const {'n': '\n', 't': '\t', 'r': '\r', 'b': '\b', 'f': '\f'}[e] ?? e);
    i += 2;
  }
  return b.toString();
}

/// Bridge to the native llama.cpp worker (android/.../LlamaBridge.kt + cpp/llama_jni.cpp):
///   assistant/llm: load{path,contextSize}->bool,
///   generate{id,prompts,maxTokens,grammar,stream}->String, cancel{id}, unload.
///   Native -> Dart: text{id,text} with the cumulative raw output while streaming.
/// Error codes: llama_cancelled, prompt_too_long, llama_error, llama_unavailable.
class LlamaChannelEngine extends LlmEngine {
  static const _ch = MethodChannel('assistant/llm');
  static final _listeners = <int, void Function(String raw)>{};
  static var _nextId = 0;
  static var _handlerSet = false;

  final String modelPath;
  final int contextSize;
  final _active = <int>{};
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
  Future<String> complete(Prompt p) => completeStreaming(p);

  @override
  Future<String> completeStreaming(Prompt p,
      {void Function(String text)? onText}) async {
    final id = ++_nextId;
    final maxTokens = switch (p.kind) {
      PromptKind.action => 160,
      PromptKind.plan => 120,
      PromptKind.memory => 80,
    };
    if (onText != null) {
      if (!_handlerSet) {
        _handlerSet = true;
        _ch.setMethodCallHandler((call) async {
          if (call.method != 'text') return;
          final a = call.arguments as Map;
          _listeners[a['id'] as int]?.call(a['text'] as String);
        });
      }
      var last = '';
      _listeners[id] = (raw) {
        final v = visibleRespondText(raw);
        if (v != null && v != last) onText(last = v);
      };
    }
    _active.add(id);
    try {
      return await _ch.invokeMethod<String>('generate', {
            'id': id,
            'prompts': p.budgeted(contextSize, maxTokens),
            'maxTokens': maxTokens,
            'grammar': switch (p.kind) {
              PromptKind.action => toolGrammar,
              PromptKind.plan => semanticGrammar,
              PromptKind.memory => Prompt.memoryGrammar,
            },
            'stream': onText != null,
          }) ??
          '';
    } finally {
      _active.remove(id);
      _listeners.remove(id);
    }
  }

  @override
  Future<void> cancel() async {
    for (final id in _active.toList()) {
      _listeners.remove(id); // no streamed text after stop
      try {
        await _ch.invokeMethod('cancel', {'id': id});
      } on MissingPluginException {
        // nothing running
      } on PlatformException {
        // best-effort
      }
    }
  }

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
