/// Drill phase for [TrainingSessionController]: the quiz proper.
///
/// Plays the opponent's moves onto the board and waits for the user at each
/// of theirs. Session fields stay on the controller so the trainer widgets
/// keep a single place to read from; this class is the only writer of those
/// fields during [TrainingPhase.drilling].
///
/// A wrong answer is corrected on the board (the expected move plays after a
/// pause) and remembered for the replay phase; the line then carries on.
/// When the line runs out, a clean line finishes and a line with mistakes
/// goes to replay when [TrainingSettings.wrongMoveReplay] is on.
library;

import '../../../models/completed_move.dart';
import '../../../utils/chess_utils.dart' show playSanOrNullMove;
import '../models/move_display.dart';
import '../models/move_validation.dart' as validation;
import '../models/training_phase.dart';
import 'training_session_controller.dart';

class DrillPhase {
  DrillPhase(this._s);

  final TrainingSessionController _s;

  /// Play opponent moves up to the user's next move, or finish the line.
  ///
  /// Stops early while an opponent move is still waiting for Next
  /// ([TrainingSessionController.opponentWaitingForAck]); the acknowledgement
  /// resumes it.
  Future<void> advance() async {
    if (_s.currentLine == null) return;
    final generation = _s.lineGeneration;
    final limit = _s.effectiveLineLength;

    while (_s.currentMoveIndex < limit) {
      if (_s.isUserMove(_s.currentMoveIndex)) {
        _prepareUserMove();
        return;
      }
      _playOpponentMove(_s.currentMoveIndex);
      if (_s.opponentWaitingForAck) return;
      _s.currentMoveIndex++;
      if (_s.currentMoveIndex >= limit) {
        // Let the final opponent move register on the board before the
        // results panel replaces the card.
        await Future.delayed(Duration(milliseconds: _s.settings.moveSpeedMs));
        if (generation != _s.lineGeneration) return;
      }
    }
    _onLineComplete();
  }

  /// Plays the opponent reply with no trailing delay: the reply and the next
  /// "Your move" prompt land in the same frame. Pacing happens while the
  /// user's answered pair is still on screen (see [handleMove]).
  void _playOpponentMove(int moveIndex) {
    final line = _s.currentLine;
    if (line == null) return;
    final san = line.moves[moveIndex];
    if (playSanOrNullMove(_s.session.position, san) == null) {
      _s.error = 'Could not play opponent move $san';
      _s.emitChange();
      return;
    }
    _s.session.playMove(san);

    _s.currentPairOpponent = buildMoveDisplay(
      line,
      moveIndex,
      isOpponent: true,
    );
    _s.currentPairUser = null;
    _s.currentAnnotation = null;
    _s.emitChange();
  }

  void _prepareUserMove() {
    _s.waitingForUser = true;
    _s.currentAnnotation = null;
    _s.feedback = null;
    _s.currentPairUser = null;
    _s.emitChange();
  }

  /// Judge the user's answer at the current move and carry the line on.
  ///
  /// The caller has already recorded the attempt and re-enabled input; a
  /// wrong answer switches it off again while the correction plays out so a
  /// second answer cannot interleave with it.
  Future<void> handleMove(CompletedMove move) async {
    final line = _s.currentLine;
    if (line == null) return;
    final generation = _s.lineGeneration;
    final moveIndex = _s.currentMoveIndex;
    final expectedSan = line.moves[moveIndex];
    final isCorrect = validation.isCorrectUserMove(
      _s.session.position,
      move,
      expectedSan,
    );
    _s.updateMoveProgress(line, moveIndex, wasCorrect: isCorrect);
    final display = buildMoveDisplay(line, moveIndex, isOpponent: false);

    if (isCorrect) {
      _s.session.playMove(expectedSan);
      _s.waitingForUser = false;
      _s.feedback = null;
      _s.currentPairUser = display;
      _s.currentAnnotation = null;
      _s.emitChange();
      _s.currentMoveIndex++;
      // Hold the completed pair + "Correct!" for the full pause, then swap
      // to the opponent's reply and next prompt in one update — no cleared
      // or opponent-only frames in between.
    } else {
      _s.lineHadMistake = true;
      _s.wrongMoveIndices.add(moveIndex);
      _s.waitingForUser = false;
      _s.feedback = 'Play $expectedSan';
      _s.currentAnnotation = line.comments[moveIndex.toString()];
      _s.emitChange();
      await Future.delayed(wrongMoveCorrectionDelay);
      if (generation != _s.lineGeneration) return;

      _s.session.playMove(expectedSan);
      _s.currentPairUser = display;
      _s.currentAnnotation = display.comment;
      _s.emitChange();
      _s.currentMoveIndex++;
    }

    await Future.delayed(Duration(milliseconds: _s.settings.moveSpeedMs));
    if (generation != _s.lineGeneration) return;
    _clearPair();
    await advance();
  }

  void _clearPair() {
    _s.currentPairOpponent = null;
    _s.currentPairUser = null;
    _s.feedback = null;
    _s.currentAnnotation = null;
  }

  void _onLineComplete() {
    if (_s.lineHadMistake &&
        _s.settings.wrongMoveReplay &&
        _s.wrongMoveIndices.isNotEmpty) {
      _s.startReplayPhase();
    } else {
      _s.completeLine();
    }
  }
}
