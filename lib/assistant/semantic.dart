import 'tools.dart';

/// What the model may say about a message: meaning only. It never supplies
/// dates (only the user's own time words), database facts, or prose about
/// tasks. The app validates every field and runs the real SQLite tools.
const semanticIntents = [
  'create_task', // something to do
  'create_reminder', // asked to be reminded/notified
  'complete', // says a task is done
  'delete',
  'postpone',
  'list', // asks what is planned
  'recall', // asks what they told the assistant before
  'answer_pending', // only supplies the time the pending question asked for
  'cancel_pending',
  'chat', // small talk / general question
];
const semanticRanges = ['today', 'tomorrow', 'overdue', 'all'];

class Semantic {
  final String intent;
  final String? title, ref, when, range, reply;
  final bool? multiple, followUp;
  final bool negated;
  const Semantic(this.intent,
      {this.title,
      this.ref,
      this.when,
      this.range,
      this.reply,
      this.multiple,
      this.followUp,
      this.negated = false});
}

/// Fields each intent may carry (besides `intent` and `negated`).
const _fields = {
  'create_task': {'title', 'when'},
  'create_reminder': {'title', 'when', 'multiple', 'follow_up'},
  'complete': {'ref', 'title'},
  'delete': {'ref', 'title'},
  'postpone': {'ref', 'title', 'when'},
  'list': {'range'},
  'recall': {'title'},
  'answer_pending': {'when'},
  'cancel_pending': <String>{},
  'chat': {'reply'},
};

/// Field order is fixed by [semanticGrammar]: intent, title, ref, when, range,
/// multiple, follow_up, negated, reply.
Semantic parseSemantic(String raw) {
  final j = extractJsonObject(raw);
  final intent = j['intent'];
  if (intent is! String || !semanticIntents.contains(intent)) {
    throw ToolError('not a semantic plan');
  }
  // Untrusted even when grammar-constrained: unknown keys or fields that make
  // no sense for the intent mean the plan is not understood.
  for (final k in j.keys) {
    if (k != 'intent' && k != 'negated' && !_fields[intent]!.contains(k)) {
      throw ToolError('"$k" does not belong to $intent');
    }
  }
  String? str(String k) {
    final v = j[k];
    if (v == null) return null;
    if (v is! String || v.length > 300) throw ToolError('bad "$k"');
    final s = v.trim();
    return s.isEmpty ? null : s;
  }

  bool? flag(String k) {
    final v = j[k];
    if (v == null || v is bool) return v as bool?;
    throw ToolError('bad "$k"');
  }

  final range = str('range');
  if (range != null && !semanticRanges.contains(range)) throw ToolError('bad range');
  return Semantic(intent,
      title: str('title'),
      ref: str('ref'),
      when: str('when'),
      range: range,
      reply: str('reply'),
      multiple: flag('multiple'),
      followUp: flag('follow_up'),
      negated: flag('negated') ?? false);
}

/// GBNF for [parseSemantic]: one object, known intent/range values, typed
/// optional fields in a fixed order (so the 0.6B model can't invent keys).
final String semanticGrammar = () {
  String alt(List<String> l) => l.map((v) => '"\\"$v\\""').join(' | ');
  String opt(String key, String v) => '("," "\\"$key\\":" $v)?';
  return [
    'root ::= "{" "\\"intent\\":" intent ${opt('title', 'str')} ${opt('ref', 'str')} '
        '${opt('when', 'str')} ${opt('range', 'range')} ${opt('multiple', 'bool')} '
        '${opt('follow_up', 'bool')} ${opt('negated', 'bool')} ${opt('reply', 'str')} "}"',
    'intent ::= ${alt(semanticIntents)}',
    'range ::= ${alt(semanticRanges)}',
    'bool ::= "true" | "false"',
    jsonStrRule,
  ].join('\n');
}();

/// list_tasks arguments for a [semanticRanges] value: one definition for
/// prompts, rules and the database query. tomorrow/today = due that day only
/// (undated excluded); overdue = due before now; all = every pending task.
Map<String, Object?> rangeArgs(String range, DateTime now) {
  final day = DateTime(now.year, now.month, now.day);
  DateTime d(int n) => DateTime(day.year, day.month, day.day + n);
  return switch (range) {
    'today' => {'from': d(0), 'to': d(1)},
    'tomorrow' => {'from': d(1), 'to': d(2)},
    'overdue' => {'to': now},
    _ => <String, Object?>{},
  };
}

String rangeLabel(String range) => switch (range) {
      'today' => 'Due today',
      'tomorrow' => 'Due tomorrow',
      'overdue' => 'Overdue',
      _ => 'Pending tasks',
    };
