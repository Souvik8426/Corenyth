part of '../session.dart';

extension _SessionSemantic on AssistantSession {
  // ---- model-first semantic planning ----

  /// One grammar-constrained model call -> [Semantic] -> validated tool call.
  /// Null = no usable plan (rules take over; [lastFallbackReason] says why).
  /// The legacy interpreter uses plan-v1, the unified one plan-v2.
  Future<ToolCall?> _semantic(String text, Map<String, int> timing) async {
    var loaded = true;
    if (loadEngine != null) {
      try {
        loaded = await loadEngine!();
      } catch (_) {
        loaded = false;
      }
    }
    if (_cancelled) throw ToolError('cancelled');
    if (!loaded) {
      lastFallbackReason = 'the local model is not loaded';
      _diag['model'] = 'unavailable';
      _diag['fallback'] = 'not_loaded';
      return null;
    }
    final v2 = _mode == Interpreter.unified;
    final contract = v2 ? planContractV2 : promptContractVersion;
    final ctx = Stopwatch()..start();
    final open = await taskRepo.relevantTasks(text, cap: _taskCap);
    final draft = await _draft();
    final last = _lastTask == null ? null : await taskRepo.get(_lastTask!);
    // Only the user's own earlier words: assistant replies (old lists) never.
    final earlier = (await conversations.recent(id, n: 5))
        .where((m) =>
            m.role == 'user' &&
            m.content.trim() != text.trim() &&
            _safeHistorical(m.content))
        .map((m) =>
            m.content.length > 120 ? m.content.substring(0, 120) : m.content)
        .toList();
    // Context is global: the user's related words from any chat.
    final related = (await _related(text))
        .map((m) =>
            m.content.length > 120 ? m.content.substring(0, 120) : m.content)
        .where((m) => !earlier.contains(m))
        .toList();
    final p = Prompt(PromptKind.plan, text,
        now: _now(),
        contract: contract,
        // The most relevant tasks, listed by id: a stable order keeps the
        // KV-cached prefix valid from one message to the next.
        tasks: open.isEmpty
            ? '(none)'
            : [
                for (final t
                    in open.take(_taskCap).toList()
                      ..sort((a, b) => a.id.compareTo(b.id)))
                  _line(t),
                if (open.length > _taskCap)
                  '(and ${open.length - _taskCap} more)',
              ].join('\n'),
        context: [
          if (last != null && !last.done) 'Last task mentioned: ${_line(last)}',
          for (final m in earlier.reversed.take(2).toList().reversed)
            'Earlier user message: $m',
          for (final m in related.take(2))
            'Related earlier user message (any chat): $m',
        ].join('\n'),
        pending: draft == null
            ? null
            : '${draft.tool == 'create_reminder' ? 'reminder' : 'task'} '
                '"${draft.title}" still needs a time',
        // Profile (name, tone) stays in the KV-cached system prompt; the
        // memories picked for this message go in the user turn.
        memories: (await _personalMemories(text))
            .where(isUsefulPersonalMemory)
            .take(3)
            .toList(),
        tone: (await profile.get())?.tone,
        personalContext: buildPersonalContext(
            await profile.get() ?? const UserProfile(), const []));
    timing['context'] = ctx.elapsedMilliseconds;
    if (_cancelled) throw ToolError('cancelled');
    _diag['model'] = 'called';
    _diag['prompt'] = promptIdentity(contract);
    final Semantic s;
    try {
      // Streamed: the mood envelope (first field of the contract) is emitted
      // as soon as it completes, and a chat plan's reply prose flows into the
      // live draft while the plan is still generating. Only `chat` streams:
      // its reply is the answer itself and passes the same checks now that
      // the final text must pass later. Write/list/recall plans buffer —
      // their reply is a follow-up the app appends after its own exact
      // confirmation, and never a success claim (nothing has committed yet).
      final raw = await _complete(p, onRaw: (chunk) {
        if (_cancelled) return;
        final view = planStreamView(chunk);
        if (view.mood != null) {
          _emitMood(view.mood!, source: 'model:$contract');
        }
        if (view.intent != 'chat' || view.replyText == null) return;
        final next = _streamedDraft(
            view.replyText!,
            (t) =>
                safeReply(t, text) &&
                !echoes(t, text) &&
                !AssistantSession._groundless(t, open));
        if (next == null) return;
        _sendLive(next);
        _diag['stream'] = next.isEmpty ? 'withheld' : 'plan';
      });
      if (raw == null) {
        lastFallbackReason = 'the model was already asked this turn';
        _diag['fallback'] = 'model_budget';
        return null;
      }
      if (AssistantSession._logRaw) debugPrint('raw plan: $raw');
      s = parseSemantic(raw, version: v2 ? 2 : 1);
    } on PlatformException catch (e) {
      if (e.code == 'llama_cancelled' || _cancelled) {
        _cancelled = true;
        throw ToolError('cancelled');
      }
      if (e.code == 'prompt_too_long') return AssistantSession._say(AssistantSession.tooLongReply);
      lastFallbackReason = 'the local model failed (${e.code})';
      _diag['model'] = 'failed';
      _diag['fallback'] = 'native_${e.code}';
      return null;
    } on ModelCancellationException catch (e) {
      // Earlier optional work did not confirm cancellation in time: the
      // worker is quarantined (no overlapping native call), so this turn
      // uses rules. Recovery waits for that generation to actually end.
      if (_cancelled) throw ToolError('cancelled');
      lastFallbackReason = 'the local model was still busy';
      _diag['model'] = 'busy';
      _diag['fallback'] = 'model_cancel_${e.result.name}';
      return null;
    } on ToolError {
      lastFallbackReason = 'the model reply was not a valid plan';
      _diag['model'] = 'invalid';
      _diag['fallback'] = 'invalid_plan';
      return null;
    } catch (_) {
      lastFallbackReason = 'the local model failed';
      _diag['model'] = 'failed';
      _diag['fallback'] = 'engine_exception';
      return null;
    }
    if (_cancelled) throw ToolError('cancelled');
    _diag['intent'] = s.intent;
    _modelAuth = s.authorization;
    if (s.authorization != null) _diag['auth_model'] = s.authorization!;
    final c = await _act(s, text, open, draft);
    if (s.intent == 'list' &&
        c != null &&
        c.tool != 'list_tasks' &&
        c.tool != 'list_reminders' &&
        c.tool != 'briefing') {
      _modelLine = null;
      _diag['fallback'] = 'list_without_listing';
      return await _rules(text) ?? await _rulePlanCall(text);
    }
    final line = s.reply;
    if (c != null &&
        line != null &&
        c.tool == 'respond' &&
        _diag['clarify'] == 'event_time' &&
        isSafeFollowUp(line, text)) {
      _diag['reply'] = 'model_line';
      return AssistantSession._say('${c.args['text']} ${line.trim()}');
    }
    if (c != null && line != null && AssistantSession._writes.contains(c.tool)) {
      if (_diag['clarify'] != null) {
        _diag['line'] = 'clarify';
      } else if (!isSafeFollowUp(line, text)) {
        _diag['line'] = 'unsafe';
      } else {
        _modelLine = line.trim();
      }
    }
    if (c == null) {
      lastFallbackReason ??=
          'the model\'s reading (${s.intent}) did not fit your message';
      _diag['fallback'] ??= 'rejected_${s.intent}';
    }
    return c;
  }

