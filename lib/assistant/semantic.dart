import '../mascot/mascot_emotion.dart';
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

/// plan-v2 (unified interpreter): the v1 intents plus follow-through ones,
/// and an explicit [semanticAuthorizations] label replacing v1's `negated`
/// (whose "only asking" wording made polite requests look like refusals).
const semanticIntentsV2 = [
  ...semanticIntents,
  'progress', // news about an existing task ("Aditya hasn't replied")
  'outcome', // how a finished event went
  'details', // when an event ends / what it is about
];
const semanticAuthorizations = [
  'request',
  'statement',
  'question',
  'hypothetical',
  'negated',
];

class Semantic {
  final String intent;
  final String? title, ref, when, range, reply;
  final bool? multiple, followUp;
  final bool negated;

  /// plan-v2 only: the model's [semanticAuthorizations] label (evidence the
  /// app compares with its own reading; never permission by itself).
  final String? authorization;

  /// The validated mood envelope of the same generation, or null when it was
  /// absent or malformed (unknown provenance; never a plan failure).
  final MoodReading? mood;
  const Semantic(this.intent,
      {this.title,
      this.ref,
      this.when,
      this.range,
      this.reply,
      this.multiple,
      this.followUp,
      this.negated = false,
      this.authorization,
      this.mood});
}

/// Fields each intent may carry (besides `intent` and `negated`).
/// Every intent ends with `reply`: the model's own words to the user, in
/// their tone. For chat it is the answer; for anything else a follow-up the
/// app appends after its own exact confirmation (see [isSafeFollowUp]).
const _fields = {
  'create_task': {'title', 'when', 'reply'},
  'create_reminder': {'title', 'when', 'multiple', 'follow_up', 'reply'},
  'complete': {'ref', 'title', 'reply'},
  'delete': {'ref', 'title', 'reply'},
  'postpone': {'ref', 'title', 'when', 'reply'},
  'list': {'range', 'reply'},
  'recall': {'title', 'reply'},
  'answer_pending': {'when', 'reply'},
  'cancel_pending': {'reply'},
  'chat': {'reply'},
};

const _fieldsV2 = {
  ..._fields,
  'progress': {'ref', 'reply'},
  'outcome': {'ref', 'reply'},
  'details': {'ref', 'title', 'when', 'reply'},
};

