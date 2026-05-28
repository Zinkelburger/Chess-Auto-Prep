import 'package:flutter/foundation.dart';

import 'package:chess_auto_prep/models/tactics_position.dart';
import 'package:chess_auto_prep/services/tactics/tactics_session_controller.dart';
import 'package:chess_auto_prep/services/tactics_database.dart';
import 'package:flutter_test/flutter_test.dart';

TacticsPosition _samplePosition({List<String> line = const ['e4']}) {
  return TacticsPosition(
    fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
    gameWhite: 'A',
    gameBlack: 'B',
    gameResult: '1-0',
    gameDate: '2024.01.01',
    gameId: 'g1',
    positionContext: 'Move 1 — White to play',
    userMove: 'd4',
    correctLine: line,
    mistakeType: '?',
    mistakeAnalysis: 'test',
  );
}

/// Ignore delayed UI callbacks so assertions see immediate state.
void _noopSchedule(Duration _, VoidCallback __) {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('processMoveAttempt accepts correct single-move tactic', () {
    final db = TacticsDatabase();
    db.positions.add(_samplePosition());
    final session = TacticsSessionController(database: db)
      ..autoAdvance = false;
    session.selectPosition(db.positions.first);

    final update = session.processMoveAttempt(
      moveUci: 'e2e4',
      boardFen: db.positions.first.fen,
      schedule: _noopSchedule,
      isMounted: () => true,
    );

    expect(update?.applyMoveUci, 'e2e4');
    expect(session.positionSolved, isTrue);
    expect(session.feedback, 'Correct!');
  });

  test('processMoveAttempt rejects wrong move', () {
    final db = TacticsDatabase();
    db.positions.add(_samplePosition());
    final session = TacticsSessionController(database: db);
    session.selectPosition(db.positions.first);

    final update = session.processMoveAttempt(
      moveUci: 'd2d4',
      boardFen: db.positions.first.fen,
      schedule: _noopSchedule,
      isMounted: () => true,
    );

    expect(update?.applyMoveUci, 'd2d4');
    expect(session.feedback, 'Incorrect');
    expect(session.positionSolved, isFalse);
  });
}
