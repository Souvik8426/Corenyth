part of '../session.dart';

extension _SessionCommit on AssistantSession {
  Future<String> _commit(CandidatePlan plan, String text,
      Map<String, int> timing, OperationJournal? journal,
      {bool recovering = false}) async {
    var p = plan;
    final v = validatePlan(p);
    _diag['validation'] = v.accepted ? 'ok' : v.reason!;
    if (!v.accepted) {
      _note = _header = _prefix = null;
      p = CandidatePlan(
          interpreter: p.interpreter,
          route: p.route,
          call: AssistantSession._say(v.reply!),
          evidence: p.evidence,
          authorization: p.authorization,
          modelAuthorization: p.modelAuthorization);
    }
    final memo =
        _memoryEffect != null && _auth.permitsReport ? _memoryEffect : null;
    if (p.call.tool != 'respond' || p.effects.isNotEmpty) {
      _go(SessionState.executing);
    }
    _diag['tool'] = p.call.tool;
    _diag['db'] = p.call.tool == 'respond' ? 'none' : 'error';
    if ((p.writes || memo != null) && !recovering) {
      // The memory write rides in the journaled action, so a crash before
      // it commits replays it with the same arguments (plan 1.3).
      final action = p.toActionJson();
      await journal?.mark(_op, OperationJournal.executing,
          action: memo == null
              ? action
              : jsonEncode({
                  ...(jsonDecode(action) as Map<String, Object?>),
                  'memory': encodeCall(memo),
                }));
    }
    final receipts = <ExecutionReceipt>[];
    final opId = journal == null ? null : _op;
    bool independentCreate(ToolCall c) => const {
          'create_task', 'create_reminder', 'create_daily'
        }.contains(c.tool);
    final scopeCreates = [...p.effects, p.call]
        .where((c) => independentCreate(c) || c.tool == 'create_batch')
        .length > 1;
    // Batch preview indices are durable and may be sparse. Reserve them
    // before assigning indices to independent effects and the main create.
    final reserved = <int>{};
    for (final c in [...p.effects, p.call]) {
      if (c.tool != 'create_batch') continue;
      final items = c.args['items'];
      if (items is List) {
        for (final item in items) {
          if (item is Map && item['index'] is int) {
            reserved.add(item['index'] as int);
          }
        }
      }
    }
    var createIndex = 0;
    Future<ExecutionReceipt> run(ToolCall c) async {
      final ExecutionReceipt r;
      if (scopeCreates && independentCreate(c) && opId != null) {
        do { createIndex++; } while (reserved.contains(createIndex));
        r = await tools.runIndependentCreate(c,
            operationId: '$opId#$createIndex',
            legacyOperationId: opId,
            recovering: recovering);
      } else {
        r = await tools.run(c,
          operationId: c.tool == 'create_batch' ? _op : opId,
          // Any existing unlinked turn is legacy/unknown, including failed
          // turns being routed again. Its memory action must stay withheld.
          recovering: recovering ||
              (c.tool == 'save_memory' &&
                  journal != null &&
                  _userRowId == null),
          memorySource: opId == null || _userRowId == null
              ? null
              : MemoryWriteSource(opId, id, _userRowId!));
      }
      receipts.add(r);
      return r;
    }

    final exec = Stopwatch()..start();
    var memoWrote = false;
    try {
      if (memo != null) {
        // A thrown error still aborts the turn (the journal replays it); a
        // failed receipt lets the turn go on, and the reply below then makes
        // no claim that anything was remembered.
        final saved = await run(memo);
        memoWrote = saved.wrote;
        if (saved.wrote) _saved.add(memo.args['content'] as String);
      }
      for (final e in p.effects) {
        await run(e);
      }
      await _applyPending(p.pending);
      final before = await _before(p.call);
      final main = await run(p.call);
      if (v.accepted && _batchTouched) await _storeBatch(_batchUpdate);
      if (p.call.tool == 'create_batch' && recovering) await _storeBatch(null);
      if (p.call.tool != 'respond') _diag['db'] = 'ok';
      _diag['receipt'] = main.status.name;
      if (main.alarm != AlarmStatus.none) _diag['alarm'] = main.alarm.name;
      await _rememberTask(p.call);
      var reply = await _after(p.call, before, main.reply, text, run);
      final memoryUnresolved =
          receipts.any((r) => r.error == memoryRecoveryUnresolved);
      // "I'll remember that" only when this turn's memory write landed.
      if (p.call.tool == 'respond' &&
          !memoWrote &&
          AssistantSession._memoryClaim.hasMatch(reply.trim())) {
        reply = memoryUnresolved
            ? AssistantSession._memoryRecoveryWithheld
            : memo == null
                ? 'Got it.'
                : AssistantSession._memoryWriteFailed;
        _diag['memory'] ??= memo == null ? 'not_saved' : 'write_failed';
      }
      if (memoryUnresolved && !reply.contains(AssistantSession._memoryRecoveryWithheld)) {
        reply = '$reply ${AssistantSession._memoryRecoveryWithheld}';
      }
      lastTurn = TurnRecord(
          operationId: _op,
          plan: p,
          validation: v,
          receipts: receipts,
          reply: reply);
      if (receipts.any((r) => r.wrote) || memoryUnresolved) {
        await journal?.mark(
            _op,
            memoryUnresolved
                ? OperationJournal.recoveryUnresolved
                : OperationJournal.committed,
            receipt: jsonEncode(lastTurn!.toJson()));
      }
      return reply;
    } on ToolError catch (e) {
      receipts.add(ExecutionReceipt(
          tool: p.call.tool,
          status: ReceiptStatus.failed,
          operationId: opId,
          reply: e.message,
          error: e.message));
      _diag['receipt'] = 'failed';
      lastTurn = TurnRecord(
          operationId: _op,
          plan: p,
          validation: v,
          receipts: receipts,
          reply: e.message);
      rethrow;
    } finally {
      timing['execution'] = exec.elapsedMilliseconds;
    }
  }

  /// A retried turn whose result was final: the same reply, no new writes.
  Future<String> _replay(Operation prior, void Function(String)? onText) async {
    final receipt = Map<String, Object?>.from(jsonDecode(prior.receipt!) as Map);
    final reply = receipt['reply'] as String? ?? '';
    _routeId = RouteId.retryReplay;
    _diag['route'] = routeName(RouteId.retryReplay);
    if (prior.status == OperationJournal.committed ||
        prior.status == OperationJournal.recoveryUnresolved) {
      // Committed but its reply was never shown (crash): show it once.
      await operations!.publishReply(_op, reply,
          prior.status == OperationJournal.recoveryUnresolved
              ? OperationJournal.recoveryUnresolved
              : OperationJournal.replied,
          receipt, replay: true);
    }
    onText?.call(reply);
    _go(SessionState.speaking);
    if (!_cancelled) await speak?.call(reply);
    return reply;
  }

  /// Cancelled before commit: nothing was written; the "Which one?" this
  /// turn consumed is dropped as before.
  Future<void> _abandon(OperationJournal? journal) async {
    try {
      await journal?.mark(_op, OperationJournal.abandoned);
      if (_pickStored) await _storePick(null);
    } catch (_) {}
  }

}
