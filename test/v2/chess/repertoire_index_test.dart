import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/repertoire_index.dart';
import 'package:flutter_test/flutter_test.dart';

/// Three lines, two of them reaching the position after 2...e6 by the other
/// move order and both playing 3.Nc3 there.
const transposed = '''
// Color: White

[Event "Queen's Gambit"]
[Result "*"]

1. d4 Nf6 2. c4 e6 3. Nc3 *

[Event "English"]
[Result "*"]

1. c4 Nf6 2. d4 e6 3. Nc3 d5 *

[Event "English"]
[Result "*"]

1. c4 Nf6 2. d4 e6 3. Nf3 *
''';

/// One line that comes back to the start and plays 1.Nf3 again.
const repeated = '''
// Color: White

[Event "Back and forth"]
[Result "*"]

1. Nf3 Nf6 2. Ng1 Ng8 3. Nf3 d5 *
''';

RepertoireIndex indexed(String text) {
  final chapter = parseChapter(name: 'Test', text: text);
  return RepertoireIndex.of(chapter.tree, chapter.side);
}

/// After 1.d4 Nf6 2.c4 e6, or 1.c4 Nf6 2.d4 e6.
const afterE6 = 'rnbqkb1r/pppp1ppp/4pn2/8/2PP4/8/PP2PPPP/RNBQKBNR w KQkq - 0 3';

void main() {
  test('a move counts the lines of every move order that plays it', () {
    final index = indexed(transposed);
    final here = index.movesAt(const Fen(afterE6).position)!;
    expect(here['b1c3']!.lines, 2);
    expect(here['g1f3']!.lines, 1);
    // It is read where the file first plays it.
    expect(here['b1c3']!.sans, ['d4', 'Nf6', 'c4', 'e6', 'Nc3']);
    final start = index.movesAt(Fen.initial.position)!;
    expect(start['d2d4']!.lines, 1);
    expect(start['c2c4']!.lines, 2);
  });

  test('a line that plays a move again from the same position counts '
      'once', () {
    final start = indexed(repeated).movesAt(Fen.initial.position)!;
    expect(start['g1f3']!.lines, 1);
    expect(start.keys, ['g1f3']);
  });
}