  /// "#3 buy milk (due tomorrow (Thu 15 Oct) at 9:00 AM)": dates from SQLite.
  String _line(Task t) => '#${t.id} ${t.done ? '[done] ' : ''}${t.title}'
      '${t.dueAt == null ? '' : ' (due ${friendlyTime(t.dueAt!, _now())})'}'
      '${t.subject == null ? '' : ', about ${t.subject}'}';

  Future<void> _rememberTask(ToolCall c) async {
    if (c.tool == 'list_tasks') _lastTask = null;
    final id = c.args['id'];
    if (id is int && c.tool.endsWith('_task')) _lastTask = id;
    if (c.tool == 'create_task' || c.tool == 'create_reminder') {
      // The task this call is about: its explicit link, or the one pending task
      // with its title (a repeated reminder resolves to its existing task). A
      // standalone reminder (no preferences = no task) or an ambiguous title
      // clears the context; never "newest id", which may be unrelated.
      final link = c.args['task_id'];
      final standalone =
          c.tool == 'create_reminder' && tools.preferences == null;
      final same = standalone || link is int
          ? const <Task>[]
          : await taskRepo.byTitle(c.args['title'] as String);
      _lastTask = link is int
          ? link
          : same.length == 1
              ? same.single.id
              : null;
    }
  }

