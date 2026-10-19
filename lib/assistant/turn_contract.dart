import 'dart:convert';

import 'authorization.dart';
import 'rule_engine.dart' show ClarifyDraft;
import 'tools.dart' show ToolCall, parseLocalDateTime;

/// The P2 turn contract: `TurnInput → CandidatePlan → ValidatedAction or
/// clarification → ExecutionReceipt → reply`. Every interpreter and route
/// produces a [CandidatePlan]; one validator ([validatePlan]) and one
/// executor (ToolExecutor) decide and perform writes.

/// Which interpreter chooses routes. [legacy] is the pre-P2 route chain
/// (kept for rollback and comparison); [unified] is the coordinator's route
/// table with the plan-v2 semantic contract. Both share the validator,
/// executor, receipts and operation journal, and only the active one writes.
enum Interpreter { legacy, unified }

/// Build-time switch: `--dart-define=CORENYTH_INTERPRETER=unified`. The
/// prior route stays the default until the P5 parity/device gates pass.
const defaultInterpreter =
    String.fromEnvironment('CORENYTH_INTERPRETER') == 'unified'
        ? Interpreter.unified
        : Interpreter.legacy;

/// Every route that may settle a turn, in the unified coordinator's priority
/// order (lower index first). Each returns handled / not handled / needs
/// clarification through a [CandidatePlan]; the first handled one wins, so
/// an accepted action has exactly one route.
enum RouteId {
  /// "remember that …": an explicit memory, settled before anything else.
  explicitMemory,

  /// A persisted "Which one?" this chat asked: "#3" or a full name.
  pendingPick,

  /// Arithmetic, answered without the model.
  calculator,

  /// A reply that only gives the open time question's time (or "cancel").
  pendingAnswer,

  /// "That was dumb, answer my previous message": re-answers, never writes.
  complaint,

  /// "remind me daily at 8:46 until 5 November …".
  dailySchedule,

  /// Optional meeting end/subject for a task awaiting details.
  eventDetails,

  /// "The meeting is over (, it went well)": completes that event.
  eventDone,

  /// How an event went, answering its outcome question.
  outcome,

  /// News about existing work ("Aditya hasn't replied"): talked through.
  progress,

  /// "Brief me" / "what does my day look like".
  briefing,

  /// A negated reminder request naming saved reminders (unified only): asks
  /// which to cancel, never creates or cancels by itself.
  negatedCancel,

  /// The local model's semantic plan (grammar constrained, validated).
  semantic,

  /// Fully recognized deterministic commands and their clarifications.
  rules,

  /// Read-only rule replies when nothing else understood the message.
  rulePlan,

  /// A retried operation whose result was already final (no new writes).
  retryReplay,

  /// A retried operation finishing its stored validated action after a crash.
  retryRecover,
}

/// The diagnostics names used since P0 (`route`), kept stable.
String routeName(RouteId r) => switch (r) {
      RouteId.explicitMemory => 'explicit_memory',
      RouteId.pendingPick ||
      RouteId.calculator ||
      RouteId.pendingAnswer =>
        'early',
      RouteId.complaint => 'complaint',
      RouteId.dailySchedule ||
      RouteId.eventDetails ||
      RouteId.eventDone ||
      RouteId.outcome ||
      RouteId.progress ||
      RouteId.briefing =>
        'follow_through',
      RouteId.negatedCancel => 'negated_cancel',
      RouteId.semantic => 'semantic',
      RouteId.rules => 'rules',
      RouteId.rulePlan => 'rule_plan',
      RouteId.retryReplay => 'retry_replay',
      RouteId.retryRecover => 'retry_recover',
    };

enum ActionFamily {
  /// Prose only.
  reply,

  /// Database reads (lists, memory lookups, briefings).
  read,

  /// New tasks/reminders/daily schedules.
  create,

  /// Completion, deletion, edits, moves, reminder cancellation.
  change,

  /// Facts about existing work (details, outcomes, open questions, review
  /// participation) and personal memories.
  report,
}

ActionFamily familyOf(String tool) => switch (tool) {
      'respond' => ActionFamily.reply,
      'list_tasks' ||
      'list_reminders' ||
      'search_memory' ||
      'briefing' =>
        ActionFamily.read,
      'create_task' ||
      'create_reminder' ||
      'create_daily' =>
        ActionFamily.create,
      'complete_task' ||
      'delete_task' ||
      'edit_task' ||
      'edit_reminder' ||
      'cancel_reminder' =>
        ActionFamily.change,
      _ => ActionFamily.report,
    };

