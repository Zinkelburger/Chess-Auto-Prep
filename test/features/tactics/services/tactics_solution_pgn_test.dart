import 'package:chess_auto_prep/features/documents/repositories/stored_game_repository.dart';
import 'package:chess_auto_prep/features/tactics/models/tactics_position.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_solution_pgn.dart';
import 'package:flutter_test/flutter_test.dart';

TacticsPosition _tactic({required String fen}) => TacticsPosition(
  fen: fen,
  gameWhite: 'Alice "Ace"',
  gameBlack: 'Bob',
  gameResult: '1-0',
  gameDate: '2024.01.01',
  gameId: 'g1',
  userMove: 'd4',
  correctLine: const ['e4'],
  mistakeType: '?',
  mistakeAnalysis: 'test',
);

class _Archive implements StoredGameRepository {
  _Archive(this.lookup);
  final Future<String?> Function(String) lookup;
  @override
  Future<String?> findById(String id) => lookup(id);
}

void main() {
  test(
    'source-game actions use the injected archive before the solution',
    () async {
      final tactic = _tactic(
        fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
      );
      final pgn = await sourceGamePgn(
        tactic,
        ['e4'],
        storedGames: _Archive((id) async {
          expect(id, 'g1');
          return '1. d4 d5 *';
        }),
      );
      expect(pgn, '1. d4 d5 *');
    },
  );

  for (final unavailable in [false, true]) {
    test(
      'source-game action retains its solution when archive ${unavailable ? "fails" : "has no game"}',
      () async {
        final tactic = _tactic(
          fen: 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
        );
        final pgn = await sourceGamePgn(
          tactic,
          ['e4'],
          storedGames: _Archive((id) async {
            if (unavailable) throw StateError('offline');
            return null;
          }),
        );
        expect(pgn, buildSolutionPgn(tactic, ['e4']));
      },
    );
  }

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
