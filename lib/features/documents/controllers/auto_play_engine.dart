/// Owns Viewer playback timing and drives navigation through its injected reader handle.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import '../repositories/pgn_viewer_handle.dart';

class AutoPlayEngine {
  /// Pause before the first ply after Play is pressed, so the press itself
  /// reads as the start rather than an instant jump.
  static const firstStepDelay = Duration(milliseconds: 300);

  /// Delay between plies when playback starts.
  static const defaultDelaySec = 1.0;

  AutoPlayEngine({
    required this.isActive,
    required this.handle,
    required this.hasNextGame,
    required this.nextGame,
    required this.onChanged,
    this.schedulePostFrame,
  });

  /// Whether the owning view is still mounted/active.
  final bool Function() isActive;

  final PgnViewerHandle handle;

  /// Whether a following game exists to roll over to.
  final bool Function() hasNextGame;

  /// Switch to the next game.
  final VoidCallback nextGame;

  /// Notify listeners (the controller's `notifyListeners`).
  final VoidCallback onChanged;

  /// Run a callback after the current frame (so `goForward` settles first).
  final void Function(void Function() callback)? schedulePostFrame;

  bool _disposed = false;
  int _run = 0;
  Timer? _timer;
  bool isPlaying = false;
  bool autoNextGame = false;
  double delaySec = defaultDelaySec;
  bool _firstStep = false;
  DateTime? _lastStepTime;

  Duration get _stepDelay => Duration(milliseconds: (delaySec * 1000).round());

  void toggle() => isPlaying ? stop() : start();

  void start() {
    if (_disposed) return;
    _run++;
    _firstStep = true;
    isPlaying = true;
    onChanged();
    _schedule();
  }

  void stop() {
    _run++;
    _timer?.cancel();
    _timer = null;
    if (isPlaying) {
      isPlaying = false;
      onChanged();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || !isPlaying) return;
    final delay = _firstStep ? firstStepDelay : _stepDelay;
    _firstStep = false;
    _timer = Timer(delay, _step);
  }

  void _step() {
    if (_disposed || !isActive() || !isPlaying) return;
    final run = _run;
    final fenBefore = handle.currentFen;
    if (fenBefore == null) return;
    _lastStepTime = DateTime.now();

    handle.goForward();

    void checkAfterForward() {
      if (_disposed || !isActive() || !isPlaying || run != _run) return;
      final fenAfter = handle.currentFen;
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

    final schedule = schedulePostFrame;
    if (schedule != null) {
      schedule(checkAfterForward);
    } else {
      checkAfterForward();
    }
  }

  /// Change the delay between plies; a running playback keeps the time the
  /// current ply has already been on screen and only waits out the rest.
  void setSpeed(double val) {
    delaySec = val;
    onChanged();
    final lastStep = _lastStepTime;
    if (!isPlaying || lastStep == null) return;

    _timer?.cancel();
    final remaining = _stepDelay - DateTime.now().difference(lastStep);
    if (remaining <= Duration.zero) {
      _step();
    } else {
      _timer = Timer(remaining, _step);
    }
  }

  void setAutoNextGame(bool value) {
    autoNextGame = value;
    onChanged();
  }

  void dispose() {
    _disposed = true;
    isPlaying = false;
    _timer?.cancel();
    _timer = null;
  }
}
