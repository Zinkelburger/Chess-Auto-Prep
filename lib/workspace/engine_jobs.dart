import 'package:flutter/foundation.dart';

import 'engine_analysis.dart';

enum EngineJobKind {
  search('Expectimax search'),
  makingLines('Preparing repertoire lines'),
  audit('Chapter audit'),
  review('Game review'),
  solitaire('Solitaire chess'),
  tournament('Engine tournament');

  const EngineJobKind(this.label);
  final String label;
}

/// The one heavy engine job the machine runs at a time: a search from the
/// board, the engine lines a draft is finished with, a chapter audit, a game
/// review, an engine tournament. Each starts its own engines at full
/// threads, so two at once would each get half the machine and both run
/// slowly; the board engines (the board's and the Analysis tab's) are paused
/// for as long as one holds it, for the same reason.
///
/// A job [take]s the machine before it starts an engine and [release]s it
/// when the engine is gone; a job that finds another holding it does not
/// start. Notifies when the holder changes, so every owner whose start
/// depends on it can say again whether it may start. A job that ends after
/// the window is taken down still releases it, quietly.
final class EngineJobs extends ChangeNotifier {
  EngineJobs(EngineAnalysis board, {EngineAnalysis? analysisTab})
    : _boards = [board, ?analysisTab];

  final List<EngineAnalysis> _boards;
  Object? _holder;
  bool _disposed = false;
  EngineJobKind? _activeKind;
  EngineJobKind? get activeKind => _activeKind;
  String get blockingMessage =>
      '${_activeKind?.label ?? 'Another engine job'} is running. '
      'Use the running-task button at the top to return to it.';

  /// Whether a job other than [job] holds the machine.
  bool heldByOther(Object job) => _holder != null && !identical(_holder, job);

  /// Takes the machine for [job] and pauses the board engines, saying
  /// [reason] in its pane. False, changing nothing, when another job holds
  /// it; taking it again for the same job only changes the reason.
  bool take(Object job, String reason, {EngineJobKind? kind}) {
    if (heldByOther(job)) return false;
    final changed = _holder == null || kind != _activeKind;
    _activeKind = kind;
    _holder = job;
    for (final board in _boards) {
      board.pause(job, reason);
    }
    if (changed && !_disposed) notifyListeners();
    return true;
  }

  /// Gives the machine back and lets the board engines follow their boards
  /// again. Nothing happens unless [job] holds it.
  void release(Object job) {
    if (!identical(_holder, job)) return;
    _holder = null;
    _activeKind = null;
    for (final board in _boards) {
      board.resume(job);
    }
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
