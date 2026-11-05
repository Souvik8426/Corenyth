part of '../session.dart';

extension _SessionReceipts on AssistantSession {
  /// Rewrites a validated call by app rules only: a timed meeting the user
  /// said they have gets its alerts (task-linked reminders on) even without
  /// "remind me"; "15 minutes before" is that item's own early alert.
  Future<ToolCall> _adjust(ToolCall c) async {
    final a = c.args, due = a['due'];
    final r = c.tool.startsWith('create_') ? _fallback.readWhen(_said) : null;
    if (c.tool == 'create_task' &&
        due is DateTime &&
        r != null &&
        r.dated &&
        !r.timed &&
        RegExp(r'^call(?: with .+)?$', caseSensitive: false)
            .hasMatch((a['title'] as String).trim())) {
      final draft = ClarifyDraft(
          tool: c.tool,
          title: a['title'] as String,
          day: due.toIso8601String().substring(0, 10));
      _diag['clarify'] = 'event_time';
      _note = null;
      await _setDraft(draft);
      return AssistantSession._say(draft.prompt);
    }
    final rel = r?.anchor?.relation;
    final deadline = r != null &&
        r.role == TemporalRole.deadline &&
        (rel == TemporalRelation.within || rel == TemporalRelation.before);
    if (deadline && c.tool == 'create_reminder' && r.at == a['at']) {
      _note = _note == null ? AssistantSession._deadlineNote : '$_note ${AssistantSession._deadlineNote}';
    }
    if (c.tool == 'create_task' &&
        !deadline &&
        tools.preferences != null &&
        due is DateTime &&
        due.isAfter(_now()) &&
        (isEventTitle(a['title'] as String) ||
            (await tools.preferences!.get()).multiple)) {
      c = ToolCall('create_reminder', {'title': a['title'], 'at': due});
    }
    if (c.tool == 'create_reminder' && _leadMin != null) {
      c = ToolCall(c.tool, {
        ...c.args,
        'lead': [_leadMin!]
      });
    }
    if (c.tool == 'create_reminder' &&
        tools.preferences != null &&
        !isEventTitle(c.args['title'] as String) &&
        !c.args.containsKey('follow_up')) {
      c = ToolCall(c.tool, {...c.args, 'follow_up': false});
    }
    return c;
  }

  /// Grounding for [c]'s fields, as the route recorded it, else read from
  /// the message itself: a title said (at least half its words), the user's
  /// own time words, an id the user typed or an exact title they gave.
  Map<String, String> _evidenceFor(ToolCall c) {
    final e = {..._evidence};
    final f = familyOf(c.tool);
    if (f == ActionFamily.create) {
      final title = c.args['title'];
      if (e['title'] == null && title is String && AssistantSession._grounded(title, _said)) {
        e['title'] = 'said';
      }
      final timed = c.args['at'] != null || c.args['due'] != null;
      if (e['time'] == null && timed) {
        final r = _fallback.readWhen(_said);
        if (r.spans.isNotEmpty) {
          e['time'] = r.spans.map((s) => s.text).join(' | ');
        } else if (r.at != null || _fallback.findWhen(_said).at != null) {
          e['time'] = 'resolved';
        }
      }
    } else if (f == ActionFamily.change && e['target'] == null) {
      final id = c.args['id'];
      final sel = c.args['title'] ?? c.args['target_title'];
      if (id is int && RegExp('(?:#|\\b)$id\\b').hasMatch(_said)) {
        e['target'] = 'typed';
      } else if (sel is String && AssistantSession._grounded(sel, _said, all: true)) {
        e['target'] = 'exact_title';
      }
    }
    return e;
  }

  /// The task a completion is about, read before it runs (its follow-up is
  /// cancelled by it): is it a meeting-like event?
  Future<({Task task, bool event})?> _before(ToolCall c) async {
    if (c.tool != 'complete_task') return null;
    try {
      final ref = c.args['id'], title = c.args['title'];
      Task? t;
      if (ref is int) {
        t = await taskRepo.get(ref);
      } else if (title is String) {
        final l = await taskRepo.byTitle(title);
        t = l.length == 1 ? l.single : null;
      }
      if (t == null || t.done) return null;
      final id = t.id;
      final follow = (await tools.reminders.upcoming())
          .any((r) => r.taskId == id && r.kind == 'follow_up');
      return (
        task: t,
        event: follow ||
            t.endsAt != null ||
            t.subject != null ||
            isEventTitle(t.title)
      );
    } catch (_) {
      return null;
    }
  }

