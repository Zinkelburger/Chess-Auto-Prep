import 'package:flutter/foundation.dart';

import '../features/trainer/trainer.dart';
import '../features/tactics/puzzle_trainer.dart';
import 'mode.dart';
import 'workspace_requests.dart';

/// Keeps the Train tab's sitting beside its controls: in the mode it was
/// started in, with the Train tab open. Anywhere else the board would go on
/// showing the lesson and taking moves for it with nothing to answer or
/// leave it by, so the sitting pauses.
final class SittingInView {
  SittingInView({
    required Trainer trainer,
    required WorkspaceRequests requests,
    required bool Function() trainTabOpen,
  }) : _trainer = trainer,
       _requests = requests,
       _trainTabOpen = trainTabOpen {
    for (final owner in _owners) {
      owner.addListener(check);
    }
  }

  final Trainer _trainer;
  final WorkspaceRequests _requests;

  /// Whether the mode on screen has its Train tab open: the tabs are the
  /// shell's, one set per mode.
  final bool Function() _trainTabOpen;

  /// The mode the sitting runs in, while one does.
  Mode? _mode;
  bool _wasSuspended = false;

  List<Listenable> get _owners => [_trainer, _requests];

  /// Suspends the sitting out of view; returning offers explicit Resume.
  void check() {
    if (_trainer.lesson == null) {
      _mode = null;
      _wasSuspended = false;
      return;
    }
    final suspended = _trainer.lesson!.suspended;
    if (_wasSuspended && !suspended) _mode = _requests.mode;
    _wasSuspended = suspended;
    final mode = _mode ??= _requests.mode;
    if (_requests.mode != mode || !_trainTabOpen()) _trainer.suspend();
  }

  void dispose() {
    for (final owner in _owners) {
      owner.removeListener(check);
    }
  }
}

/// Keeps a puzzle on the board only while Tactics is on screen. Anywhere
/// else the board would go on judging the moves made on it, Space would
/// show its answer and the arrows walk the puzzles, with nothing on screen
/// to say so; so it is put down, and the run is kept for Tactics.
final class PuzzleInView {
  PuzzleInView({
    required PuzzleTrainer puzzles,
    required WorkspaceRequests requests,
  }) : _puzzles = puzzles,
       _requests = requests {
    for (final owner in _owners) {
      owner.addListener(check);
    }
  }

  final PuzzleTrainer _puzzles;
  final WorkspaceRequests _requests;

  List<Listenable> get _owners => [_puzzles, _requests];

  /// Puts the puzzle down if it is up out of Tactics: the mode changed, or
  /// a set game came up in another mode's document.
  void check() {
    if (_puzzles.up != null && _requests.mode != Mode.tactics) {
      _puzzles.putDown();
    }
  }

  void dispose() {
    for (final owner in _owners) {
      owner.removeListener(check);
    }
  }
}
