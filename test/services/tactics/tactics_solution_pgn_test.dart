import 'package:chess_auto_prep/models/tactics_position.dart';
import 'package:chess_auto_prep/services/tactics/tactics_solution_pgn.dart';
import 'package:flutter_test/flutter_test.dart';

TacticsPosition _tactic({required String fen}) => TacticsPosition(
  fen: fen,
  gameWhite: 'Alice "Ace"',
  gameBlack: 'Bob',
  gameResult: '1-0',
  gameDate: '2024.01.01',
  gameId: 'g1',
  positionContext: 'Move 1 — White to play',
  userMove: 'd4',
  correctLine: const ['e4'],
  mistakeType: '?',
  mistakeAnalysis: 'test',
);

void main() {
  test('numbers moves from a white-to-move position', () {
    final pgn = buildSolutionPgn(
      _tactic(fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'),
      ['e4', 'e5', 'Nf3'],
    );
    expect(pgn, contains('1. e4 e5 2. Nf3 *'));
    expect(pgn, contains('[SetUp "1"]'));
    expect(pgn, contains('[FEN "rnbqkbnr'));
  });

  test('starts with ellipsis when black is to move', () {
    final pgn = buildSolutionPgn(
      _tactic(
        fen: 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 3',
      ),
      ['e5', 'Nf3'],
    );
    expect(pgn, contains('3... e5 4. Nf3 *'));
  });

  test('escapes quotes in player names and ends with * when no moves', () {
    final pgn = buildSolutionPgn(
      _tactic(fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1'),
      const [],
    );
    expect(pgn, contains(r'[White "Alice \"Ace\""]'));
    expect(pgn.trimRight(), endsWith('*'));
  });

  group('buildSourceGamePgn', () {
    test('reconstructs a full game from stored source movetext', () {
      final tactic = _tactic(
        fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      ).copyWith(sourceMovetext: '1. e4 e5 2. Nf3 Nc6');
      final pgn = buildSourceGamePgn(tactic);

      // Game headers (no [FEN]/[SetUp] — it starts from the standard position)
      // and the full movetext ending with the game result.
      expect(pgn, contains(r'[White "Alice \"Ace\""]'));
      expect(pgn, contains('[Black "Bob"]'));
      expect(pgn, contains('[Result "1-0"]'));
      expect(pgn, isNot(contains('[SetUp')));
      expect(pgn, isNot(contains('[FEN')));
      expect(pgn, contains('1. e4 e5 2. Nf3 Nc6 1-0'));
    });

    test('returns empty when no source movetext was captured', () {
      final tactic = _tactic(
        fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      );
      expect(buildSourceGamePgn(tactic), isEmpty);
    });
  });
}