bool isWrite(String tool) =>
    familyOf(tool) != ActionFamily.reply && familyOf(tool) != ActionFamily.read;

/// A "Which one?" the assistant asked: the action waiting for its target.
/// Persisted per chat (PendingRepo key `pick:<chat>`), so a restart keeps
/// its meaning; it lives for the next turn only, as before P2.
class TargetPick {
  final String tool;
  final Map<String, Object?> args;
  final Duration? shift;
  final List<int> ids;
  final DateTime askedAt;
  const TargetPick(
      {required this.tool,
      required this.args,
      this.shift,
      required this.ids,
      required this.askedAt});

  /// Older picks are ignored: a stray "3" days later must not act.
  static const maxAge = Duration(hours: 6);

  Map<String, Object?> toJson() => {
        'kind': 'pick',
        'v': 1,
        'tool': tool,
        'args': encodeArgs(args),
        if (shift != null) 'shift_min': shift!.inMinutes,
        'ids': ids,
        'asked_at': askedAt.toIso8601String(),
      };

  /// Null for anything that isn't a well-typed pick.
  static TargetPick? fromJson(Map<String, Object?> j) {
    try {
      if (j['kind'] != 'pick') return null;
      final tool = j['tool'], ids = j['ids'], at = j['asked_at'];
      if (tool is! String || ids is! List || at is! String) return null;
      final asked = DateTime.tryParse(at);
      if (asked == null) return null;
      final s = j['shift_min'];
      return TargetPick(
          tool: tool,
          args: decodeArgs(Map<String, Object?>.from(j['args'] as Map)),
          shift: s is int ? Duration(minutes: s) : null,
          ids: [for (final i in ids) i as int],
          askedAt: asked);
    } catch (_) {
      return null;
    }
  }
}

/// JSON-safe tool arguments: DateTime as `{"$dt": iso}`.
Map<String, Object?> encodeArgs(Map<String, Object?> a) => {
      for (final e in a.entries)
        e.key: e.value is DateTime
            ? {r'$dt': (e.value as DateTime).toIso8601String()}
            : e.value
    };

Map<String, Object?> decodeArgs(Map<String, Object?> a) => {
      for (final e in a.entries)
        e.key: e.value is Map && (e.value as Map).containsKey(r'$dt')
            ? parseLocalDateTime((e.value as Map)[r'$dt'] as String) ??
                DateTime.parse((e.value as Map)[r'$dt'] as String)
            : e.value is List
                ? [for (final x in e.value as List) x]
                : e.value
    };

Map<String, Object?> encodeCall(ToolCall c) =>
    {'tool': c.tool, 'args': encodeArgs(c.args)};

ToolCall decodeCall(Map<String, Object?> j) {
  final args = decodeArgs(Map<String, Object?>.from(j['args'] as Map));
  final lead = args['lead'];
  if (lead is List) args['lead'] = [for (final x in lead) x as int];
  return ToolCall(j['tool'] as String, args);
}

/// A change to the open interactions, applied only when the turn commits
/// (never in a dry run, never after a cancel before commit).
class PendingChange {
  final ClarifyDraft? draft;
  final TargetPick? pick;
  final bool clearDraft;
  const PendingChange.setDraft(ClarifyDraft this.draft)
      : pick = null,
        clearDraft = false;
  const PendingChange.clearDraft()
      : draft = null,
        pick = null,
        clearDraft = true;
  const PendingChange.setPick(TargetPick this.pick)
      : draft = null,
        clearDraft = false;

  String get kind => draft != null
      ? 'draft_set'
      : pick != null
          ? 'pick_set'
          : 'draft_clear';

  Map<String, Object?> toJson() => {
        'kind': kind,
        if (draft != null) 'draft': draft!.toJson(),
        if (pick != null) 'pick': pick!.toJson(),
      };

  static PendingChange? fromJson(Map<String, Object?> j) {
    switch (j['kind']) {
      case 'draft_clear':
        return const PendingChange.clearDraft();
      case 'draft_set':
        final d = ClarifyDraft.fromJson(
            Map<String, Object?>.from(j['draft'] as Map));
        return d == null ? null : PendingChange.setDraft(d);
      case 'pick_set':
        final p =
            TargetPick.fromJson(Map<String, Object?>.from(j['pick'] as Map));
        return p == null ? null : PendingChange.setPick(p);
    }
    return null;
  }
}

