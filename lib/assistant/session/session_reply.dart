part of '../session.dart';

extension _SessionReply on AssistantSession {
  /// Sends [p] to the model within this turn's [_ModelBudget]: null when the
  /// budget for its kind is spent. An identical prompt reuses its output (a
  /// cache hit — the callbacks of the original call do not replay).
  /// [onRaw] receives the cumulative raw output while the model generates;
  /// [onText] the cumulative user-visible respond text, when the contract has
  /// one.
  Future<String?> _complete(Prompt p,
      {void Function(String raw)? onRaw,
      void Function(String visible)? onText}) async {
    final key = '${p.kind.name}\u0000${p.contract}\u0000${p.render()}';
    final seen = _budget._seen[key];
    if (seen != null) return seen;
    if (p.kind == PromptKind.plan) {
      if (_budget.plan >= _ModelBudget.maxPlan) return null;
      _budget.plan++;
    } else {
      if (_budget.reply >= _ModelBudget.maxReply) return null;
      _budget.reply++;
    }
    // Foreground on the shared scheduler: FIFO with every session's
    // foreground calls, never overlapping another generation in this
    // isolate. A cancel of this session surfaces as `llama_cancelled`; a
    // quarantined worker as [ModelCancellationException] (callers fall back).
    final outcome = await models.runWithOutcome(p, ModelPriority.foreground,
        engine: engine, onText: onText, onRaw: onRaw);
    final raw = outcome.output;
    if (outcome.status != ModelRunStatus.completed || raw == null) {
      // Never null-as-budget: only a disposed scheduler gets here.
      throw StateError('model scheduler: ${outcome.status.name}');
    }
    _budget._seen[key] = raw;
    return raw;
  }

  /// Publishes one live-draft update: cumulative visible reply text (''
  /// withdraws the draft). Records the first-visible-text latency once.
  void _sendLive(String text) {
    if (text == _liveSent) return;
    _liveSent = text;
    final t = _timing;
    if (text.isNotEmpty && t != null && !t.containsKey('first_text')) {
      t['first_text'] = _turnClock.elapsedMilliseconds;
    }
    _streamSink?.call(text);
  }

  /// The streaming gate shared by the plan and reply paths: given one
  /// cumulative chunk of visible reply text and [passes] — the same checks
  /// the completed answer must pass — returns the text to publish (cumulative
  /// replace; '' withdraws), or null when nothing new may be shown.
  ///
  /// Guarantees: an *established* violation (ungrounded completed number,
  /// action claim, JSON, oversized text, echo) permanently blocks the stream —
  /// these checks only ever flip from pass to fail as text grows, so nothing
  /// that later fails was ever displayed. An *undecidable* suffix (a number or
  /// claim-verb word still arriving) is held, not judged: 'Those 1' waits,
  /// then 'Those 12 ideas' is released whole when 12 is grounded. Held tails
  /// surface at finalization, when the authoritative answer replaces the
  /// draft. Write plans never reach this gate at all: their replies stay
  /// buffered until the operation commits.
  String? _streamedDraft(String cumulative, bool Function(String) passes) {
    if (_streamBlocked) return null;
    final hold = undecidableSuffixLength(cumulative);
    final decidable = cumulative.substring(0, cumulative.length - hold);
    if (decidable.isEmpty) return null;
    if (passes(decidable)) return decidable;
    _streamBlocked = true;
    return '';
  }

