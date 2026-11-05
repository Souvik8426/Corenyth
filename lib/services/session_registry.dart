import 'dart:async';

import '../assistant/session.dart';
import 'backup/backup_service.dart';

/// Tracks the live chat sessions so a backup import can settle them first.
///
/// [suspend] stops new turns from writing, cancels the turns in flight and
/// waits for them to end. If a turn does not end within [settleTimeout] it
/// throws [SessionsNotSettled] and lifts the block again, so a refused import
/// leaves the sessions working as before. Sessions are held weakly: a session
/// the UI dropped does not stay alive here.
class SessionRegistry implements SessionGate {
  SessionRegistry({this.settleTimeout = const Duration(seconds: 10)});

  /// How long an in-flight turn gets to finish after it is cancelled.
  final Duration settleTimeout;

  final _sessions = <WeakReference<AssistantSession>>[];
  bool _suspended = false;

  /// True while writes are blocked, so a session made now is blocked too.
  bool get suspended => _suspended;

  /// Adds [session]; it is blocked at once if a suspend is under way.
  void register(AssistantSession session) {
    _sessions.removeWhere((w) => w.target == null);
    _sessions.add(WeakReference(session));
    session.writesPaused = _suspended;
  }

  List<AssistantSession> get _live => [
        for (final w in _sessions)
          if (w.target != null) w.target!
      ];

  @override
  Future<void> suspend() async {
    if (_suspended) {
      throw const SessionsNotSettled(
          'Another operation is already holding the chat sessions.');
    }
    _suspended = true;
    final live = _live;
    for (final s in live) {
      s.writesPaused = true;
    }
    try {
      final busy = [
        for (final s in live)
          if (s.hasActiveTurn) s
      ];
      if (busy.isNotEmpty) {
        await Future.wait([for (final s in busy) s.cancel()])
            .timeout(settleTimeout);
      }
      if (live.any((s) => s.hasActiveTurn)) {
        throw const SessionsNotSettled(
            'A chat turn is still running and did not stop.');
      }
    } on TimeoutException {
      resume();
      throw const SessionsNotSettled(
          'A chat turn is still running and did not stop in time.');
    } catch (_) {
      resume();
      rethrow;
    }
  }

  @override
  void resume() {
    _suspended = false;
    for (final s in _live) {
      s.writesPaused = false;
    }
  }
}
