/// New-line learn walkthrough for [TrainingSessionController].
///
/// Owns the acknowledge / quiz gates and the pacing timer. Session fields
/// (the line, the cursor, flags the UI binds to) stay on the controller so
/// the trainer widgets keep a single place to read from; this class is the
/// only writer of those fields during [TrainingPhase.learning].
///
/// The walkthrough plays each move onto the board with its comment. What
/// happens at *your* moves depends on [TrainingSettings.learnRequiresClick]:
///
///  * manual advance — every one of your moves waits for Next, then the board
///    rewinds one ply and asks you to play it before going on;
///  * auto advance — the same, with [TrainingSettings.learnDelaySec] in place
///    of the click. The delay only replaces Next; it never skips the quiz,
///    which used to be the case for moves without a note.
///
/// Opponent moves with a comment wait for Next in both modes. When the line
/// runs out the same line restarts in [TrainingPhase.drilling].
library;

import 'dart:async';

import '../../models/completed_move.dart';
import '../../utils/chess_utils.dart' show playSanOrNullMove;
import 'move_display.dart';
import 'move_validation.dart' as validation;
import 'training_phase.dart';
import 'training_session_controller.dart';

class LearnPhase {
  LearnPhase(this._s);

  final TrainingSessionController _s;
  Timer? _timer;

  void cancelPending() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> advance() async {
    if (_s.currentLine == null) return;
    final generation = _s.lineGeneration;
    if (_s.currentMoveIndex >= _s.currentLineLength) {
      _s.resetBoard(_s.currentLine!);
      _s.currentMoveIndex = 0;
      _s.phase = TrainingPhase.drilling;
      _s.feedback = null;
      _s.currentAnnotation = null;
      _s.currentPairOpponent = null;
      _s.currentPairUser = null;
      _s.waitingForUser = false;
      _s.emitChange();
      unawaited(
        Future.microtask(() async {
          if (!await _s.playIntroMoves()) return;
          await _s.advanceDrillPhase();
        }),
      );
      return;
    }

    final san = _s.currentLine!.moves[_s.currentMoveIndex];
    if (playSanOrNullMove(_s.session.position, san) == null) {
      _s.error = 'Invalid move in line: $san';
      _s.emitChange();
      return;
    }
    _s.session.playMove(san);

    final annotation = _s.currentLine!.comments[_s.currentMoveIndex.toString()];
    final isUserMove = _s.isUserMove(_s.currentMoveIndex);
    final display = buildMoveDisplay(
      _s.currentLine,
      _s.currentMoveIndex,
      isOpponent: !isUserMove,
    );

    _s.currentAnnotation = annotation;
    _s.feedback = null;
    _s.waitingForUser = false;

    if (!isUserMove) {
      _s.currentPairOpponent = display;
      _s.currentPairUser = null;
      _s.emitChange();

      if (annotation != null && annotation.isNotEmpty) {
        _s.opponentWaitingForAck = true;
        _s.emitChange();
      } else {
        await Future.delayed(Duration(milliseconds: _s.settings.moveSpeedMs));
        if (generation != _s.lineGeneration) return;
        _s.currentMoveIndex++;
        await advance();
      }
    } else {
      _s.currentPairUser = display;
      _s.emitChange();

      if (_s.settings.learnRequiresClick) {
        _s.learnWaitingForAck = true;
        _s.emitChange();
      } else {
        _timer = Timer(
          Duration(seconds: _s.settings.learnDelaySec),
          acknowledged,
        );
      }
    }
  }

  /// Next was pressed on one of your moves (or the auto-advance delay ran
  /// out): rewind that move and ask for it.
  ///
  /// Idempotent on purpose. Next is a button that also self-focuses, so a
  /// double-click or a Space that lands after the click would otherwise
  /// rewind the board a second ply and quiz the wrong move.
  void acknowledged() {
    if (_s.phase != TrainingPhase.learning || _s.learnQuizzing) return;
    cancelPending();
    _s.session.goBack();
    _s.learnWaitingForAck = false;
    _s.learnQuizzing = true;
    _s.waitingForUser = true;
    // The prompt is the card's own "Your move" row; the feedback line is for
    // the verdict on what you played.
    _s.feedback = null;
    _s.currentAnnotation = null;
    _s.emitChange();
  }

  Future<void> handleQuizMove(CompletedMove move) async {
    if (_s.currentLine == null) return;
    final generation = _s.lineGeneration;
    final expectedSan = _s.currentLine!.moves[_s.currentMoveIndex];
    final isCorrect = validation.isCorrectUserMove(
      _s.session.position,
      move,
      expectedSan,
    );

    if (isCorrect) {
      _s.session.playMove(expectedSan);
      _s.learnQuizzing = false;
      _s.waitingForUser = false;
      _s.feedback = 'Correct!';
      _s.emitChange();
      await Future.delayed(Duration(milliseconds: _s.settings.moveSpeedMs));
      if (generation != _s.lineGeneration) return;
      _s.currentMoveIndex++;
      await advance();
    } else {
      // Input stays off while the correction animates so a second answer
      // can't interleave with it; 'Try again' below re-enables it.
      _s.waitingForUser = false;
      _s.feedback = 'Wrong — the move is $expectedSan';
      _s.emitChange();
      await Future.delayed(const Duration(milliseconds: 1200));
      if (generation != _s.lineGeneration) return;
      _s.session.playMove(expectedSan);
      await Future.delayed(const Duration(milliseconds: 800));
      if (generation != _s.lineGeneration) return;
      _s.session.goBack();
      _s.feedback = 'Try again';
      _s.waitingForUser = true;
      _s.emitChange();
    }
  }
}