  /// Emits this turn's mood at most once (the first valid reading wins),
  /// reports its arrival latency, and stores it against the turn's user
  /// message row. A storage failure never affects the reply.
  void _emitMood(MoodReading reading, {required String source}) {
    if (_moodEmitted) return;
    _moodEmitted = true;
    final t = _timing;
    if (t != null && !t.containsKey('mood')) {
      t['mood'] = _turnClock.elapsedMilliseconds;
    }
    final record = TurnMood(
      source: source,
      conversationId: id,
      turnId: _op,
      generationId: '$_op/$source#${_budget.plan}p${_budget.reply}r',
      emotion: reading.mood == null
          ? null
          : MascotEmotion(reading.mood!, reading.intensity),
      confidence: reading.confidence,
      messageRowId: _userRowId,
    );
    _moodSink?.call(record);
    _diag['mood'] = '${reading.mood?.name ?? 'unknown'}($source)';
    final repo = moods;
    final row = _userRowId;
    if (repo != null && row != null) {
      _moodSave = repo
          .save(
            messageId: row,
            chatId: id,
            source: source,
            mood: reading.mood?.name,
            intensity: reading.intensity,
            confidence: reading.confidence,
          )
          .catchError((_) {}); // display already updated; retried next turn
    }
  }

  /// A short reply from the local model about facts the app read, in the
  /// user's tone. Only prose: anything claiming an action, carrying an
  /// ungrounded number, parroting the message, or not a plain reply falls
  /// back to [fallback]. [history]: recent turns from [_chatHistory].
  /// A dry run ([compareInterpreters]) never calls the model here.
  ///
  /// The reply is streamed into the live draft as it grows: each cumulative
  /// chunk is shown only while it still passes the same checks the final text
  /// must pass, so no unverified claim is ever displayed. A chunk that fails
  /// a check stops the stream and withdraws the draft; the final reply (or
  /// the fallback) is decided afterwards exactly as before.
  Future<String> _converse(
      String text, List<String> facts, String fallback, String goal,
      {List<Message> history = const []}) async {
    if (_dryRun) return fallback;
    if (engineInUse != engine.name || engine is RuleEngine) return fallback;
    if (loadEngine != null) {
      try {
        if (!await loadEngine!()) return fallback;
      } catch (_) {
        return fallback;
      }
    }
    if (_cancelled) throw ToolError('cancelled');
    final context = ['Goal: $goal', ...facts].join('\n');
    final p = Prompt(PromptKind.reply, text,
        tone: (await profile.get())?.tone,
        now: _now(),
        context: context,
        history: history,
        personalContext: buildPersonalContext(
            await profile.get() ?? const UserProfile(),
            await _personalMemories(text)));
    String? raw;
    try {
      if (_liveSent.isNotEmpty) _sendLive(''); // a replaced draft starts clean
      final grounding = '$context\n$text';
      raw = await _complete(p, onRaw: (chunk) {
        if (_cancelled) return;
        if (!_moodEmitted) {
          final reading = planStreamView(chunk).mood;
          if (reading != null) _emitMood(reading, source: 'model:reply');
        }
        final v = visibleRespondText(chunk);
        if (v == null || v.isEmpty) return;
        final next = _streamedDraft(
            v,
            (t) =>
                safeReply(t, grounding) &&
                !echoes(t, text) &&
                !echoes(t, _said));
        if (next == null) return;
        _sendLive(next);
        _diag['stream'] = next.isEmpty ? 'withheld' : 'reply';
      });
      if (raw == null) _diag['reply_budget'] = 'spent';
    } on PlatformException catch (e) {
      if (e.code == 'llama_cancelled') _cancelled = true;
    } on ModelCancellationException catch (e) {
      _diag['reply_model'] = 'busy_${e.result.name}'; // quarantined: fallback
    } catch (_) {}
    if (_cancelled) throw ToolError('cancelled');
    _diag['reply'] = 'fallback';
    if (raw == null) return fallback;
    try {
      final c = parseToolCall(raw);
      final r = c.args['text'];
      if (c.tool == 'respond' &&
          r is String &&
          safeReply(r, '$context\n$text') &&
          !echoes(r, text) &&
          !echoes(r, _said)) {
        _diag['reply'] = 'model';
        return r.trim();
      }
    } on ToolError {
      // not a plain reply: the deterministic text stands
    }
    return fallback;
  }

}
