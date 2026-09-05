/// An imported study is written one game per line, so the trainer and the
/// builder's line list see what the deviation walker sees.
library;

import 'package:chess_auto_prep/services/repertoire_line_expansion.dart';
import 'package:chess_auto_prep/services/repertoire_service.dart';
import 'package:flutter_test/flutter_test.dart';

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