  /// After a committed write: a new meeting asks its optional details; a
  /// finished one asks how it went (follow-ups on) or notes the outcome the
  /// message already gave. Metadata only, through the executor ([run]); a
  /// failure here never hides the write's own reply.
  Future<String> _after(
      ToolCall c,
      ({Task task, bool event})? before,
      String reply,
      String text,
      Future<ExecutionReceipt> Function(ToolCall) run) async {
    try {
      if (_subject != null &&
          c.tool.startsWith('create_') &&
          _lastTask != null) {
        await run(ToolCall(
            'set_event_details', {'id': _lastTask, 'subject': _subject}));
      }
      if (c.tool == 'create_reminder' && _lastTask != null) {
        final found = await taskRepo.get(_lastTask!);
        if (found == null || found.done || !isEventTitle(found.title)) {
          return reply;
        }
        var t = found;
        // "meeting in 10 minutes for half an hour": its end, not its start.
        final r = _fallback.readWhen(text);
        if (r.end != null && t.dueAt == r.at && t.endsAt == null) {
          try {
            await run(
                ToolCall('set_event_details', {'id': t.id, 'ends_at': r.end}));
            t = await taskRepo.get(t.id) ?? t;
          } on ToolError {
            // not after the start: the optional question below still asks
          }
        }
        final more = <String>[];
        if (t.awaiting == null && t.endsAt == null && t.subject == null) {
          await run(ToolCall(
              'set_awaiting', {'id': t.id, 'question': TaskRepo.details}));
          final follow = (await tools.reminders.upcoming())
              .any((r) => r.taskId == t.id && r.kind == 'follow_up');
          more.add(follow
              ? 'When does it end, and what is it about? Then I can check in right after it ends. (Optional.)'
              : 'Optional: when does it end, and what is it about?');
        }
        final k = keyWords(t.title)
            .where((w) => !isEventTitle(w) && w != 'meet')
            .toSet();
        for (final o in await taskRepo.list()) {
          if (o.id != t.id &&
              isArrangement(o.title) &&
              keyWords(o.title).any(k.contains)) {
            more.add(
                'Your task #${o.id} "${o.title}" is still open; say "complete task #${o.id}" '
                'when setting it up is done.');
            break;
          }
        }
        return [reply, ...more].join(' ');
      }
      if (c.tool != 'complete_task' ||
          before == null ||
          (!before.event && c.args['outcome'] == null)) return reply;
      final t = before.task;
      await run(ToolCall('review_answered', {'id': t.id}));
      final outcome =
          (c.args['outcome'] as String?) ?? eventDone(text)?.outcome;
      if (outcome != null) {
        final sp = splitRequest(outcome);
        if (t.awaiting == TaskRepo.details) {
          await run(ToolCall('set_awaiting', {'id': t.id, 'question': null}));
        }
        if (sp.outcome.isNotEmpty) {
          await run(
              ToolCall('record_outcome', {'id': t.id, 'outcome': sp.outcome}));
        }
        final ack = sp.outcome.isEmpty
            ? ''
            : await _converse(
                sp.outcome,
                [_line(t)],
                'Thanks for telling me how it went; I noted it.',
                'This is finished and the user said how it went (it may not have happened). Acknowledge that in one sentence; do not ask how it went.');
        return [
          reply,
          if (ack.isNotEmpty) ack,
          sp.request == null
              ? 'If anything from it needs a reminder, just tell me.'
              : 'To set a reminder from it, send it on its own, e.g. "${sp.request}".',
        ].join(' ');
      }
      if (!before.event) return reply;
      if ((await tools.preferences?.get())?.followUp ?? false) {
        await run(ToolCall('set_awaiting',
            {'id': t.id, 'question': TaskRepo.outcomeQuestion}));
        return '$reply How did it go? Anything from it you want me to remind you about later?';
      }
      if (t.awaiting == TaskRepo.details) {
        await run(ToolCall('set_awaiting', {'id': t.id, 'question': null}));
      }
      return reply;
    } on ToolError {
      return reply; // cancelled mid-reply: the committed write still reports itself
    } catch (e) {
      debugPrint('follow-through metadata failed');
      return reply;
    }
  }

}
