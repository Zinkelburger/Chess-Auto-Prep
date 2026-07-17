/// Auto-play timer logic for the PGN viewer, extracted from
/// `PgnViewerController`.
///
/// Owns the timer + playback state and drives the board through injected
/// callbacks. `PgnViewerController` keeps its public API and delegates here, so
/// existing call-sites are unchanged.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

class AutoPlayEngine {
  AutoPlayEngine({
    required this.isActive,
    required this.currentFen,
    required this.goForward,
    required this.hasNextGame,
    required this.nextGame,
    required this.onChanged,
    this.schedulePostFrame,
  });

  /// Whether the owning view is still mounted/active.
  final bool Function() isActive;

  /// Current board FEN (used to detect "no more moves").
  final String? Function() currentFen;

  /// Advance one ply on the board.
  final VoidCallback goForward;

  /// Whether a following game exists to roll over to.
  final bool Function() hasNextGame;

  /// Switch to the next game.
  final VoidCallback nextGame;

  /// Notify listeners (the controller's `notifyListeners`).
  final VoidCallback onChanged;

  /// Run a callback after the current frame (so `goForward` settles first).
  final void Function(void Function() callback)? schedulePostFrame;

  Timer? _timer;
  bool isPlaying = false;
  bool autoNextGame = false;
  double delaySec = 1.0;
  bool _firstStep = false;
  DateTime? _lastStepTime;

  void toggle() => isPlaying ? stop() : start();

  void start() {
    _firstStep = true;
    isPlaying = true;
    onChanged();
    _schedule();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (isPlaying) {
      isPlaying = false;
      onChanged();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (!isPlaying) return;
    final delayMs = _firstStep ? 300 : (delaySec * 1000).round();
    _firstStep = false;
    _timer = Timer(Duration(milliseconds: delayMs), _step);
  }

  void _step() {
    if (!isActive() || !isPlaying) return;
    final fenBefore = currentFen();
    if (fenBefore == null) return;
    _lastStepTime = DateTime.now();

    goForward();

    void checkAfterForward() {
      if (!isActive() || !isPlaying) return;
      final fenAfter = currentFen();
      if (fenAfter == fenBefore) {
        if (autoNextGame && hasNextGame()) {
          nextGame();
          start();
        } else {
          stop();
        }
      } else {
        _schedule();
      }
    }

    if (schedulePostFrame != null) {
      schedulePostFrame!(checkAfterForward);
    } else {
      checkAfterForward();
    }
  }

  void setSpeed(double val) {
    delaySec = val;
    onChanged();
    if (!isPlaying || _lastStepTime == null) return;

    _timer?.cancel();
    final elapsedMs = DateTime.now().difference(_lastStepTime!).inMilliseconds;
    final newDelayMs = (val * 1000).round();
    final remainingMs = newDelayMs - elapsedMs;

    if (remainingMs <= 0) {
      _step();
    } else {
      _timer = Timer(Duration(milliseconds: remainingMs), _step);
    }
  }

  void setAutoNextGame(bool value) {
    autoNextGame = value;
    onChanged();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