  /// The app's side of a semantic plan: every title/ref must come from the
  /// message, every date from the app's own parser, every id from SQLite.
  Future<ToolCall?> _act(
      Semantic s, String text, List<Task> open, ClarifyDraft? draft) async {
    final explicit = _fallback.fastRoute(text);
    final et = explicit?['type'] == 'tool' ? explicit!['tool'] as String : null;
    if (AssistantSession._ruleOnly.contains(et) ||
        (et == 'edit_task' &&
            (explicit!['arguments'] as Map).containsKey('title'))) {
      return null;
    }
    // A clear command the model filed as chat/list/recall: the rules handle it.
    bool command() =>
        _fallback.parseCreate(text) != null ||
        RuleEngine.doneRef(text) != null ||
        (_auth.kind == Authorization.request &&
            RegExp(r'^(?:please )?(?:delete|remove|mark|complete|move|push|postpone|change|rename|reschedule)\b',
                    caseSensitive: false)
                .hasMatch(text.trim()));
    // plan-v2: the model said "don't"/"only asking"/"what if" about a message
    // the app reads as an authorizing request. Its label never authorizes or
    // forbids alone: the plan is set aside and the deterministic rules,
    // which only act on fully recognized commands, decide.
    const doubtful = {'negated', 'question', 'hypothetical'};
    if (_mode == Interpreter.unified &&
        doubtful.contains(s.authorization) &&
        _auth.permitsWrite &&
        familyOf(AssistantSession._intentTool(s.intent)) != ActionFamily.read) {
      _diag['fallback'] = 'authorization_disagreement';
      lastFallbackReason =
          'the model read your message as ${s.authorization}, which did not match it';
      return null;
    }
    // A question about the user's own plans is answered from SQLite, never prose.
    final dataQuestion = !command() &&
        !RuleEngine.isNegated(text) &&
        (AssistantSession._dataQuestion.hasMatch(text) || _rangeIn(text) != null) &&
        RegExp(r"\b(?:what|which|any|anything|show|list|tell|pending|left|got)\b|\?",
                caseSensitive: false)
            .hasMatch(text);
    switch (s.intent) {
      case 'chat':
        if (command()) return null;
        // "did I miss anything", "am I behind on anything": the overdue list.
        if (AssistantSession._overdueQuestion.hasMatch(text) && !RuleEngine.isNegated(text)) {
          _header = rangeLabel('overdue');
          return ToolCall('list_tasks', rangeArgs('overdue', _now()));
        }
        if (dataQuestion) {
          _header = rangeLabel(_rangeIn(text) ?? 'all');
          return ToolCall(
              'list_tasks', rangeArgs(_rangeIn(text) ?? 'all', _now()));
        }
        final r = s.reply;
        final planned =
            r != null && !AssistantSession._groundless(r, open) && !echoes(r, text) ? r : null;
        // One call per turn: the plan already carries the toned answer.
        if (planned != null && safeReply(planned, text)) {
          _diag['reply'] = 'model';
          return AssistantSession._say(_corePolicy.concise(planned.trim(), text));
        }
        final said = await _converse(text, const [], planned ?? '',
            'Small talk or a general message. Reply naturally to what the user actually said, in one or two sentences.',
            history: await _chatHistory());
        if (said.isNotEmpty && !AssistantSession._groundless(said, open)) {
          return AssistantSession._say(_corePolicy.concise(said, text));
        }
        return planned == null ? null : AssistantSession._say(planned);
      case 'list':
        if (command()) return null;
        // "which reminders are coming up", "got any alarms lined up": the
        // reminders, not the task list.
        if (AssistantSession._reminderNoun.hasMatch(text) && !RuleEngine.isNegated(text)) {
          return ToolCall('list_reminders', const {});
        }
        if (!dataQuestion) {
          final read = _fallback.plan(text);
          if (read['type'] == 'tool' && read['tool'] == 'search_memory') {
            return _recall(text);
          }
          // The model heard a request to see plans in words the app's own
          // patterns miss ("gimme a rundown of tmrw", "did i miss anything").
          // Listing only reads, so that reading stands unless the user said
          // not to.
          if (!RuleEngine.isNegated(text)) {
            final range = _rangeIn(text) ?? RuleEngine.agendaRange(text);
            _header = rangeLabel(range);
            return ToolCall('list_tasks', rangeArgs(range, _now()));
          }
          final r = s.reply;
          if (r != null &&
              safeReply(r, text) &&
              !AssistantSession._groundless(r, open) &&
              !echoes(r, text)) {
            _diag['reply'] = 'model';
            return AssistantSession._say(r.trim());
          }
          return AssistantSession._say(await _converse(text, const [], 'Tell me a little more.',
              'Respond to the actual message. No tasks, reminders or actions were requested.',
              history: await _chatHistory()));
        }
        // The day the user said wins over a missing or different model range.
        final range = _rangeIn(text) ?? RuleEngine.agendaRange(text);
        _header = rangeLabel(range);
        return ToolCall('list_tasks', rangeArgs(range, _now()));
      case 'recall':
        if (command()) return null;
        if (_auth.kind == Authorization.hypothetical) {
          final relevant = named(open, text);
          final fallback = relevant.isEmpty
              ? "I haven't changed anything. Tell me if you decide to make that change."
              : '${relevant.map((t) => t.title).join(', ')} is still on your list. Let me know if you decide to change it.';
          return AssistantSession._say(await _converse(
              text,
              relevant.map(_line).toList(),
              fallback,
              'Discuss this possibility briefly. The user has not decided; no action was taken.',
              history: await _chatHistory()));
        }
        if (RuleEngine.isGeneralKnowledge(text)) {
          return AssistantSession._say(
              "I can't look that up offline, and I'd rather not guess.");
        }
        if (!isQuestionLike(text) &&
            !RegExp(r'\bremember\b', caseSensitive: false).hasMatch(text))
          return null;
        return _recall(text);
      case 'cancel_pending':
        if (draft == null) return null;
        _clearDraft();
        return AssistantSession._say('Okay, I dropped "${draft.title}".');
      case 'answer_pending':
        if (draft == null) return null;
        final w = s.when;
        final answer = w != null && _mentioned(w, text) ? w : text;
        final r = _fallback.resolveClarify(draft, answer);
        return await _answer(draft, r, answer) ?? AssistantSession._say(draft.prompt);
      case 'create_task':
      case 'create_reminder':
        return _create(s, text);
      case 'complete':
      case 'delete':
      case 'postpone':
        return _change(s, text, open);
      // plan-v2 follow-through intents: the same handlers as the
      // deterministic routes, reached when those did not recognize it.
      case 'progress':
      case 'outcome':
      case 'details':
        if (_mode != Interpreter.unified || !_auth.permitsReport) return null;
        return _followIntent(s, text, open);
    }
    return null;
  }

