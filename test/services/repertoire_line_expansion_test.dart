/// An imported study is written one game per line, so the trainer and the
/// builder's line list see what the deviation walker sees.
library;

import 'package:chess_auto_prep/services/repertoire_line_expansion.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:flutter_test/flutter_test.dart';

ExpandedPgn expanded(String pgn) => expandVariationsIntoLines(pgn);

void main() {
  const study =
      '[Event "Caro-Kann: Advance"]\n'
      '[Result "*"]\n\n'
      '1. e4 c6 2. d4 d5 3. e5 Bf5 4. Nf3 (4. Nc3 e6 5. g4 Bg6) '
      '(4. h4 h5) 4... e6 5. Be2 c5 (5... Ne7) *\n';

  test('every bracketed variation becomes a game of its own', () {
    final expanded = expandVariationsIntoLines(study);
    expect(expanded.gameCount, 4);

    final lines = RepertoireService().parseRepertoirePgn(expanded.pgn);
    expect(
      [for (final l in lines) l.moves.join(' ')],
      [
        'e4 c6 d4 d5 e5 Bf5 Nf3 e6 Be2 c5',
        'e4 c6 d4 d5 e5 Bf5 Nf3 e6 Be2 Ne7',
        'e4 c6 d4 d5 e5 Bf5 Nc3 e6 g4 Bg6',
        'e4 c6 d4 d5 e5 Bf5 h4 h5',
      ],
      reason: 'mainline first, then sidelines in bracket order',
    );
    expect(expanded.pgn, isNot(contains('(')), reason: 'no brackets remain');
  });

  test('sidelines are named after the move that leaves the mainline', () {
    final lines = RepertoireService().parseRepertoirePgn(
      expandVariationsIntoLines(study).pgn,
    );
    expect(
      [for (final l in lines) l.name],
      [
        'Caro-Kann: Advance',
        'Caro-Kann: Advance — 5...Ne7',
        'Caro-Kann: Advance — 4.Nc3',
        'Caro-Kann: Advance — 4.h4',
      ],
    );
    expect(lines.map((l) => l.id).toSet().length, 4, reason: 'distinct ids');
  });

  test('sidelines record the plies where they left the mainline', () {
    final lines = RepertoireService().parseRepertoirePgn(
      expandVariationsIntoLines(study).pgn,
    );
    expect(
      lines[0].branchPlies,
      isEmpty,
      reason: 'the mainline branches nowhere',
    );
    // 5...Ne7 is the second child at ply 9; 4.Nc3 and 4.h4 at ply 6.
    expect(lines[1].branchPlies, [9]);
    expect(lines[2].branchPlies, [6]);
    expect(lines[3].branchPlies, [6]);
    expect(expanded(study).pgn, contains('[BranchPlies "6"]'));
    // Who the bracket belonged to, read for each side: 4.Nc3 is White's
    // alternative (commentary in a White book, coverage in a Black one).
    expect(lines[2].firstBranchOnSide(white: true), 6);
    expect(lines[2].firstBranchOnSide(white: false), isNull);
    expect(lines[1].firstBranchOnSide(white: false), 9);
  });

  test('the branch label goes on the title header, not the chapter', () {
    // An export with the chapter in [Black] and the line title in [White]:
    // the sideline's label belongs on the title, or every sideline becomes
    // a chapter of its own.
    const pgn =
        '[Event "?"]\n[White "Caro-Kann 4...Bf5 #1"]\n[Black "31) Caro-Kann"]\n'
        '[Result "*"]\n\n1. e4 c6 2. d4 d5 3. Nc3 (3. e5 Bf5) 3... dxe4 *\n\n'
        '[Event "?"]\n[White "Caro-Kann 4...Bf5 #2"]\n[Black "31) Caro-Kann"]\n'
        '[Result "*"]\n\n1. e4 c6 2. d4 d5 3. Nc3 dxe4 4. Nxe4 *\n\n'
        '[Event "?"]\n[White "French #1"]\n[Black "30) French"]\n'
        '[Result "*"]\n\n1. e4 e6 *\n';
    final lines = RepertoireService().parseRepertoirePgn(
      expandVariationsIntoLines(pgn).pgn,
    );
    expect(lines.map((l) => l.chapter).toSet(), {
      '31) Caro-Kann',
      '30) French',
    });
    expect(lines[1].name, 'Caro-Kann 4...Bf5 #1 — 3.e5');
  });

  test('under an Event chapter the branch label goes on White', () {
    const pgn =
        '[Event "12. Fianchetto"]\n[White "9.Nd2 e6"]\n[Black "?"]\n'
        '[Result "*"]\n\n1. d4 Nf6 2. c4 g6 3. g3 (3. Nc3 d5) 3... Bg7 *\n\n'
        '[Event "12. Fianchetto"]\n[White "9.Qd3 a6"]\n[Black "?"]\n'
        '[Result "*"]\n\n1. d4 Nf6 2. c4 g6 3. g3 Bg7 4. Bg2 *\n\n'
        '[Event "33. Veresov"]\n[White "3.Bg5"]\n[Black "?"]\n'
        '[Result "*"]\n\n1. d4 Nf6 2. Nc3 d5 *\n';
    final lines = RepertoireService().parseRepertoirePgn(
      expandVariationsIntoLines(pgn).pgn,
    );
    expect(lines.map((l) => l.chapter).toSet(), {
      '12. Fianchetto',
      '33. Veresov',
    });
    expect(lines[1].name, '9.Nd2 e6 — 3.Nc3');
  });

  test('the same line under two chapter titles is kept once', () {
    // A course export that lists every line under every chapter.
    const pgn =
        '[Event "?"]\n[White "A"]\n[Black "Line 1"]\n[Result "*"]\n\n'
        '1. e4 e5 *\n\n'
        '[Event "?"]\n[White "A"]\n[Black "Line 2"]\n[Result "*"]\n\n'
        '1. d4 d5 *\n\n'
        '[Event "?"]\n[White "B"]\n[Black "Line 1"]\n[Result "*"]\n\n'
        '1. e4  e5 *\n\n'
        '[Event "?"]\n[White "B"]\n[Black "Line 2"]\n[Result "*"]\n\n'
        '1. d4 d5 *\n';
    final expanded = expandVariationsIntoLines(pgn);
    expect(expanded.gameCount, 2);
    final lines = RepertoireService().parseRepertoirePgn(expanded.pgn);
    expect(lines.map((l) => l.headers['Black']), ['Line 1', 'Line 2']);
    // The same moves under a different title are two lines.
    const twoTitles =
        '[Event "?"]\n[Black "Line 1"]\n[Result "*"]\n\n1. e4 e5 *\n\n'
        '[Event "?"]\n[Black "Line 2"]\n[Result "*"]\n\n1. e4 e5 *\n';
    expect(expandVariationsIntoLines(twoTitles).gameCount, 2);
  });

  test('a nested bracket records every branch on its path', () {
    const nested =
        '[Event "N"]\n[Result "*"]\n\n'
        '1. e4 e5 (1... c5 2. Nf3 (2. c3 d5) 2... d6) 2. Nf3 *\n';
    final lines = RepertoireService().parseRepertoirePgn(
      expandVariationsIntoLines(nested).pgn,
    );
    expect(
      [for (final l in lines) l.branchPlies],
      [
        <int>[],
        [1],
        [1, 2],
      ],
    );
  });

  test('only the mainline keeps the game\'s own id header', () {
    const withId =
        '[Event "Line"]\n[LineID "abc"]\n[Result "*"]\n\n'
        '1. d4 d5 (1... Nf6) *\n';
    final lines = RepertoireService().parseRepertoirePgn(
      expandVariationsIntoLines(withId).pgn,
    );
    expect(lines.map((l) => l.id).toList(), ['abc', isNot('abc')]);
  });

  test('comments, glyphs and the start position travel with each line', () {
    const annotated =
        '[Event "Endgame"]\n'
        '[FEN "8/8/4k3/8/8/4K3/4P3/8 w - - 0 1"]\n'
        '[SetUp "1"]\n'
        '[Result "*"]\n\n'
        '{ Opposition. } 1. Kd4 { Take the opposition } (1. Kf4!? Kf6) '
        '1... Kd6 *\n';
    final expanded = expandVariationsIntoLines(annotated);
    expect(expanded.gameCount, 2);
    final lines = RepertoireService().parseRepertoirePgn(expanded.pgn);
    expect(lines[0].comments['0'], 'Take the opposition');
    expect(lines[0].startPosition.fen, startsWith('8/8/4k3/8/8/4K3/4P3/8 w'));
    expect(lines[1].moves, ['Kf4', 'Kf6']);
    expect(lines[1].name, 'Endgame — 1.Kf4');
    expect(expanded.pgn, contains('\$5'), reason: 'the !? glyph survives');
    expect(
      expanded.pgn,
      contains('{ Opposition. }'),
      reason: 'the game comment survives',
    );
  });

  test('a file that is already one game per line comes back untouched', () {
    const plain =
        '// Color: White\n\n'
        '[Event "A"]\n\n1. d4 d5 2. Bf4 *\n\n'
        '[Event "B"]\n\n1. d4 Nf6 2. Bf4 *\n';
    final expanded = expandVariationsIntoLines(plain);
    expect(identical(expanded.pgn, plain), isTrue);
    expect(expanded.gameCount, 2);
  });

  test('games without variations are copied through beside expanded ones', () {
    const mixed =
        '// Color: White\n\n'
        '[Event "A"]\n\n1. d4 d5 2. Bf4 *\n\n'
        '[Event "B"]\n\n1. d4 Nf6 2. Bf4 (2. c4) *\n';
    final expanded = expandVariationsIntoLines(mixed);
    expect(expanded.gameCount, 3);
    expect(expanded.pgn, startsWith('// Color: White\n'));
    expect(expanded.pgn, contains('[Event "A"]\n\n1. d4 d5 2. Bf4 *\n'));
    final lines = RepertoireService().parseRepertoirePgn(expanded.pgn);
    expect(lines.map((l) => l.name).toList(), ['A', 'B', 'B — 2.c4']);
    expect(lines.map((l) => l.color).toSet(), {'white'});
  });

  test('a complete game keeps its analysis in brackets', () {
    const modelGame =
        '[Event "Bertok - Fischer"]\n[Result "0-1"]\n\n'
        '1. d4 Nf6 2. c4 e6 (2... g6) 3. Nf3 *\n';
    final expanded = expandVariationsIntoLines(modelGame);
    expect(expanded.gameCount, 1);
    expect(identical(expanded.pgn, modelGame), isTrue);
  });

  test('a variation before the first move is a line too', () {
    const twoFirstMoves = '[Event "Openers"]\n\n1. e4 (1. d4 d5) 1... e5 *\n';
    final lines = RepertoireService().parseRepertoirePgn(
      expandVariationsIntoLines(twoFirstMoves).pgn,
    );
    expect(lines.map((l) => l.moves.join(' ')).toList(), ['e4 e5', 'd4 d5']);
    expect(lines[1].name, 'Openers — 1.d4');
  });

  test('header-less pasted moves expand like any other game', () {
    final expanded = expandVariationsIntoLines('1. e4 e5 (1... c5) 2. Nf3 *');
    expect(expanded.gameCount, 2);
    final lines = RepertoireService().parseRepertoirePgn(expanded.pgn);
    expect(lines.map((l) => l.moves.join(' ')).toList(), [
      'e4 e5 Nf3',
      'e4 c5',
    ]);
  });
}
