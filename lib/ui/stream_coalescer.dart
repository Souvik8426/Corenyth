import 'dart:async';

/// Batches live model output into UI updates at a small fixed interval.
///
/// The chunks are real streamed output, merged while generation is running —
/// never a typewriter reveal of a finished answer. [cancel] and the final
/// authoritative callback flush nothing: the caller's final bubble
/// supersedes the draft, so a pending batch can never resurrect withdrawn
/// text or overwrite a newer turn.
class StreamCoalescer {
  StreamCoalescer(this.onFlush) : interval = const Duration(milliseconds: 33);

  final void Function(String liveText) onFlush;

  /// Update cadence, inside the 16-50 ms window measured for frame budgets.
  final Duration interval;
  Timer? _timer;
  String? _pending;
  int _lastFlush = 0;
  bool _cancelled = false;

  /// Whether [cancel] was called; a cancelled coalescer drops everything.
  bool get cancelled => _cancelled;

  /// Offers one cumulative live text. Empty text withdraws the draft.
  void add(String liveText) {
    if (_cancelled) return;
    _pending = liveText;
    final now = DateTime.now().millisecondsSinceEpoch;
    final due = _lastFlush + interval.inMilliseconds;
    if (now >= due) {
      _flush();
    } else {
      _timer ??= Timer(Duration(milliseconds: due - now), _flush);
    }
  }

  void _flush() {
    _timer?.cancel();
    _timer = null;
    _lastFlush = DateTime.now().millisecondsSinceEpoch;
    final text = _pending;
    _pending = null;
    if (!_cancelled && text != null) onFlush(text);
  }

  /// Stops the coalescer: no further flushes, ever. Called on finalization,
  /// stop, and dispose.
  void cancel() {
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
    _pending = null;
  }
}