  /// The deterministic plan as a call. A memory lookup goes through [_recall],
  /// which also checks earlier chats; a bare search_memory call would not.
  Future<ToolCall> _rulePlanCall(String text) async {
    final plan = _fallback.plan(text);
    if (plan['type'] == 'tool' && plan['tool'] == 'search_memory') {
      return _recall(text);
    }
    return parseToolCall(jsonEncode(plan));
  }

  Future<ToolCall> _recall(String text) async {
    final hits = await memory.search(text, limit: 3);
    if (hits.isNotEmpty) return ToolCall('search_memory', {'query': text});
    final related = await _related(text);
    if (related.isNotEmpty) {
      return AssistantSession._say(
          'Earlier you said: ${related.map((m) => AssistantSession._cut(m.content)).join('; ')}');
    }
    return AssistantSession._say('I have nothing stored about that.');
  }

  /// plan-v2 progress / outcome / details: the target must be named in the
  /// message (every word of the model's ref) among the tasks that intent
  /// applies to; meeting details are read by the app's own parser.
  Future<ToolCall?> _followIntent(
      Semantic s, String text, List<Task> open) async {
    final ref = s.ref ?? s.title;
    final asked = await taskRepo.awaitingAnswers();
    final pool = switch (s.intent) {
      'outcome' => [
          for (final t in asked)
            if (t.awaiting == TaskRepo.outcomeQuestion) t
        ],
      'details' => [
          for (final t in asked)
            if (t.awaiting == TaskRepo.details && !t.done && t.dueAt != null) t
        ],
      _ => open,
    };
    if (pool.isEmpty) return null;
    List<Task> l;
    if (ref != null) {
      if (!AssistantSession._grounded(ref, text, all: true)) return null;
      l = await _matching(ref, pool);
      if (l.isEmpty) l = named(pool, ref);
    } else {
      l = pool.length == 1 ? pool : named(pool, text);
    }
    if (l.isEmpty) return null;
    if (l.length > 1) {
      return _ask(s.intent == 'progress' ? 'discuss' : s.intent, l, text,
          'Which one do you mean?');
    }
    final t = l.single;
    _evidence['target'] = 'model_ref';
    return switch (s.intent) {
      'progress' => _discuss(t, text),
      'outcome' => _recordOutcome(t, text),
      _ => _applyDetails(t, text),
    };
  }

