part of '../session.dart';

extension _SessionMood on AssistantSession {
  /// Dispatches optional mood work with captured immutable inputs, completely
  /// independent of foreground turn settlement and mutable turn budget.
  void _dispatchOptionalMood({
    required String text,
    required String opId,
    required int? userRowId,
    required void Function(TurnMood mood)? moodSink,
    required int schedulerTurn,
  }) {
    final epoch = _generationEpoch;
    final now = _turnNow ?? _now();
    // Same contract as this session's plan prompt, so the mood job's system
    // block is byte-identical to the next plan turn's (KV reuse).
    final contract =
        _mode == Interpreter.unified ? planContractV2 : promptContractVersion;
    lastOptionalMoodJob = _runOptionalMood(
      text: text,
      opId: opId,
      userRowId: userRowId,
      moodSink: moodSink,
      now: now,
      contract: contract,
      epoch: epoch,
      schedulerTurn: schedulerTurn,
    );
  }

  /// One mood-only plan generation: the first valid envelope is accepted,
  /// shown and saved exactly once; anything after preemption, cancel or
  /// close is dropped, and a stale job never touches the newer turn's
  /// diagnostics.
  Future<void> _runOptionalMood({
    required String text,
    required String opId,
    required int? userRowId,
    required void Function(TurnMood mood)? moodSink,
    required DateTime now,
    required String contract,
    required int epoch,
    required int schedulerTurn,
  }) async {
    bool stale() => _cancelled || epoch != _generationEpoch || _closeRequested;
    if (stale()) return;
    try {
      // Read once: tone and personal context come from the same snapshot,
      // derived exactly as the coordinator's plan prompt derives them.
      final row = await profile.get();
      final user = row ?? const UserProfile();
      if (stale()) return;
      // The coordinator's plan layout (tasks '(none)' is in-distribution);
      // only the grammar differs, ending after the envelope.
      final p = Prompt(PromptKind.plan, text,
          now: now,
          contract: contract,
          tasks: '(none)',
          tone: row?.tone,
          personalContext: buildPersonalContext(user, const []),
          moodOnly: true);
      MoodReading? accepted;
      Future<void>? save;
      // Optional priority on the shared scheduler: any newer turn (this or
      // another session) or foreground call preempts it; a stale token is
      // dropped before it reaches the engine.
      final outcome = await models.runWithOutcome(p, ModelPriority.optional,
          engine: engine, turn: schedulerTurn, onRaw: (chunk) {
        if (accepted != null || stale()) return;
        final reading = planStreamView(chunk).mood;
        if (reading == null) return;
        accepted = reading;
        moodSink?.call(TurnMood(
          source: 'model:mood',
          conversationId: id,
          turnId: opId,
          generationId: '$opId/optional_mood',
          emotion: reading.mood == null
              ? null
              : MascotEmotion(reading.mood!, reading.intensity),
          confidence: reading.confidence,
          messageRowId: userRowId,
        ));
        final repo = moods;
        if (repo != null && userRowId != null) {
          save = repo
              .save(
                messageId: userRowId,
                chatId: id,
                source: 'model:mood',
                mood: reading.mood?.name,
                intensity: reading.intensity,
                confidence: reading.confidence,
              )
              .catchError((_) {});
        }
      });
      await save;
      if (stale() || outcome.status != ModelRunStatus.completed) return;
      final got = accepted;
      _diag['mood'] =
          got == null ? 'none' : '${got.mood?.name ?? 'unknown'}(model:mood)';
      _diag['model_calls'] = '${_budget.plan}p${_budget.reply}r+mood';
      lastDiagnostics = Map.unmodifiable(_diag);
    } on PlatformException {
      // preempted or failed: optional work ends silently
    } catch (_) {}
  }

}