/// Field order is fixed by [semanticGrammar]: emotion, intent, title, ref,
/// when, range, multiple, follow_up, negated/authorization, reply. The mood
/// envelope comes first so a streaming consumer has it before any reply text.
/// [version] 2 reads plan-v2 ([semanticGrammarV2]): its intents, and
/// `authorization` (a v1 `negated` is still accepted, as authorization
/// "negated" when true).
///
/// The mood envelope is validated on its own: absent or malformed emotion
/// degrades to an unknown reading and never fails an otherwise valid plan,
/// while every other unknown key still rejects the whole plan.
Semantic parseSemantic(String raw, {int version = 1}) {
  final j = extractJsonObject(raw);
  final mood = MoodReading.parse(j[moodContractKey]);
  final intent = j['intent'];
  final intents = version == 2 ? semanticIntentsV2 : semanticIntents;
  final fields = version == 2 ? _fieldsV2 : _fields;
  if (intent is! String || !intents.contains(intent)) {
    throw ToolError('not a semantic plan');
  }
  // Untrusted even when grammar-constrained: unknown keys or fields that make
  // no sense for the intent mean the plan is not understood.
  for (final k in j.keys) {
    if (k != 'intent' &&
        k != 'negated' &&
        k != moodContractKey &&
        !(version == 2 && k == 'authorization') &&
        !fields[intent]!.contains(k)) {
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
  if (range != null && !semanticRanges.contains(range))
    throw ToolError('bad range');
  var auth = version == 2 ? str('authorization') : null;
  if (auth != null && !semanticAuthorizations.contains(auth)) {
    throw ToolError('bad authorization');
  }
  final negated = flag('negated') ?? false;
  if (version == 2 && auth == null && negated) auth = 'negated';
  return Semantic(intent,
      authorization: auth,
      mood: mood,
      title: str('title'),
      ref: str('ref'),
      when: str('when'),
      range: range,
      reply: str('reply'),
      multiple: flag('multiple'),
      followUp: flag('follow_up'),
      negated: negated || auth == 'negated');
}

/// Intent-specific grammar mirrors the parser exactly. An unconstrained
/// optional-field union caused small models to fill irrelevant fields, making
/// otherwise grammatical plans fail validation on every request.
///
/// The mood envelope is the required first field of every plan (and of the
/// reply contract), so a streaming consumer has it validated before any
/// reply text is generated.
final String emotionGrammar = [
  'emotion ::= "{\\"mood\\":" emood ",\\"intensity\\":" mnum ",\\"confidence\\":" mnum "}"',
  'emood ::= ${moodContractMoods.map((m) => '"\\"$m\\""').join(' | ')}',
  'mnum ::= [0-1] "." [0-9] [0-9]',
].join('\n');

String _semanticGrammar(int version) {
  String alt(List<String> values) =>
      values.map((v) => '\"\\\"$v\\\"\"').join(' | ');
  String opt(String key, String value) => '(\",\" \"\\\"$key\\\":\" $value)?';
  final fields = version == 2 ? _fieldsV2 : _fields;
  final intents = version == 2 ? semanticIntentsV2 : semanticIntents;
  final rules = <String>[];
  for (final intent in intents) {
    final parts = <String>[
      '\"{\"',
      '\"\\\"emotion\\\":\" emotion \",\"',
      '\"\\\"intent\\\":\\\"$intent\\\"\"'
    ];
    for (final key in [
      'title',
      'ref',
      'when',
      'range',
      'multiple',
      'follow_up'
    ]) {
      if (fields[intent]!.contains(key)) {
        parts.add(opt(
            key,
            key == 'range'
                ? 'range'
                : ['multiple', 'follow_up'].contains(key)
                    ? 'bool'
                    : 'str'));
      }
    }
    parts.add(
        version == 2 ? opt('authorization', 'auth') : opt('negated', 'bool'));
    // Required: the model always speaks; the app decides whether to show it.
    if (fields[intent]!.contains('reply')) {
      parts.add('\",\" \"\\\"reply\\\":\" str');
    }
    parts.add('\"}\"');
    rules.add('plan-${intent.replaceAll('_', '-')} ::= ${parts.join(' ')}');
  }
  return [
    'root ::= ${intents.map((i) => 'plan-${i.replaceAll('_', '-')}').join(' | ')}',
    ...rules,
    'range ::= ${alt(semanticRanges)}',
    'auth ::= ${alt(semanticAuthorizations)}',
    'bool ::= \"true\" | \"false\"',
    emotionGrammar,
    jsonStrRule,
  ].join('\n');
}

final String semanticGrammar = _semanticGrammar(1);
final String semanticGrammarV2 = _semanticGrammar(2);

/// list_tasks arguments for a [semanticRanges] value: one definition for
/// prompts, rules and the database query. tomorrow/today = due that day only
/// (undated excluded); overdue = due before now; all = every pending task.
Map<String, Object?> rangeArgs(String range, DateTime now) {
  final day = DateTime(now.year, now.month, now.day);
  DateTime d(int n) => DateTime(day.year, day.month, day.day + n);
  return switch (range) {
    'today' => {'from': d(0), 'to': d(1)},
    'week' => {'from': d(1 - now.weekday), 'to': d(8 - now.weekday)},
    'afternoon_today' => {
        'from': DateTime(now.year, now.month, now.day, 12),
        'to': d(1)
      },
    'tomorrow' => {'from': d(1), 'to': d(2)},
    'overdue' => {'to': now},
    _ => <String, Object?>{},
  };
}

String rangeLabel(String range) => switch (range) {
      'today' => 'Due today',
      'week' => 'This week',
      'afternoon_today' => 'After lunch today',
      'tomorrow' => 'Due tomorrow',
      'overdue' => 'Overdue',
      _ => 'Pending tasks',
    };
