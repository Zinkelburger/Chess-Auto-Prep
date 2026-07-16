part of 'training_session_controller.dart';

// ---------------------------------------------------------------------------
// LEARN PHASE
// ---------------------------------------------------------------------------

/// The new-line learn walkthrough and its acknowledge/quiz gates for
/// [TrainingSessionController]. Shared fields and cross-phase helpers are
/// provided by the host class ([_MoveDisplayMixin], [_MoveValidationMixin],
/// and the drill/line-management methods).
mixin _LearnPhaseMixin
    on ChangeNotifier, _MoveDisplayMixin, _MoveValidationMixin {
  // Shared state provided by the host class.
  int get currentMoveIndex;
  set currentMoveIndex(int value);
  int get currentLineLength;
  TrainingPhase get phase;
  set phase(TrainingPhase value);
  String? get feedback;
  set feedback(String? value);
  String? get currentAnnotation;
  set currentAnnotation(String? value);
  MoveDisplayInfo? get currentPairOpponent;
  set currentPairOpponent(MoveDisplayInfo? value);
  MoveDisplayInfo? get currentPairUser;
  set currentPairUser(MoveDisplayInfo? value);
  bool get waitingForUser;
  set waitingForUser(bool value);
  String? get error;
  set error(String? value);
  bool get opponentWaitingForAck;
  set opponentWaitingForAck(bool value);
  bool get learnWaitingForAck;
  set learnWaitingForAck(bool value);
  bool get learnQuizzing;
  set learnQuizzing(bool value);
  RepertoireController get session;
  TrainingSettings get settings;
  int get _lineGeneration;
  Timer? get _learnTimer;
  set _learnTimer(Timer? value);

  // Cross-phase helpers defined on the host class.
  bool _isUserMove(int moveIndex);
  Future<bool> _playIntroMoves();
  Future<void> advanceDrillPhase();

  Future<void> advanceLearnPhase() async {
    if (currentLine == null) return;
    final generation = _lineGeneration;
    if (currentMoveIndex >= currentLineLength) {
      session.clearMoveHistory();
      if (currentLine!.startPosition.fen != Chess.initial.fen) {
        session.setPositionFromFen(currentLine!.startPosition.fen);
      } else {
        session.clearMoveHistory();
      }
      currentMoveIndex = 0;
      phase = TrainingPhase.drilling;
      feedback = null;
      currentAnnotation = null;
      currentPairOpponent = null;
      currentPairUser = null;
      waitingForUser = false;
      notifyListeners();
      Future.microtask(() async {
        if (!await _playIntroMoves()) return;
        await advanceDrillPhase();
      });
      return;
    }

    final san = currentLine!.moves[currentMoveIndex];
    final move = session.position.parseSan(san);
    if (move == null) {
      error = 'Invalid move in line: $san';
      notifyListeners();
      return;
    }
    session.playMove(san);

    final annotation = currentLine!.comments[currentMoveIndex.toString()];
    final isUserMove = _isUserMove(currentMoveIndex);
    final display = _buildMoveDisplay(
      currentMoveIndex,
      isOpponent: !isUserMove,
    );

    currentAnnotation = annotation;
    feedback = null;
    waitingForUser = false;

    if (!isUserMove) {
      currentPairOpponent = display;
      currentPairUser = null;
      notifyListeners();

      if (annotation != null && annotation.isNotEmpty) {
        opponentWaitingForAck = true;
        notifyListeners();
      } else {
        await Future.delayed(Duration(milliseconds: settings.moveSpeedMs));
        if (generation != _lineGeneration) return;
        currentMoveIndex++;
        await advanceLearnPhase();
      }
    } else {
      currentPairUser = display;
      notifyListeners();

      if (settings.learnRequiresClick) {
        learnWaitingForAck = true;
        notifyListeners();
      } else if (annotation != null && annotation.isNotEmpty) {
        _learnTimer = Timer(
          Duration(seconds: settings.learnDelaySec),
          learnAcknowledged,
        );
      } else {
        await Future.delayed(Duration(milliseconds: settings.moveSpeedMs));
        if (generation != _lineGeneration) return;
        currentMoveIndex++;
        await advanceLearnPhase();
      }
    }
  }

  void learnAcknowledged() {
    _learnTimer?.cancel();
    session.goBack();
    learnWaitingForAck = false;
    learnQuizzing = true;
    waitingForUser = true;
    feedback = 'Your move';
    currentAnnotation = null;
    notifyListeners();
  }

  Future<void> handleLearnQuizMove(CompletedMove move) async {
    if (currentLine == null) return;
    final generation = _lineGeneration;
    final expectedSan = currentLine!.moves[currentMoveIndex];
    final isCorrect = isCorrectUserMove(move, expectedSan);

    if (isCorrect) {
      session.playMove(expectedSan);
      learnQuizzing = false;
      waitingForUser = false;
      feedback = 'Correct!';
      notifyListeners();
      await Future.delayed(Duration(milliseconds: settings.moveSpeedMs));
      if (generation != _lineGeneration) return;
      currentMoveIndex++;
      await advanceLearnPhase();
    } else {
      // Input stays off while the correction animates so a second answer
      // can't interleave with it; 'Try again' below re-enables it.
      waitingForUser = false;
      feedback = 'Wrong — the move is $expectedSan';
      notifyListeners();
      await Future.delayed(const Duration(milliseconds: 1200));
      if (generation != _lineGeneration) return;
      session.playMove(expectedSan);
      await Future.delayed(const Duration(milliseconds: 800));
      if (generation != _lineGeneration) return;
      session.goBack();
      feedback = 'Try again';
      waitingForUser = true;
      notifyListeners();
    }
  }
}
