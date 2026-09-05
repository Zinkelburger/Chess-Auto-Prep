/// Wrong-move replay phase for [TrainingSessionController].
///
/// After a line is drilled with mistakes, this walks only the missed user
/// moves. Session fields stay on the controller; this class is the only
/// writer of those fields during [TrainingPhase.replaying].
library;

import '../../models/completed_move.dart';
import 'move_validation.dart' as validation;
import 'training_phase.dart';
import 'training_session_controller.dart';

class ReplayPhase {
  ReplayPhase(this._s);

  final TrainingSessionController _s;

  void start() {
    _s.wrongMoveIndices = _s.wrongMoveIndices.toSet().toList()..sort();
    _s.replayIndex = 0;
    _s.phase = TrainingPhase.replaying;
    _s.feedback =
        'Replay missed moves (${_s.wrongMoveIndices.length} remaining)';
    _s.currentAnnotation = null;
    _s.emitChange();
    setupPosition();
  }

  void setupPosition() {
    if (_s.currentLine == null) return;
    if (_s.replayIndex >= _s.wrongMoveIndices.length) {
      _s.completeLine();
      return;
    }

    final targetMoveIndex = _s.wrongMoveIndices[_s.replayIndex];
    _s.resetBoard(_s.currentLine!);
    for (int i = 0; i < targetMoveIndex; i++) {
      _s.session.playMove(_s.currentLine!.moves[i]);
    }

    _s.waitingForUser = true;
    _s.feedback =
        'Replay — ${_s.wrongMoveIndices.length - _s.replayIndex} left';
    _s.currentAnnotation = null;
    _s.emitChange();
  }

  Future<void> handleMove(CompletedMove move) async {
    final generation = _s.lineGeneration;
    final targetMoveIndex = _s.wrongMoveIndices[_s.replayIndex];
    final expectedSan = _s.currentLine!.moves[targetMoveIndex];
    final isCorrect = validation.isCorrectUserMove(
      _s.session.position,
      move,
      expectedSan,
    );

    if (isCorrect) {
      _s.updateMoveProgress(_s.currentLine!, targetMoveIndex, wasCorrect: true);
      _s.session.playMove(expectedSan);
      _s.feedback = 'Correct!';
      _s.waitingForUser = false;
      _s.emitChange();
      _s.replayIndex++;
      await Future.delayed(const Duration(milliseconds: 500));
      if (generation != _s.lineGeneration) return;
      setupPosition();
    } else {
      _s.updateMoveProgress(
        _s.currentLine!,
        targetMoveIndex,
        wasCorrect: false,
      );
      _s.feedback = 'Try again — the move is $expectedSan';
      _s.emitChange();
    }
  }
}