  Future<ToolCall?> _create(Semantic s, String text) async {
    final clauses = text.split(RegExp(r'(?<=[.!?;,])\s+|[\r\n]+'));
    final titleWords = keyWords(s.title ?? '');
    final matching = clauses
        .where((clause) =>
            titleWords.isNotEmpty && keyWords(clause).containsAll(titleWords))
        .toList();
    final guardText = matching.length == 1 ? matching.single : text;
    // Reminder vs silent task follows what the user said: "remind me…" always
    // notifies; a plain statement never gets an alarm it didn't ask for.
    if (RegExp(r'^(?:please )?(?:(?:can|could|would|will) (?:you|u) )?(?:book|order|send|pay|call|email)\b',
                caseSensitive: false)
            .hasMatch(text.trim()) &&
        !RegExp(r'\b(?:task|remind|reminder|need to|have to)\b',
                caseSensitive: false)
            .hasMatch(text)) {
      return AssistantSession._say(
          "I can't do that action for you. Would you like me to save it as a task or reminder?");
    }
    final asked = _fallback.parseCreate(text)?.tool == 'create_reminder' ||
        AssistantSession._notifyAsk.hasMatch(text);
    final reminder = asked;
    if ((guardText == text && s.negated) || RuleEngine.isNegated(guardText)) {
      return AssistantSession._say("Okay, I won't save that.");
    }
    if (RuleEngine.isQuestionOrNegated(guardText))
      return null; // "How do I buy milk?"
    if (RuleEngine.isTentative(guardText)) {
      _diag['clarify'] = 'tentative';
      return AssistantSession._say("I haven't set anything since that sounds undecided. "
          'If you want a reminder, tell me what and when.');
    }
    if (guardText != text) {
      text = guardText;
      _auth = readAuthorization(guardText);
    }
    final parsed = _fallback.parseCreate(text);
    final title = parsed != null
        ? (parsed.note == RuleEngine.conflict
            ? parsed.title
                .replaceFirst(RegExp(r'^the ', caseSensitive: false), '')
            : parsed.title)
        : RuleEngine.cleanTitle(_fallback.readWhen(s.title ?? '').rest);
    if (RegExp(r'^(?:it|that|this)(?: later)?$', caseSensitive: false)
        .hasMatch(title)) {
      _diag['clarify'] = 'target';
      return AssistantSession._say('What should I remind you about?');
    }
    // Every content word of the title as the user said it: no invented object.
    if (title.isEmpty || !AssistantSession._grounded(title, text, all: true)) return null;
    _evidence['title'] = 'said';
    // Two commitments in the message: save both or neither, never a subset.
    if (RuleEngine.isMulti(title) || RuleEngine.isMulti(text)) {
      return AssistantSession._say(RuleEngine.multiReply(title));
    }
    // Overrides only when the message talks about them; explicit words win.
    final (mult, follow, _) = RuleEngine.extractFlags(text);
    final multiple = mult ??
        (RegExp(r'\b(?:multiple|several|times|alerts?|again)\b',
                    caseSensitive: false)
                .hasMatch(text)
            ? s.multiple
            : null);
    final followUp = follow ??
        (RegExp(r'\bfollow', caseSensitive: false).hasMatch(text)
            ? s.followUp
            : null);
    final tool = reminder ? 'create_reminder' : 'create_task';
    // Asking for one value keeps everything else that was understood.
    Future<ToolCall> askTime(String code, String lead,
        {String? time, DateTime? day}) async {
      _diag['clarify'] = code;
      final d = ClarifyDraft(
          tool: tool,
          title: title,
          multiple: multiple,
          followUp: followUp,
          time: time,
          day: day?.toIso8601String().substring(0, 10));
      await _setDraft(d);
      return AssistantSession._say('$lead${d.prompt}');
    }

    // The same resolver as the rules, over the whole message: the model's
    // time words never outvote other time words the user also said.
    final whole = _fallback.readWhen(text);
    if (whole.conflict) {
      return askTime('temporal_conflict',
          '${RuleEngine.timeProblem(whole, reminder, _now())} ');
    }
    // Whole-message words the app can't schedule ("in 2 weeks", "every
    // week", "30 February", or time words left over after the parts it did
    // read) outrank any valid-looking subset the model copied.
    if (whole.unsupported ||
        (whole.at != null && RuleEngine.hasUnsupportedDate(whole.rest))) {
      return askTime('unsupported_date', "I can't schedule that date yet. ");
    }
    DateTime? at;
    String? note;
    var reading = whole;
    final w = s.when;
    if (whole.at != null) {
      at = whole.at;
      note = whole.note;
      _evidence['time'] = whole.spans.isEmpty
          ? 'resolved'
          : whole.spans.map((s) => s.text).join(' | ');
    } else if (w != null && _mentioned(w, text)) {
      final r = _fallback.resolveWhen(w);
      if (!r.ok) {
        // Words the app can't schedule: ask, keep the item, never guess.
        return askTime(
            'model_when_unresolved', 'I couldn\'t read "$w" as a time. ');
      }
      at = r.at;
      note = r.note;
      reading = _fallback.readWhen(w);
      _evidence['time'] = 'model_copied: $w';
    } else if (RuleEngine.hasUnsupportedDate(text)) {
      return askTime('unsupported_date', "I can't schedule that date yet. ");
    }
    final anchor = reading.anchor;
    final deadline = at != null &&
        reading.role == TemporalRole.deadline &&
        (anchor?.relation == TemporalRelation.within ||
            anchor?.relation == TemporalRelation.before);
    if (deadline && AssistantSession._pronounTitle.hasMatch(title)) {
      // "Finish this within 10 minutes": a deadline for something unnamed.
      _diag['clarify'] = 'deadline_target';
      return AssistantSession._say('What needs to be done ${anchor!.text}? Tell me and I can '
          'add it as a task or set a reminder.');
    }
    // "I have a meeting tomorrow": a day but no time for an event the user
    // only mentioned. Ask its time (the day is kept) instead of guessing 9 AM.
    if (!reminder &&
        at != null &&
        reading.dated &&
        !reading.timed &&
        (isEventTitle(title) ||
            RegExp(r'^call(?: with .+)?$', caseSensitive: false)
                .hasMatch(title.trim()))) {
      return askTime('event_time', '', day: at);
    }
    final problem = RuleEngine.timeProblem(reading, reminder, _now());
    if (problem != null) return askTime('deadline_not_alert', '$problem ');
    if (at == null && !reminder) return ToolCall(tool, {'title': title});
    if (at == null || at.isBefore(_now())) {
      return askTime(at == null ? 'no_time_found' : 'time_passed',
          at == null ? '' : '${friendlyTime(at, _now())} has already passed. ',
          time: at == null || note != null ? null : RuleEngine.clockText(at));
    }
    if (note != null) _note = _note == null ? note : '$note $_note';
    return ToolCall(
        tool,
        reminder
            ? {
                'title': title,
                'at': at,
                if (multiple != null) 'multiple': multiple,
                if (followUp != null) 'follow_up': followUp,
              }
            : {'title': title, 'due': at});
  }

