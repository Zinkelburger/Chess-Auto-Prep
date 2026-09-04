/// Cooperative pause and cancel for a long-running service loop.
///
/// The audit, the hole hunt and the trick hunt each ran for minutes over a
/// tree, and each had grown the same two booleans, the same three one-line
/// mutators, the same reset, and — five times between them — the same
/// hand-written wait:
///
/// ```dart
/// if (_cancelled) break;
/// while (_paused && !_cancelled) {
///   await Future.delayed(const Duration(milliseconds: 100));
/// }
/// if (_cancelled) break;
/// ```
///
/// Three lines of that are load-bearing and easy to get subtly wrong: the
/// pause loop must re-check *cancel*, or cancelling a paused run leaves it
/// spinning forever, and the check has to be repeated after the wait, because
/// cancel is what usually ends a pause.
///
/// [checkpoint] is that whole shape as one call. Sites that `break` and sites
/// that `return` both work, because it answers a question rather than
/// controlling flow itself.
library;

class RunControl {
  bool _cancelled = false;
  bool _paused = false;

  bool get isCancelled => _cancelled;
  bool get isPaused => _paused;

  /// True between [reset] and a [cancel], i.e. while a run may still proceed.
  bool get isRunning => !_cancelled;

  void pause() => _paused = true;
  void resume() => _paused = false;
  void cancel() => _cancelled = true;

  /// Clear both flags. Call as a run starts, not as it ends: a cancelled run
  /// is asked for its partial results afterwards, and clearing here would
  /// make `isCancelled` lie about why it stopped.
  void reset() {
    _cancelled = false;
    _paused = false;
  }

  /// How often a paused loop wakes to look at the flags. Short enough that
  /// Resume feels immediate, long enough that a paused run costs nothing.
  static const Duration pollInterval = Duration(milliseconds: 100);

  /// Wait here while paused, then report whether the run should continue.
  ///
  /// Returns false once cancelled — including when the cancel arrives *during*
  /// the pause, which is the case the hand-written copies had to remember to
  /// re-check. Call it once per unit of work:
  ///
  /// ```dart
  /// while (queue.isNotEmpty) {
  ///   if (!await control.checkpoint()) break;
  ///   …
  /// }
  /// ```
  Future<bool> checkpoint() async {
    if (_cancelled) return false;
    while (_paused && !_cancelled) {
      await Future<void>.delayed(pollInterval);
    }
    return !_cancelled;
  }
}
