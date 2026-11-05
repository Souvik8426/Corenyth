part of '../session.dart';

extension _SessionBatch on AssistantSession {
  String get _batchKey => 'batch:$id';

  Future<Map<String, Object?>?> _loadBatch() async {
    final raw = pending == null ? _memBatch : await pending!.get(_batchKey);
    if (raw == null) return null;
    try {
      final draft = Map<String, Object?>.from(jsonDecode(raw) as Map);
      final at = DateTime.parse(draft['asked_at'] as String);
      final age = _now().difference(at);
      if (age > const Duration(minutes: 30) ||
          age < const Duration(minutes: -1)) {
        return null;
      }
      final items = draft['items'];
      if (items is! List || items.isEmpty || items.length > 20) return null;
      for (final item in items) {
        if (item is! Map ||
            item['index'] is! int ||
            item['arguments'] is! Map ||
            !const {
              'create_task',
              'create_reminder',
              'create_daily',
            }.contains(item['tool'])) {
          return null;
        }
      }
      return draft;
    } catch (_) {
      return null;
    }
  }

  Future<void> _storeBatch(String? raw) async {
    if (pending == null) {
      _memBatch = raw;
    } else if (raw == null) {
      await pending!.clear(_batchKey);
    } else {
      await pending!.put(_batchKey, raw);
    }
  }

