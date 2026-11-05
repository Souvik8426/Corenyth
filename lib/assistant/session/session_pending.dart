part of '../session.dart';

extension _SessionPending on AssistantSession {
  // ---- typed pending interactions (applied only when a turn commits) ----
  // The time question is global (main chat key; old per-chat rows remain
  // readable). A "Which one?" belongs to the chat that asked it (key
  // `pick:<chat>`) and lives for its next turn, across restarts.

  Future<ClarifyDraft?> _draft() async {
    final repo = pending;
    final raw = repo == null
        ? _memDraft
        : await repo.get(ConversationRepo.mainChatId) ?? await repo.get(id);
    if (raw == null) return null;
    try {
      return ClarifyDraft.fromJson(
          Map<String, Object?>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return null; // unreadable draft: treated as none
    }
  }

  Future<void> _setDraft(ClarifyDraft d) async {
    final old = await _draft();
    if (old != null && old.title != d.title) {
      _note = '(I replaced the unfinished "${old.title}" with this one.)';
    }
    _changes.add(PendingChange.setDraft(d));
  }

  void _clearDraft() => _changes.add(const PendingChange.clearDraft());

  void _setPick(TargetPick p) => _changes.add(PendingChange.setPick(p));

  String get _pickKey => 'pick:$id';

  /// This chat's "Which one?" if still fresh. Reading it consumes it at
  /// commit (unless this turn asks again).
  Future<TargetPick?> _loadPick() async {
    final raw = pending == null ? _memPick : await pending!.get(_pickKey);
    if (raw == null) return null;
    _pickStored = true;
    try {
      final p = TargetPick.fromJson(
          Map<String, Object?>.from(jsonDecode(raw) as Map));
      if (p == null) return null;
      final age = _now().difference(p.askedAt);
      if (age > TargetPick.maxAge || age < const Duration(minutes: -1)) {
        return null;
      }
      return p;
    } catch (_) {
      return null;
    }
  }

  Future<void> _storePick(TargetPick? p) async {
    final raw = p == null ? null : jsonEncode(p.toJson());
    final repo = pending;
    if (repo == null) {
      _memPick = raw;
    } else if (raw == null) {
      await repo.clear(_pickKey);
    } else {
      await repo.put(_pickKey, raw);
    }
  }

  Future<void> _applyPending(List<PendingChange> changes) async {
    var pickSet = false;
    for (final c in changes) {
      if (c.draft != null) {
        final raw = jsonEncode(c.draft!.toJson());
        final repo = pending;
        if (repo == null) {
          _memDraft = raw;
        } else {
          await repo.put(ConversationRepo.mainChatId, raw);
        }
      } else if (c.pick != null) {
        await _storePick(c.pick);
        pickSet = true;
      } else if (c.clearDraft) {
        final repo = pending;
        if (repo == null) {
          _memDraft = null;
        } else {
          await repo.clear(ConversationRepo.mainChatId);
          if (id != ConversationRepo.mainChatId) await repo.clear(id);
        }
      }
    }
    if (_pickStored && !pickSet) await _storePick(null);
  }

  /// Settled without the model: "#3" for this chat's "which one?", a
  /// calculation, or a reply that only gives the pending question's time.
  Future<ToolCall?> _early(String text) async {
    for (final (id, c) in [
      (RouteId.pendingPick, await _pickRoute(text)),
    ]) {
      if (c != null) {
        _routeId = id;
        return c;
      }
    }
    final calc = _calcRoute(text);
    if (calc != null) {
      _routeId = RouteId.calculator;
      return calc;
    }
    final answer = await _pendingAnswerRoute(text);
    if (answer != null) _routeId = RouteId.pendingAnswer;
    return answer;
  }

  /// A reply to the "Which one?" this chat asked last turn.
  Future<ToolCall?> _pickRoute(String text) async {
    final pick = await _loadPick();
    final n = RegExp(r'^(?:#|number |task )?(\d+)$', caseSensitive: false)
        .firstMatch(text.trim());
    int? selected = n == null ? null : int.parse(n.group(1)!);
    if (pick != null &&
        selected == null &&
        pick.args['text'] is String &&
        !_isCommand(text) &&
        !hasCommandWord(text) &&
        !isQuestionLike(text) &&
        !isProgressUpdate(text) &&
        !looksLikeOutcome(text)) {
      final choices = <Task>[];
      for (final id in pick.ids) {
        final task = await taskRepo.get(id);
        if (task != null) choices.add(task);
      }
      final matches = named(choices, text);
      if (matches.length == 1) selected = matches.single.id;
      if (matches.length > 1) {
        _setPick(pick);
        return AssistantSession._say('Which one? Please give the full name or task number.');
      }
    }
    if (pick != null && selected != null) {
      final id = selected;
      if (pick.ids.contains(id)) {
        final said = pick.args['text'];
        if (said is! String) return _withId(pick, id, 'pick');
        final t = await taskRepo.get(id);
        if (t == null)
          return AssistantSession._say(
              'That task no longer exists, so I left everything as it was.');
        return switch (pick.tool) {
          'discuss' => await _discuss(t, said),
          'outcome' => await _recordOutcome(t, said),
          _ => await _applyDetails(t, said) ??
              AssistantSession._say("I couldn't read those details."),
        };
      }
      _setPick(pick);
      return AssistantSession._say(
          "That isn't one of ${pick.ids.map((i) => '#$i').join(', ')}. Which one?");
    }
    return null;
  }

  ToolCall? _calcRoute(String text) {
    final calc = calculate(text.trim());
    return calc == null ? null : AssistantSession._say(calc);
  }

  Future<ToolCall?> _pendingAnswerRoute(String text) async {
    final draft = await _draft();
    if (draft == null) return null;
    var answer = text;
    String? subject;
    // An event's time question may be answered with its topic too.
    final about = draft.day == null
        ? null
        : RegExp(
                r"^(.+?)[,;.]?\s+(?:and\s+)?(?:it'?s\s+|it is\s+)?about\s+(.+?)[.!]*$",
                caseSensitive: false)
            .firstMatch(text.trim());
    if (about != null && _fallback.isTimeAnswer(draft, about.group(1)!)) {
      answer = about.group(1)!;
      subject = about.group(2)!;
    }
    if (_fallback.isTimeAnswer(draft, answer)) {
      final c =
          await _answer(draft, _fallback.resolveClarify(draft, answer), answer);
      if (c != null && c.tool != 'respond') _subject = subject;
      return c;
    }
    return null;
  }

  /// Applies a clarification result: done (or cancelled) clears the draft.
  Future<ToolCall?> _answer(ClarifyDraft draft,
      ({Map<String, Object?> call, bool keep})? r, String answer) async {
    if (r == null) return null;
    if (!r.keep) _clearDraft();
    _evidence['title'] = 'pending';
    final words = _fallback.readWhen(answer).spans.map((s) => s.text);
    if (words.isNotEmpty) _evidence['time'] = 'answer: ${words.join(' | ')}';
    if (draft.time != null) _evidence['time'] ??= 'pending: ${draft.time}';
    return _call(r.call);
  }

}
