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

/// Execute callbacks immediately so we can test the full multi-move flow
/// synchronously.
void _immediateSchedule(Duration _, VoidCallback action) => action();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('processMoveAttempt accepts correct single-move tactic', () {
    final db = TacticsDatabase();
    db.positions.add(_samplePosition());
    final session = TacticsSessionController(database: db)..autoAdvance = false;
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

  test('multi-move tactic: opponent auto-plays after correct user move', () {
    // 3-ply line from the starting position: user plays e4, opponent plays e5,
    // then user plays Nf3. correctLine = ['e4', 'e5', 'Nf3'].
    final db = TacticsDatabase();
    db.positions.add(_samplePosition(line: ['e4', 'e5', 'Nf3']));
    final session = TacticsSessionController(database: db)..autoAdvance = false;
    session.selectPosition(db.positions.first);

    final boardUpdates = <TacticsBoardUpdate>[];
    session.onBoardUpdate = boardUpdates.add;

    // --- Move 1: user plays e4 ---
    final update1 = session.processMoveAttempt(
      moveUci: 'e2e4',
      boardFen: db.positions.first.fen,
      schedule: _immediateSchedule,
      isMounted: () => true,
    );

    expect(update1?.applyMoveUci, 'e2e4', reason: 'user move applied');
    expect(session.positionSolved, isFalse,
        reason: 'not solved yet — opponent + user move remain');

    // The opponent reply (e5) should have been auto-played via onBoardUpdate.
    expect(boardUpdates, hasLength(1), reason: 'opponent auto-replied');
    final oppUpdate = boardUpdates.first;
    expect(oppUpdate.setFen, isNotNull, reason: 'opponent sets FEN');
    expect(oppUpdate.san, 'e5');

    // After opponent reply, it's the user's turn again (index 2).
    expect(session.currentMoveIndex, 2);
    expect(session.waitingForOpponent, isFalse);

    // --- Move 2: user plays Nf3 from the post-opponent FEN ---
    final update2 = session.processMoveAttempt(
      moveUci: 'g1f3',
      boardFen: session.currentTacticFen!,
      schedule: _immediateSchedule,
      isMounted: () => true,
    );

    expect(update2?.applyMoveUci, 'g1f3', reason: 'final user move applied');
    expect(session.positionSolved, isTrue, reason: 'tactic complete');
    expect(session.feedback, 'Correct!');
  });

  test('multi-move tactic: currentTacticFen tracks board through all plies',
      () {
    // 5-ply line: e4, e5, Nf3, Nc6, Bb5.
    final db = TacticsDatabase();
    db.positions.add(_samplePosition(line: ['e4', 'e5', 'Nf3', 'Nc6', 'Bb5']));
    final session = TacticsSessionController(database: db)..autoAdvance = false;
    session.selectPosition(db.positions.first);
    session.onBoardUpdate = (_) {};

    final startFen = db.positions.first.fen;

    // User plays e4 → opponent e5 auto-plays.
    session.processMoveAttempt(
      moveUci: 'e2e4',
      boardFen: startFen,
      schedule: _immediateSchedule,
      isMounted: () => true,
    );
    expect(session.currentMoveIndex, 2);
    final fenAfterE5 = session.currentTacticFen!;
    expect(fenAfterE5, isNot(startFen),
        reason: 'FEN advanced past initial position');

    // User plays Nf3 → opponent Nc6 auto-plays.
    session.processMoveAttempt(
      moveUci: 'g1f3',
      boardFen: fenAfterE5,
      schedule: _immediateSchedule,
      isMounted: () => true,
    );
    expect(session.currentMoveIndex, 4);
    final fenAfterNc6 = session.currentTacticFen!;
    expect(fenAfterNc6, isNot(fenAfterE5),
        reason: 'FEN advanced again after second pair');

    // User plays Bb5 → tactic complete.
    session.processMoveAttempt(
      moveUci: 'f1b5',
      boardFen: fenAfterNc6,
      schedule: _immediateSchedule,
      isMounted: () => true,
    );
    expect(session.positionSolved, isTrue);
    expect(session.currentMoveIndex, 5);
  });
}