  /// Batch interpretation never hands the combined text to follow-through or
  /// inference. The preview is staged here and persisted only on commit.
  Future<ToolCall?> _batchRoute(String text) async {
    final draft = await _loadBatch();
    _batchTouched = true; // every non-confirming turn consumes an old draft
    _batchUpdate = null;
    if (draft != null) {
      final answer = text.trim().toLowerCase().replaceAll(
            RegExp(r'[.!]+$'),
            '',
          );
      if (const {'no', 'cancel'}.contains(answer)) {
        _batchHandled = true;
        _diag['batch'] = 'discard';
        return AssistantSession._say('Okay, I discarded that batch. Nothing added.');
      }
      final all = const {'yes', 'add all'}.contains(answer);
      final subset = RegExp(
        r'^(only|drop)\s+(\d+(?:(?:\s*(?:,|and)\s*|\s+)\d+)*)$',
      ).firstMatch(answer);
      if (all || subset != null) {
        _batchHandled = true;
        final items = [
          for (final value in draft['items'] as List)
            Map<String, Object?>.from(value as Map),
        ];
        final selected = subset == null
            ? <int>{}
            : {
                for (final m in RegExp(r'\d+').allMatches(subset.group(2)!))
                  int.parse(m.group(0)!),
              };
        final valid = {for (final item in items) item['index'] as int};
        if (!valid.containsAll(selected)) {
          _batchUpdate = jsonEncode(draft);
          return AssistantSession._say('Choose item numbers from the preview, or say "no".');
        }
        final chosen = [
          for (final item in items)
            if (all ||
                (subset!.group(1) == 'drop'
                    ? !selected.contains(item['index'])
                    : selected.contains(item['index'])))
              item,
        ];
        if (chosen.isEmpty) return AssistantSession._say('Nothing selected. Nothing added.');
        _diag['batch'] = 'commit';
        return ToolCall('create_batch', {'items': chosen});
      }
    }
    final batch = readBatch(text);
    if (batch == null) return null;
    _batchHandled = true;
    _diag['batch'] = 'preview';
    _memoryEffect = null;
    if (batch.items.length > maxBatchItems) {
      return AssistantSession._say('Please send up to 10 at a time. Nothing added.');
    }
    final creates = <Map<String, Object?>>[];
    final rows = <String>[], tracked = <String>[], skipped = <String>[];
    final remindAll = RegExp(
      r'^\s*(?:[#*_]\s*)*remind me about these\b',
      caseSensitive: false,
    ).hasMatch(text);
    void add(ToolCall call, String label) {
      final index = creates.length + 1;
      creates.add({
        'index': index,
        'tool': call.tool,
        'arguments': call.args.map(
          (key, value) => MapEntry(
            key,
            value is DateTime ? value.toIso8601String() : value,
          ),
        ),
      });
      rows.add('$index. ${call.args['title']}$label');
    }

    for (final item in batch.items) {
      final said = item.text;
      final auth = readAuthorization(said);
      String? reason;
      if (auth.kind == Authorization.negated ||
          (RuleEngine.isNegated(said) && !isProgressUpdate(said))) {
        reason = 'negated';
      } else if (auth.kind == Authorization.hypothetical ||
          RuleEngine.isTentative(said)) {
        reason = 'undecided';
      } else if (auth.kind == Authorization.question ||
          isQuestionLike(said) ||
          RegExp(
            r'\bwaiting for your answer\b',
            caseSensitive: false,
          ).hasMatch(said)) {
        reason = 'a question, not a task';
      }
      if (reason != null) {
        final label = said.replaceFirst(
            RegExp(r'\s*[-—–]\s*waiting for your answer\b',
                caseSensitive: false),
            ' is waiting for your answer');
        skipped.add('$label ($reason)');
        continue;
      }
      final matches = named(
        (await taskRepo.relevantTasks(said)).where((task) => !task.done),
        said,
      );
      if (matches.isNotEmpty) {
        final label = said.replaceFirst(
            RegExp(r'\s*[-—–]\s*already tracked\b.*$', caseSensitive: false),
            '');
        tracked.add(
          '$label (${matches.map((t) => '#${t.id} ${t.title}').join(', ')})',
        );
        continue;
      }
      if (isProgressUpdate(said) ||
          RegExp(
            r'\b(?:already tracked|waiting (?:on|for))\b|\b(?:is|was|have|has) (?:completed|finished|done)\b',
            caseSensitive: false,
          ).hasMatch(said)) {
        skipped.add('$said (status note)');
        continue;
      }
      // One daily bullet may name two clocks. Give the existing daily reader
      // one clock at a time; retain its date cutoff and title for each entry.
      final dailyCue = RegExp(
        r'\b(?:daily|every day|each day)\b',
        caseSensitive: false,
      );
      if (dailyCue.hasMatch(said)) {
        final cutoff = RegExp(
              Temporal.untilLead,
              caseSensitive: false,
            ).firstMatch(said)?.start ??
            said.length;
        final clocks = RegExp(
          r'\b\d{1,2}(?::\d{2})?\s*(?:am|pm)\b',
          caseSensitive: false,
        ).allMatches(said.substring(0, cutoff)).toList();
        final schedules = <ToolCall>[];
        String? problem;
        for (var i = 0; i < (clocks.isEmpty ? 1 : clocks.length); i++) {
          var one = said;
          if (clocks.length > 1) {
            one = one.replaceRange(
              clocks.first.start,
              clocks.last.end,
              clocks[i].group(0)!,
            );
          }
          one = one
              .replaceAll(
                RegExp(r'\band\b(?=\s*(?:$|until|till))', caseSensitive: false),
                '',
              )
              .replaceAll('—', ' ')
              .trim();
          final daily = _fallback.parseDaily(one);
          final schedule = daily?.schedule;
          if (schedule == null) {
            problem = daily?.problem ?? 'tell me this one in your own words';
            break;
          }
          final title = RuleEngine.cleanTitle(
            _fallback.parseCreate(schedule.rest)?.title ?? schedule.rest,
          );
          if (keyWords(title).isEmpty) {
            problem = 'tell me this one in your own words';
            break;
          }
          schedules.add(
            ToolCall('create_daily', {
              'title': title,
              'minute': schedule.hour * 60 + schedule.minute,
              'until': schedule.until,
            }),
          );
        }
        if (problem != null) {
          skipped.add('$said ($problem)');
        } else {
          for (final call in schedules) {
            final minute = call.args['minute'] as int;
            final hour = minute ~/ 60;
            add(
              call,
              ' — daily at ${hour % 12 == 0 ? 12 : hour % 12}:'
              '${(minute % 60).toString().padLeft(2, '0')} ${hour < 12 ? 'AM' : 'PM'}',
            );
          }
        }
        continue;
      }
      // "until Nov 19" is a task deadline, not a recurrence or an alert.
      final normalized = said.replaceAll('—', ' ').replaceAll('–', ' ');
      final until = Temporal.dateIn(normalized, _now(), Temporal.untilLead);
      final input =
          (until?.date == null ? normalized : until!.rest).replaceFirst(
        RegExp(
          r'^(?:please\s+)?(?:notify|alert|ping|nudge) me\s+(?:to |about )?',
          caseSensitive: false,
        ),
        'remind me to ',
      );
      final parsed = _fallback.parseCreate(input);
      final when = Temporal.read(input, _now());
      final title = RuleEngine.cleanTitle(parsed?.title ?? when.rest);
      final action = parsed != null ||
          RegExp(
            r'^(?:buy|call|email|text|pay|book|send|pick up|clean|submit|visit|meet|go|finish|write|cook|wash|post|dispose)\b',
            caseSensitive: false,
          ).hasMatch(title);
      final datedLabel =
          batch.explicit && (when.at != null || until?.date != null);
      final reminder = remindAll ||
          parsed?.tool == 'create_reminder' ||
          AssistantSession._reminderWord.hasMatch(said);
      if ((!action && !datedLabel) ||
          title.isEmpty ||
          keyWords(title).isEmpty ||
          when.conflict ||
          when.unsupported ||
          parsed?.unsupported == true ||
          (reminder && (when.at == null || !when.at!.isAfter(_now())))) {
        skipped.add('$said (tell me this one in your own words)');
        continue;
      }
      final at = until?.date ?? when.at;
      add(
        ToolCall(reminder ? 'create_reminder' : 'create_task', {
          'title': title,
          if (reminder) 'at': when.at,
          if (!reminder && at != null) 'due': at,
        }),
        at == null
            ? ''
            : until?.date != null
                ? ' — until ${shortDate(at)}'
                : when.timed
                    ? ' — ${at.year == _now().year && at.month == _now().month && at.day == _now().day ? 'today' : shortDate(at)} '
                        '${at.hour % 12 == 0 ? 12 : at.hour % 12}:'
                        '${at.minute.toString().padLeft(2, '0')} ${at.hour < 12 ? 'AM' : 'PM'}'
                    : ' — due ${shortDate(at)}',
      );
    }
    if (creates.isNotEmpty) {
      _batchUpdate = jsonEncode({
        'asked_at': _now().toIso8601String(),
        'items': creates,
      });
      _clearDraft();
    }
    return AssistantSession._say(
      [
        'I found ${batch.items.length} items.${rows.isEmpty ? '' : " I'll add:"}',
        ...rows,
        if (tracked.isNotEmpty) 'Already tracked: ${tracked.join('; ')}',
        if (skipped.isNotEmpty) 'Not added: ${skipped.join('; ')}',
        if (rows.isNotEmpty)
          'Say "yes" to add all ${rows.length}, '
              '"${rows.length >= 3 ? 'only 1 and 3' : 'only 1'}", or "no".',
        if (rows.isNotEmpty && !batch.explicit)
          'Use "only N" to add one at a time.',
      ].join('\n'),
    );
  }

}