  Future<ToolCall?> _change(Semantic s, String text, List<Task> open) async {
    if (s.negated || RuleEngine.isQuestionOrNegated(text)) {
      return AssistantSession._say("I didn't change anything.");
    }
    // "Add a task to clean my room" never completes or deletes: the user's
    // words ask to create, so this plan is unsafe, not merely different.
    if (s.intent != 'postpone' && _fallback.parseCreate(text) != null) {
      return null;
    }
    final tool = const {
      'complete': 'complete_task',
      'delete': 'delete_task',
      'postpone': 'edit_task'
    }[s.intent]!;
    var ref = s.ref ?? s.title;
    var id = ref == null
        ? null
        : RegExp(r'^#?(\d+)(?:\s+\D.*)?$').firstMatch(ref.trim());
    var modelPicked = false;
    // The prompt offers "#id" from Current tasks: a model-picked id stands
    // when that task's own words are in the message, as if the user named it.
    if (id != null && !RegExp('(?:#|\\b)${id.group(1)}\\b').hasMatch(text)) {
      final picked =
          open.where((t) => t.id == int.parse(id!.group(1)!)).toList();
      if (picked.length != 1 || !AssistantSession._grounded(picked.single.title, text)) {
        return null;
      }
      ref = picked.single.title;
      id = null;
      modelPicked = true;
    }
    // Words must come from the message.
    if (ref != null &&
        id == null &&
        !modelPicked &&
        !AssistantSession._grounded(ref, text, all: true)) {
      return null;
    }
    Duration? shift;
    Map<String, Object?> args = const {};
    if (tool == 'edit_task') {
      final w = s.when;
      // The user's own "by 30 minutes" wins when the model reworded it.
      final by = RegExp(r'^.*\b(?:by|for)\s+(.+?)[.!?]*$', caseSensitive: false)
          .firstMatch(text);
      final d = (w == null || !_mentioned(w, text)
              ? null
              : RuleEngine.parseDuration(w)) ??
          (by == null ? null : RuleEngine.parseDuration(by.group(1)!));
      final r = w == null || d != null || !_mentioned(w, text)
          ? null
          : _fallback.resolveWhen(w);
      if (d != null) {
        shift = d;
      } else if (r != null && r.ok && r.at!.isAfter(_now())) {
        args = {'due': r.at};
      } else {
        return AssistantSession._say(
            'When should I move it to? Try "by 2 hours" or "tomorrow at 5pm".');
      }
      _evidence['time'] = 'model_copied: $w';
    }
    final pronoun = ref != null &&
        RegExp(r'^(?:it|that|this|that one|this one|the last one|the same one)$',
                caseSensitive: false)
            .hasMatch(ref.trim());
    final last = pronoun ? open.where((t) => t.id == _lastTask).toList() : null;
    var l = last ?? (ref == null ? <Task>[] : await _matching(ref, open));
    // A ref that names nothing ("postpone"): the task the message names.
    if (l.isEmpty && !modelPicked && id == null) {
      final said = named(open, text);
      if (said.length == 1) l = said;
    }
    final pick = TargetPick(
        tool: tool,
        args: args,
        shift: shift,
        ids: [for (final t in l) t.id],
        askedAt: _now());
    if (l.length == 1) {
      return _withId(pick, l.first.id,
          pronoun ? 'pronoun' : (id != null ? 'typed' : 'named'));
    }
    final choices = l.isEmpty ? open : l;
    if (choices.isEmpty) return AssistantSession._say("You don't have any pending tasks.");
    _setPick(TargetPick(
        tool: tool,
        args: args,
        shift: shift,
        ids: [for (final t in choices) t.id],
        askedAt: _now()));
    _lastTask = null;
    return AssistantSession._say(
        '${l.isEmpty ? 'I couldn\'t find ${ref == null ? 'which task you mean' : 'a pending task matching "$ref"'}.' : 'Several tasks match "$ref":'}\n'
        '${choices.take(_taskCap).map((t) => '#${t.id} ${t.title}${t.dueAt == null ? '' : ' (${friendlyTime(t.dueAt!, _now())})'}').join('\n')}\n'
        'Which one? Say the number, e.g. #${choices.first.id}.');
  }

}
