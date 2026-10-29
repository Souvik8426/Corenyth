import 'mascot_emotion.dart';

/// The one owner of mascot emotion state for the open conversation.
///
/// The session delivers validated [TurnMood] records for submitted turns;
/// this store decides what the mascot shows — never an interpretation of
/// message text. Rules:
///
/// - A new turn ([beginTurn]) resets the pending display to the neutral
///   unknown state; the first valid event of that turn transitions once and
///   later events for the same turn are dropped.
/// - Events are dropped after [cancelPending] (stop), [dispose], a newer
///   [beginTurn], or a conversation switch (a fresh store per conversation).
/// - Accepted records are kept by their user message row id, so reopening or
///   paging history reads stored state instead of inferring anything; turns
///   with no record display unknown/calm.
class MoodController {
  MoodController({required String conversationId, Map<int, TurnMood>? history})
      : conversationId = conversationId,
        _history = history ?? {},
        _pending = TurnMood.unknown(conversationId, '');

  final String conversationId;
  final Map<int, TurnMood> _history;
  TurnMood _pending;
  bool _turnOpen = false;
  String? _turnId;
  bool _accepted = false;
  bool _disposed = false;

  /// Accepted per-turn records by user message row id (display use).
  Map<int, TurnMood> get history => Map.unmodifiable(_history);

  /// The live display for the turn being submitted (unknown until the model
  /// reports, calm render either way).
  TurnMood get pending => _pending;

  /// Marks the start of a submitted turn. [turnId] is the session operation
  /// id; a mood record naming a different turn is dropped as stale.
  void beginTurn(String turnId) {
    if (_disposed) return;
    _turnId = turnId;
    _turnOpen = true;
    _accepted = false;
    _pending = TurnMood.unknown(conversationId, turnId);
  }

  /// Accepts one validated event. True when it became the display value:
  /// the first valid event of the open turn wins, everything else (later
  /// events, closed windows, other conversations, stale turns) is dropped.
  bool accept(TurnMood record) {
    if (_disposed || !_turnOpen || _accepted) return false;
    if (record.conversationId != conversationId) return false;
    if (_turnId != null && record.turnId != _turnId) return false;
    _accepted = true;
    _pending = record;
    final row = record.messageRowId;
    if (row != null) _history[row] = record;
    return true;
  }

  /// Adopts a stored record read from the database (conversation reload,
  /// background writes by another engine). History only: it never touches the
  /// live pending display, and it is a no-op after [dispose].
  void adopt(int messageRowId, TurnMood record) {
    if (_disposed || record.conversationId != conversationId) return;
    _history[messageRowId] = record;
  }

  /// Closes the turn window: late events for it are stale from now on. The
  /// accepted value stays visible for its exchange.
  void endTurn() {
    _turnOpen = false;
  }

  /// The turn was stopped or failed before a reading arrived: back to the
  /// neutral unknown display, so no mood outlives its evidence.
  void cancelPending() {
    _turnOpen = false;
    _accepted = false;
    _pending = TurnMood.unknown(conversationId, _turnId ?? '');
  }

  /// The display emotion for one exchange's user message row: the stored
  /// record's emotion, or unknown (calm render) when the row has none.
  TurnMood moodFor(int? messageRowId) =>
      messageRowId == null
          ? TurnMood.unknown(conversationId, '')
          : (_history[messageRowId] ??
              TurnMood.unknown(conversationId, ''));

  void dispose() {
    _disposed = true;
    _turnOpen = false;
    _history.clear();
  }
}
