part of '../session.dart';

extension _SessionHistory on AssistantSession {
  /// The last few turns of this chat for a prose reply, this turn excluded.
  /// Check-ins and replies listing tasks stay out: task facts come from SQLite.
  Future<List<Message>> _chatHistory() async {
    try {
      final l = await conversations.recent(id, n: 7);
      if (l.isNotEmpty &&
          l.last.role == 'user' &&
          l.last.content.trim() == _said) {
        l.removeLast();
      }
      return [
        for (final m in l)
          if (m.role == 'user' &&
              m.content.trim() != _said &&
              _safeHistorical(m.content))
            Message(m.role, AssistantSession._cut(m.content))
      ];
    } catch (_) {
      return const [];
    }
  }

  /// "That was dumb, give a proper reply to my previous prompt": the last
  /// reply missed, so answer the user's earlier message again (no writes).
  Future<ToolCall> _complaint() async {
    String? earlier;
    try {
      final l = await conversations.recent(id, n: 12);
      var skipped = false;
      for (final m in l.reversed) {
        if (m.role != 'user') continue;
        if (!skipped && m.content.trim() == _said) {
          skipped = true;
          continue;
        }
        if (!isComplaint(m.content)) {
          earlier = m.content.trim();
          break;
        }
      }
    } catch (_) {}
    if (earlier == null) {
      return AssistantSession._say("Sorry, that wasn't helpful. What would you like me to do? "
          'I can add tasks, set reminders, or go over your plans.');
    }
    final last = _lastTask == null ? null : await taskRepo.get(_lastTask!);
    final t = last != null && named([last], earlier).isNotEmpty ? last : null;
    final String fallback;
    if (t == null) {
      fallback =
          'Sorry, that reply missed the point. About "${AssistantSession._cut(earlier)}": '
          'should I make it a task or a reminder, or did you just want to talk it through?';
    } else if (t.done) {
      fallback =
          'Sorry, that reply missed the point. #${t.id} ${t.title} is marked done'
          '${t.outcome == null ? '' : ', and I noted: ${AssistantSession._cut(t.outcome!)}'}. '
          'Want a reminder to follow up on it later?';
    } else {
      fallback =
          'Sorry, that reply missed the point. About #${t.id} ${t.title}: '
          'should I mark it done, or move it to another day?';
    }
    return AssistantSession._say(await _converse(
        earlier,
        [
          if (t != null) 'Task: ${_line(t)}',
          if (t?.outcome != null) 'Outcome noted: ${t!.outcome}',
        ],
        fallback,
        'Your previous reply was unhelpful. Start with a short apology, then respond properly to this message and offer one useful next step.',
        history: await _chatHistory()));
  }

  /// The user's own earlier messages from any chat sharing words with [text]
  /// (this turn excluded). Optional context: a failed read is just none.
  Future<List<Message>> _related(String text) async {
    try {
      return (await conversations.relevant(text, limit: 4))
          .where((m) =>
              _safeHistorical(m.content) &&
              m.content.trim() != _said &&
              m.content.trim() != text.trim())
          .take(3)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // Durable personal facts are sourced only from active memory rows. Replaying
  // old chat statements would resurrect deleted or superseded preferences.
  bool _safeHistorical(String text) =>
      !RuleEngine.isExplicitRemember(text) &&
      !isUsefulPersonalMemory(
          (_fallback.extractMemory(text)['memory'] as String?) ?? text) &&
      !text.toLowerCase().contains('remember');

  Future<List<String>> _personalMemories(String text) async {
    if (RuleEngine.isGeneralKnowledge(text)) return const [];
    try {
      return (await memory.relevantForContext(text, limit: 3))
          .map((m) => withFactDate(AssistantSession._cut(m.content), m.factDate))
          .toList();
    } catch (_) {
      _diag['memory'] = 'retrieval_failed';
      return const [];
    }
  }

}