/// What one interpreter made of a turn, before validation. [effects] are
/// report writes performed before [call] (an outcome noted, review
/// participation); [pending] are interaction changes. [evidence] names the
/// grounding of each field: `title` (said / pending / task), `time` (the
/// user's time words), `target` (typed / pick / named / exact / pronoun).
class CandidatePlan {
  final Interpreter interpreter;
  final RouteId route;
  final ToolCall call;
  final List<ToolCall> effects;
  final List<PendingChange> pending;
  final Map<String, String> evidence;
  final AuthorizationReading authorization;

  /// The model's own authorization label (plan-v2), or null. Recorded, never
  /// trusted alone.
  final String? modelAuthorization;

  /// Clarification code when [call] asks rather than acts.
  final String? clarify;

  /// Reply composition (disclosures, list header, outcome prefix).
  final String? note, header, prefix;
  const CandidatePlan({
    required this.interpreter,
    required this.route,
    required this.call,
    this.effects = const [],
    this.pending = const [],
    this.evidence = const {},
    required this.authorization,
    this.modelAuthorization,
    this.clarify,
    this.note,
    this.header,
    this.prefix,
  });

  bool get writes => isWrite(call.tool) || effects.any((e) => isWrite(e.tool));

  /// A comparable, text-free summary for old/new comparisons.
  Map<String, Object?> summary() => {
        'route': routeName(route),
        'tool': call.tool,
        if (call.tool != 'respond') 'args': encodeArgs(call.args),
        'effects': [for (final e in effects) e.tool],
        'pending': [for (final p in pending) p.kind],
        if (clarify != null) 'clarify': clarify,
      };

  /// What the journal stores to finish this plan after a crash.
  String toActionJson() => jsonEncode({
        'route': route.name,
        'call': encodeCall(call),
        'effects': [for (final e in effects) encodeCall(e)],
        'pending': [for (final p in pending) p.toJson()],
        'evidence': evidence,
        if (note != null) 'note': note,
        if (header != null) 'header': header,
        if (prefix != null) 'prefix': prefix,
      });

  static CandidatePlan fromActionJson(String raw, Interpreter interpreter,
      AuthorizationReading authorization) {
    final j = Map<String, Object?>.from(jsonDecode(raw) as Map);
    return CandidatePlan(
      interpreter: interpreter,
      route: RouteId.values.byName(j['route'] as String),
      call: decodeCall(Map<String, Object?>.from(j['call'] as Map)),
      effects: [
        for (final e in j['effects'] as List)
          decodeCall(Map<String, Object?>.from(e as Map))
      ],
      pending: [
        for (final p in j['pending'] as List)
          if (PendingChange.fromJson(Map<String, Object?>.from(p as Map))
              case final c?)
            c
      ],
      evidence: Map<String, String>.from(j['evidence'] as Map),
      authorization: authorization,
      note: j['note'] as String?,
      header: j['header'] as String?,
      prefix: j['prefix'] as String?,
    );
  }
}

/// [validatePlan]'s verdict: accepted, or the no-write reply to give.
class Validation {
  final bool accepted;
  final String? reason, reply;
  const Validation.accept()
      : accepted = true,
        reason = null,
        reply = null;
  const Validation.reject(String this.reason, String this.reply)
      : accepted = false;
}

/// The one gate between any route's plan and the executor:
/// - creates and changes need an authorizing message (request or statement),
///   grounded evidence for their title, time and target;
/// - reports need a message that reports something (not a question or a
///   supposition);
/// - replies and reads are always allowed (questions are how reads are asked).
/// Answers to an open question (pending answer / pick) carry the original
/// request's authorization; the answer itself must still not be negated,
/// hypothetical or a question.
Validation validatePlan(CandidatePlan p) {
  final auth = p.authorization;
  for (final c in [...p.effects, p.call]) {
    final f = familyOf(c.tool);
    if (f == ActionFamily.reply || f == ActionFamily.read) continue;
    if (f == ActionFamily.report) {
      if (!auth.permitsReport) return _blocked(auth, 'report');
      continue;
    }
    if (!auth.permitsWrite) return _blocked(auth, f.name);
    if (f == ActionFamily.create) {
      if (p.evidence['title'] == null) {
        return const Validation.reject('no_title_evidence',
            "I couldn't tell exactly what to save, so I saved nothing. What should I add?");
      }
      final timed = c.args['at'] != null || c.args['due'] != null;
      if (timed && p.evidence['time'] == null) {
        return const Validation.reject('no_time_evidence',
            "I couldn't tell when you meant, so I saved nothing. When should it be?");
      }
    } else if (p.evidence['target'] == null) {
      return const Validation.reject('no_target_evidence',
          "I couldn't tell exactly which item you meant, so I didn't change anything.");
    }
  }
  return const Validation.accept();
}

