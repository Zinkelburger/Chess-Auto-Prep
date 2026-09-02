/// What the expectimax pane needs to *ask* for a value it does not have:
/// a way to start a probe rooted at its position, and the run state to
/// show while one is in flight.
///
/// Nothing here computes anything at browse time. A probe is an ordinary
/// generation job the user starts by hand; the pane only shows what the
/// database already holds and offers to fill the gaps.
library;

import '../../core/generation_session_controller.dart';

class ExpectimaxProbeHooks {
  const ExpectimaxProbeHooks({required this.generation, required this.compute});

  final GenerationSessionController generation;

  /// Start a probe from the pane's position — after [moveSan] when given —
  /// exploring [plies] half-moves. Returns why it could not start, or null.
  final Future<String?> Function({String? moveSan, required int plies}) compute;

  /// Any build is running (the engine is taken; a probe would have to wait).
  bool get isBusy => generation.isGenerating;

  /// The running build is a probe of this kind.
  bool get isProbeRunning => generation.isExpectimaxProbe;

  String get status => generation.progress.status;

  void cancel() => generation.cancelBuild();
}
