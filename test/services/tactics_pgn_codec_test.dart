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
      expect(encoded.fallback, 0);
      expect(encoded.dropped, 0);
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

    test('SourceMovetext survives encode → decode', () {
      final puzzle = _puzzle(
        fen:
            'r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4',
        line: ['Qxf7#'],
      ).copyWith(sourceMovetext: '1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7#');

      final encoded = encodePuzzlesToPgn('Test Set', [puzzle]);
      expect(encoded.pgn, contains('[SourceMovetext '));

      final decoded = decodePuzzlesFromPgn(encoded.pgn);
      expect(decoded.puzzles, hasLength(1));
      expect(
        decoded.puzzles[0].sourceMovetext,
        '1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7#',
      );
    });

    test('missing SourceMovetext decodes to empty (legacy puzzles)', () {
      final puzzle = _puzzle(
        fen: '6k1/5ppp/8/8/8/8/r7/6K1 b - - 0 1',
        line: ['Ra1+', 'Kh2', 'Ra2'],
      );
      final encoded = encodePuzzlesToPgn('Test Set', [puzzle]);
      expect(encoded.pgn, isNot(contains('SourceMovetext')));

      final decoded = decodePuzzlesFromPgn(encoded.pgn);
      expect(decoded.puzzles[0].sourceMovetext, '');
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

    test('stats and provenance survive via custom headers (lossless)', () {
      final puzzle = TacticsPosition(
        fen:
            'r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4',
        userMove: 'd3',
        correctLine: const ['Qxf7#'],
        solutionPv: const ['Qxf7#'],
        mistakeType: '??',
        mistakeAnalysis: 'Missed the mate.',
        positionContext: 'Move 4, White to play',
        gameWhite: 'Me',
        gameBlack: 'Them',
        gameResult: '0-1',
        gameDate: '2026.07.01',
        gameId: 'abc123',
        gameUrl: 'https://lichess.org/abc123',
        lastReviewed: DateTime.utc(2026, 7, 2, 10, 30),
        reviewCount: 4,
        successCount: 3,
        timeToSolve: 12.5,
        hintsUsed: 2,
        opponentBestResponse: 'Qxe4',
        rating: 3,
      );

      final encoded = encodePuzzlesToPgn('S', [puzzle]);
      final decoded = decodePuzzlesFromPgn(encoded.pgn);
      expect(decoded.errors, isEmpty);
      final out = decoded.puzzles.single;

      expect(out.fen, puzzle.fen);
      expect(out.userMove, 'd3');
      expect(out.mistakeType, '??');
      expect(out.mistakeAnalysis, 'Missed the mate.');
      expect(out.gameWhite, 'Me');
      expect(out.gameBlack, 'Them');
      expect(out.gameDate, '2026.07.01');
      expect(out.gameId, 'abc123');
      expect(out.gameUrl, 'https://lichess.org/abc123');
      expect(out.lastReviewed, DateTime.utc(2026, 7, 2, 10, 30));
      expect(out.reviewCount, 4);
      expect(out.successCount, 3);
      expect(out.timeToSolve, 12.5);
      expect(out.hintsUsed, 2);
      expect(out.opponentBestResponse, 'Qxe4');
      expect(out.rating, 3);
    });

    test('longer solution PV rides in a header, mainline stays trainable', () {
      final puzzle = _puzzle(
        fen: '6k1/5ppp/8/8/8/8/r7/6K1 b - - 0 1',
        line: ['Ra1+'],
      ).copyWith(solutionPv: ['Ra1+', 'Kh2', 'Ra2+']);

      final encoded = encodePuzzlesToPgn('S', [puzzle]);
      expect(encoded.pgn, contains('[SolutionPv "Ra1+ Kh2 Ra2+"]'));

      final decoded = decodePuzzlesFromPgn(encoded.pgn);
      final out = decoded.puzzles.single;
      expect(out.correctLine, ['Ra1+']);
      expect(out.solutionPv, ['Ra1+', 'Kh2', 'Ra2+']);
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

    test('games without FEN are skipped and reported, others still import', () {
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

  group('reviewing arbitrary PGN (studies)', () {
    test('requireFen: false treats a header-less game as standard start', () {
      const pgn = '''
[Event "Italian ideas"]

1. e4 {The start of the plan} e5 2. Nf3 *
''';
      expect(decodePuzzlesFromPgn(pgn).puzzles, isEmpty);

      final decoded = decodePuzzlesFromPgn(pgn, requireFen: false);
      expect(decoded.errors, isEmpty);
      final puzzle = decoded.puzzles.single;
      expect(puzzle.correctLine, ['e4', 'e5', 'Nf3']);
      expect(puzzle.mistakeAnalysis, 'The start of the plan');
      expect(puzzle.positionContext, 'Move 1, White to play');
    });
  });

  group('patchStatsInPgn', () {
    const studyPgn = '''
[Event "Chapter 1"]
[FEN "6k1/5ppp/8/8/8/8/r7/6K1 b - - 0 1"]
[SetUp "1"]
[Annotator "Coach"]

1... Ra1+ {Back rank!} (1... h5 2. Kg2) 2. Kh2 Ra2 *

[Event "Chapter 2"]
[FEN "r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4"]
[SetUp "1"]
[StarRating "1"]

4. Qxf7# *
''';

    test('updates stat headers only, preserving variations and headers', () {
      final puzzles = decodePuzzlesFromPgn(studyPgn).puzzles;
      final reviewed = puzzles[0].copyWith(
        reviewCount: 2,
        successCount: 1,
        lastReviewed: DateTime.utc(2026, 7, 8),
        rating: 4,
      );

      final patched = patchStatsInPgn(studyPgn, [reviewed, puzzles[1]]);

      // Stats landed on chapter 1.
      expect(patched, contains('[ReviewCount "2"]'));
      expect(patched, contains('[SuccessCount "1"]'));
      expect(patched, contains('[StarRating "4"]'));
      // Everything else untouched: variation, comment, foreign header,
      // chapter 2's existing rating.
      expect(patched, contains('(1... h5 2. Kg2)'));
      expect(patched, contains('{Back rank!}'));
      expect(patched, contains('[Annotator "Coach"]'));
      expect(patched, contains('[StarRating "1"]'));
      // Round-trips through the decoder with the new stats.
      final reDecoded = decodePuzzlesFromPgn(patched).puzzles;
      expect(reDecoded[0].reviewCount, 2);
      expect(reDecoded[0].rating, 4);
      expect(reDecoded[1].rating, 1);
    });

    test('replaces stale stat headers instead of duplicating them', () {
      final puzzles = decodePuzzlesFromPgn(studyPgn).puzzles;
      final rerated = puzzles[1].copyWith(rating: 5);

      final patched = patchStatsInPgn(studyPgn, [rerated]);

      expect(patched, contains('[StarRating "5"]'));
      expect(patched, isNot(contains('[StarRating "1"]')));
    });

    test('content without [Event] headers is left untouched', () {
      const bare = '''
[FEN "6k1/5ppp/8/8/8/8/r7/6K1 b - - 0 1"]
[SetUp "1"]

1... Ra1+ *
''';
      final puzzles = decodePuzzlesFromPgn(bare).puzzles;
      final reviewed = puzzles.single.copyWith(reviewCount: 1);
      expect(patchStatsInPgn(bare, [reviewed]), bare);
    });
  });

  group('buildSolutionMovetext numbering', () {
    test('white to move numbering', () {
      expect(
        buildSolutionMovetext(
          'r1bqkb1r/pppp1ppp/2n2n2/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4',
          ['Qxf7#'],
        ),
        '4. Qxf7# *',
      );
    });

    test('black to move gets ellipsis and increments correctly', () {
      expect(
        buildSolutionMovetext('6k1/5ppp/8/8/8/8/r7/6K1 b - - 0 10', [
          'Ra1+',
          'Kh2',
          'Ra2',
        ]),
        '10... Ra1+ 11. Kh2 Ra2 *',
      );
    });
  });

  group('decode: onlyGame and includeVariations', () {
    // Two standard-start chapters; chapter 2 has an opponent deviation
    // (2... d6 instead of 2... Nc6) with a solver reply, and a solver
    // alternative on move 1 (1. d4) that collides with the chapter start.
    const study = '''
[Event "Chapter 1"]

1. e4 e5 2. Nf3 *

[Event "Chapter 2"]

1. e4 (1. d4 d5) 1... e5 2. Nf3 Nc6 (2... d6 {Philidor} 3. d4) 3. Bb5 *
''';

    test('onlyGame restricts decoding to that chapter', () {
      final decoded = decodePuzzlesFromPgn(
        study,
        requireFen: false,
        onlyGame: 1,
      );
      expect(decoded.puzzles, hasLength(1));
      expect(decoded.puzzles.single.correctLine, [
        'e4',
        'e5',
        'Nf3',
        'Nc6',
        'Bb5',
      ]);
    });

    test('includeVariations expands lines into extra cards', () {
      final decoded = decodePuzzlesFromPgn(
        study,
        requireFen: false,
        includeVariations: true,
        onlyGame: 1,
      );
      // Mainline + Philidor variation; the 1. d4 line shares the chapter
      // start position with the mainline card and is skipped.
      expect(decoded.puzzles, hasLength(2));
      expect(decoded.errors, hasLength(1));
      expect(decoded.errors.single, contains('same position'));

      final variation = decoded.puzzles[1];
      // Opponent deviation (2... d6) is auto-advanced: the card starts with
      // the solver to move in the Philidor position and asks for 3. d4.
      expect(variation.correctLine, ['d4']);
      expect(variation.fen, contains(' w ')); // solver (White) to move
      expect(variation.positionContext, startsWith('Variation'));
      expect(variation.mistakeAnalysis, 'Philidor');
      expect(variation.reviewCount, 0);
      // Distinct FEN from the mainline card — stats never collide.
      expect(variation.fen, isNot(decoded.puzzles[0].fen));
    });

    test('variation cards do not disturb stat patching', () {
      final decoded = decodePuzzlesFromPgn(
        study,
        requireFen: false,
        includeVariations: true,
      );
      final reviewed = [
        for (final p in decoded.puzzles) p.copyWith(reviewCount: 3),
      ];
      final patched = patchStatsInPgn(study, reviewed);
      // Both chapters get stats (matched by FEN header default); variation
      // cards match no game header, so movetext stays intact.
      expect(RegExp(r'\[ReviewCount "3"\]').allMatches(patched).length, 2);
      expect(patched, contains('(2... d6 {Philidor} 3. d4)'));
      expect(patched, contains('(1. d4 d5)'));
    });
  });
}