Validation _blocked(AuthorizationReading a, String family) => switch (a.kind) {
      Authorization.negated => Validation.reject(
          'blocked_negated_$family', "Okay, I won't do that. Nothing changed."),
      Authorization.hypothetical => Validation.reject(
          'blocked_hypothetical_$family',
          "I haven't set anything since that sounds undecided. "
              'If you want a reminder, tell me what and when.'),
      _ => Validation.reject('blocked_question_$family',
          "I haven't changed anything, since that sounded like a question. "
              'Tell me if you want me to do it.'),
    };

enum ReceiptStatus {
  /// The write committed in this call.
  committed,

  /// The write had already committed under this operation id (a retry); the
  /// receipt was rebuilt from the stamped rows, nothing was written again.
  replayed,

  /// A database read.
  readOnly,

  /// Prose only.
  noWrite,

  /// Rejected or rolled back; [ExecutionReceipt.error] says why.
  failed,
}

enum AlarmStatus {
  none,

  /// Android accepted every alarm (not proof of delivery).
  scheduled,

  /// Saved, but the phone won't deliver as asked (permission/settings).
  permissionRequired,

  /// Saved; some alarm operation is still pending and will be retried.
  pendingRetry,

  /// Linked future alerts were cancelled.
  cancelled,
}

/// What a tool call actually did, from the executor (never from a model):
/// the committed identities, resulting time and scheduling state. Replies
/// that confirm actions are rendered from it.
class ExecutionReceipt {
  final String tool;
  final ReceiptStatus status;
  final String? operationId;
  final List<int> taskIds, reminderIds;
  final DateTime? at;
  final AlarmStatus alarm;

  /// The executor's factual confirmation (or error) text.
  final String reply;
  final String? error;
  const ExecutionReceipt({
    required this.tool,
    required this.status,
    this.operationId,
    this.taskIds = const [],
    this.reminderIds = const [],
    this.at,
    this.alarm = AlarmStatus.none,
    required this.reply,
    this.error,
  });

  bool get wrote =>
      status == ReceiptStatus.committed || status == ReceiptStatus.replayed;

  Map<String, Object?> toJson() => {
        'tool': tool,
        'status': status.name,
        if (operationId != null) 'op': operationId,
        'tasks': taskIds,
        'reminders': reminderIds,
        if (at != null) 'at': at!.toIso8601String(),
        'alarm': alarm.name,
        'reply': reply,
        if (error != null) 'error': error,
      };

  static ExecutionReceipt fromJson(Map<String, Object?> j) => ExecutionReceipt(
        tool: j['tool'] as String,
        status: ReceiptStatus.values.byName(j['status'] as String),
        operationId: j['op'] as String?,
        taskIds: [for (final x in j['tasks'] as List) x as int],
        reminderIds: [for (final x in j['reminders'] as List) x as int],
        at: j['at'] == null ? null : DateTime.parse(j['at'] as String),
        alarm: AlarmStatus.values.byName(j['alarm'] as String),
        reply: j['reply'] as String,
        error: j['error'] as String?,
      );
}

/// One turn's final record: the accepted plan, its validation and every
/// receipt (report effects first, then the main call, then follow-through
/// metadata it caused).
class TurnRecord {
  final String operationId;
  final CandidatePlan plan;
  final Validation validation;
  final List<ExecutionReceipt> receipts;
  final String reply;
  const TurnRecord(
      {required this.operationId,
      required this.plan,
      required this.validation,
      required this.receipts,
      required this.reply});

  /// The receipt of the plan's main call.
  ExecutionReceipt? get main =>
      receipts.where((r) => r.tool == plan.call.tool).lastOrNull;

  Map<String, Object?> toJson() => {
        'op': operationId,
        'route': routeName(plan.route),
        'receipts': [for (final r in receipts) r.toJson()],
        'reply': reply,
      };
}

/// Read-only comparison of both interpreters on one message (no writes, no
/// reply-model calls). [agree] compares route family, tool, arguments,
/// effects and pending changes.
class InterpreterComparison {
  final CandidatePlan legacy, unified;
  const InterpreterComparison(this.legacy, this.unified);

  bool get agree =>
      jsonEncode(_cmp(legacy.summary())) == jsonEncode(_cmp(unified.summary()));

  /// The reply text of chat answers may differ; only actions are compared.
  static Map<String, Object?> _cmp(Map<String, Object?> s) =>
      {...s}..remove('route');

  bool get sameRoute => legacy.route == unified.route;
}
