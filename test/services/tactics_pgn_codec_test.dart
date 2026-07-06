import 'package:chess_auto_prep/models/tactics_position.dart';
import 'package:chess_auto_prep/services/tactics_pgn_codec.dart';
import 'package:flutter_test/flutter_test.dart';

TacticsPosition _puzzle({
  required String fen,
  required List<String> line,
  String note = '',
  String white = 'A',
  String black = 'B',
}) {
  return TacticsPosition(
    fen: fen,
    userMove: '',
    correctLine: line,
    mistakeType: 'custom',
    mistakeAnalysis: note,
    positionContext: 'Move 1, White to play',
    gameWhite: white,
    gameBlack: black,
    gameResult: '*',
    gameDate: '2026.07.06',
    gameId: '',
  );
}

void main() {
  group('encode → decode round-trip', () {
    test('fen, solution line, and note survive', () {
      final puzzles = [
        _puzzle(
          // White mates: Qxf7#
          fen:
              'r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4',
          line: ['Qxf7#'],
          note: 'Scholar\'s mate — f7 is only defended by the king.',
        ),
        _puzzle(
          // Black to move: back-rank mate in 2.
          fen: '6k1/5ppp/8/8/8/8/r7/6K1 b - - 0 1',
          line: ['Ra1+', 'Kh2', 'Ra2'],
          note: 'Cut the king off.',
        ),
      ];

      final encoded = encodePuzzlesToPgn('Test Set', puzzles);
      expect(encoded.encoded, 2);
      expect(encoded.skipped, 0);
      expect(encoded.pgn, contains('[Event "Test Set #1"]'));
      expect(encoded.pgn, contains('[SetUp "1"]'));

      final decoded = decodePuzzlesFromPgn(encoded.pgn);
      expect(decoded.errors, isEmpty);
      expect(decoded.puzzles, hasLength(2));

      expect(decoded.puzzles[0].fen, puzzles[0].fen);
      expect(decoded.puzzles[0].correctLine, ['Qxf7#']);
      expect(decoded.puzzles[0].mistakeAnalysis, contains('Scholar'));
      expect(decoded.puzzles[0].mistakeType, 'custom');
      expect(decoded.puzzles[0].gameWhite, 'A');

      // Note: encoding canonicalizes SAN — 'Ra2' is check here, so it
      // round-trips as 'Ra2+'.
      expect(decoded.puzzles[1].correctLine, ['Ra1+', 'Kh2', 'Ra2+']);
      expect(decoded.puzzles[1].positionContext, 'Move 1, Black to play');
    });

    test('UCI-encoded correctLine is exported as SAN', () {
      final puzzle = _puzzle(
        fen:
            'r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4',
        line: ['h5f7'], // UCI in storage
      );
      final encoded = encodePuzzlesToPgn('S', [puzzle]);
      expect(encoded.pgn, contains('Qxf7#'));
      expect(encoded.pgn, isNot(contains('h5f7')));
    });

    test('braces in notes are sanitized so the PGN stays parseable', () {
      final puzzle = _puzzle(
        fen: '6k1/5ppp/8/8/8/8/r7/6K1 b - - 0 1',
        line: ['Ra1+'],
        note: 'weird {braces} in note',
      );
      final encoded = encodePuzzlesToPgn('S', [puzzle]);
      final decoded = decodePuzzlesFromPgn(encoded.pgn);
      expect(decoded.errors, isEmpty);
      expect(decoded.puzzles.single.mistakeAnalysis, contains('braces'));
    });
  });

  group('decoding external PGN', () {
    test('hand-written puzzle PGN with comment on the first move', () {
      const pgn = '''
[Event "Coach set"]
[White "Student"]
[Black "Coach"]
[FEN "6k1/5ppp/8/8/8/8/r7/6K1 b - - 0 1"]
[SetUp "1"]
[Result "*"]

1... Ra1+ {Back rank!} 2. Kh2 Ra2 *
''';
      final decoded = decodePuzzlesFromPgn(pgn);
      expect(decoded.errors, isEmpty);
      final puzzle = decoded.puzzles.single;
      expect(puzzle.correctLine, ['Ra1+', 'Kh2', 'Ra2']);
      expect(puzzle.mistakeAnalysis, 'Back rank!');
      expect(puzzle.gameWhite, 'Student');
    });

    test('games without FEN are skipped and reported, others still import',
        () {
      const pgn = '''
[Event "Normal game"]

1. e4 e5 *

[Event "Real puzzle"]
[FEN "6k1/5ppp/8/8/8/8/r7/6K1 b - - 0 1"]
[SetUp "1"]

1... Ra1+ *
''';
      final decoded = decodePuzzlesFromPgn(pgn);
      expect(decoded.puzzles, hasLength(1));
      expect(decoded.errors, hasLength(1));
      expect(decoded.errors.single, contains('no [FEN]'));
    });

    test('malformed movetext is skipped without failing the file', () {
      const pgn = '''
[Event "Broken"]
[FEN "6k1/5ppp/8/8/8/8/r7/6K1 b - - 0 1"]
[SetUp "1"]

1... Rz9+ *

[Event "Fine"]
[FEN "6k1/5ppp/8/8/8/8/r7/6K1 b - - 0 1"]
[SetUp "1"]

1... Ra1+ *
''';
      final decoded = decodePuzzlesFromPgn(pgn);
      expect(decoded.puzzles, hasLength(1));
      expect(decoded.puzzles.single.correctLine, ['Ra1+']);
      expect(decoded.errors, hasLength(1));
    });
  });

  group('buildMovetext numbering', () {
    test('white to move numbering', () {
      expect(
        buildMovetext(
            'r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4',
            ['Qxf7#']),
        '4. Qxf7# *',
      );
    });

    test('black to move gets ellipsis and increments correctly', () {
      expect(
        buildMovetext('6k1/5ppp/8/8/8/8/r7/6K1 b - - 0 10',
            ['Ra1+', 'Kh2', 'Ra2']),
        '10... Ra1+ 11. Kh2 Ra2 *',
      );
    });
  });
}
