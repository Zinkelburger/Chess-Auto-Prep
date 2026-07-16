part of 'training_session_controller.dart';

// ---------------------------------------------------------------------------
// REPLAY PHASE
// ---------------------------------------------------------------------------

/// The wrong-move replay phase for [TrainingSessionController]. Shared fields
/// and cross-phase helpers are provided by the host class ([_MoveDisplayMixin],
/// [_MoveValidationMixin], and [updateMoveProgress]).
mixin _ReplayPhaseMixin
    on ChangeNotifier, _MoveDisplayMixin, _MoveValidationMixin {
  // Shared state provided by the host class.
  List<int> get wrongMoveIndices;
  set wrongMoveIndices(List<int> value);
  int get replayIndex;
  set replayIndex(int value);
  TrainingPhase get phase;
  set phase(TrainingPhase value);
  bool get waitingForUser;
  set waitingForUser(bool value);
  String? get feedback;
  set feedback(String? value);
  String? get currentAnnotation;
  set currentAnnotation(String? value);
  RepertoireController get session;
  int get _lineGeneration;

  // Cross-phase helper defined on the host class.
  void updateMoveProgress(
    RepertoireLine line,
    int moveIndex, {
    required bool wasCorrect,
  });

  void startReplayPhase() {
    wrongMoveIndices = wrongMoveIndices.toSet().toList()..sort();
    replayIndex = 0;
    phase = TrainingPhase.replaying;
    feedback = 'Replay missed moves (${wrongMoveIndices.length} remaining)';
    currentAnnotation = null;
    notifyListeners();
    setupReplayPosition();
  }

  void setupReplayPosition() {
    if (currentLine == null) return;
    if (replayIndex >= wrongMoveIndices.length) {
      phase = TrainingPhase.finished;
      waitingForUser = false;
      feedback = 'Line complete — rate your recall.';
      currentAnnotation = null;
      notifyListeners();
      return;
    }

    final targetMoveIndex = wrongMoveIndices[replayIndex];

    if (currentLine!.startPosition.fen != Chess.initial.fen) {
      session.setPositionFromFen(currentLine!.startPosition.fen);
    } else {
      session.clearMoveHistory();
    }
    for (int i = 0; i < targetMoveIndex; i++) {
      session.playMove(currentLine!.moves[i]);
    }

    waitingForUser = true;
    feedback = 'Replay — ${wrongMoveIndices.length - replayIndex} left';
    currentAnnotation = null;
    notifyListeners();
  }

  Future<void> handleReplayMove(CompletedMove move) async {
    final generation = _lineGeneration;
    final targetMoveIndex = wrongMoveIndices[replayIndex];
    final expectedSan = currentLine!.moves[targetMoveIndex];
    final isCorrect = isCorrectUserMove(move, expectedSan);

    if (isCorrect) {
      updateMoveProgress(currentLine!, targetMoveIndex, wasCorrect: true);
      session.playMove(expectedSan);
      feedback = 'Correct!';
      waitingForUser = false;
      notifyListeners();
      replayIndex++;
      await Future.delayed(const Duration(milliseconds: 500));
      if (generation != _lineGeneration) return;
      setupReplayPosition();
    } else {
      updateMoveProgress(currentLine!, targetMoveIndex, wasCorrect: false);
      feedback = 'Try again — the move is $expectedSan';
      notifyListeners();
    }
  }
}
