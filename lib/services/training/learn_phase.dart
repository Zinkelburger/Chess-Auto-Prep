/// New-line learn walkthrough for [TrainingSessionController].
///
/// Owns the acknowledge / quiz gates and the pacing timer. Session fields
/// (the line, the cursor, flags the UI binds to) stay on the controller so
/// the trainer widgets keep a single place to read from; this class is the
/// only writer of those fields during [TrainingPhase.learning].
library;

import 'dart:async';

import 'package:dartchess/dartchess.dart';

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
      _s.session.clearMoveHistory();
      if (_s.currentLine!.startPosition.fen != Chess.initial.fen) {
        _s.session.setPositionFromFen(_s.currentLine!.startPosition.fen);
      } else {
        _s.session.clearMoveHistory();
      }
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
      } else if (annotation != null && annotation.isNotEmpty) {
        _timer = Timer(
          Duration(seconds: _s.settings.learnDelaySec),
          acknowledged,
        );
      } else {
        await Future.delayed(Duration(milliseconds: _s.settings.moveSpeedMs));
        if (generation != _s.lineGeneration) return;
        _s.currentMoveIndex++;
        await advance();
      }
    }
  }

  void acknowledged() {
    cancelPending();
    _s.session.goBack();
    _s.learnWaitingForAck = false;
    _s.learnQuizzing = true;
    _s.waitingForUser = true;
    _s.feedback = 'Your move';
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
