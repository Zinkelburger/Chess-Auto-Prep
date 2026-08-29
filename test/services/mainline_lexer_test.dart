/// Pins `mainlineSansOf` to dartchess: the two must agree on every game, or a
/// file edit looks a line up under a different id than the one the parser
/// assigned it.
library;

import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/pgn_parsing_service.dart';

List<String> _dartchessMainline(String pgn) =>
    PgnGame.parsePgn(pgn).moves.mainline().map((n) => n.san).toList();

void main() {
  const corpus = <String, String>{
    'plain line': '[Event "A"]\n\n1. e4 e5 2. Nf3 Nc6 *\n',
    'no blank line between headers and moves': '[Event "A"]\n1. d4 d5 2. c4 *',
    'moves on the header line': '[Event "A"] [White "x"] 1. e4 c5 2. Nf3 d6 *',
    'comments with brackets and parens inside':
        '[Event "A"]\n\n1. e4 {best (by test) [%eval 0.3] ) (} e5 2. Nf3 '
        '{ another } Nc6 *',
    'nested variations':
        '[Event "A"]\n\n1. e4 (1. d4 d5 (1... Nf6 2. c4 (2. Nf3)) 2. c4) '
        '1... e5 2. Nf3 (2. Bc4 Nf6 (2... Bc5)) Nc6 3. Bb5 *',
    'variation containing a comment with a close paren':
        '[Event "A"]\n\n1. e4 (1. d4 {closes ) here} d5) e5 *',
    'NAGs and glyphs':
        '[Event "A"]\n\n1. e4!? e5?! 2. Nf3!! \$1 Nc6?? \$14 3. Bb5! a6? *',
    'null moves in every spelling':
        '[Event "A"]\n\n1. d4 Z0 2. Nf3 -- 3. c4 0000 4. Nc3 @@@@ 5. e4 *',
    'promotions and checks':
        '[FEN "8/P6k/8/8/8/8/8/K7 w - - 0 1"]\n[SetUp "1"]\n\n1. a8=Q+ Kh6 '
        '2. Qa6+ *',
    'castling with zeros':
        '[Event "A"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. 0-0 Be7 5. d3 0-0 *',
    'queenside castling with zeros and check':
        '[Event "A"]\n\n1. d4 d5 2. Nc3 Nf6 3. Bf4 c6 4. Qd2 Qa5 5. 0-0-0+ *',
    'rest-of-line comment':
        '[Event "A"]\n\n1. e4 e5 ; the open game 2. Nf3\n2. Nf3 Nc6 *',
    'escape line inside the movetext':
        '[Event "A"]\n\n1. e4 e5\n% not a move: 2. d4\n2. Nf3 Nc6 *',
    'multi-line comment':
        '[Event "A"]\n\n1. e4 {a comment\nthat spans\nlines 2. d4} e5 '
        '2. Nf3 *',
    'comment closing at the end of a line then moves':
        '[Event "A"]\n\n1. e4 {spans\nlines}\n1... e5 2. Nf3 *',
    'blank lines inside the movetext':
        '[Event "A"]\n\n1. e4 e5\n\n2. Nf3 Nc6\n\n\n3. Bb5 *',
    'crlf endings':
        '[Event "A"]\r\n[White "x"]\r\n\r\n1. e4 e5\r\n2. Nf3 *\r\n',
    'result in the middle of the text':
        '[Event "A"]\n\n1. e4 e5 1-0 2. Nf3 Nc6 *',
    'escaped quotes in a header value':
        '[Event "the \\"real\\" one"]\n[Site "c:\\\\games"]\n\n1. c4 e5 *',
    'header-like tag inside a comment':
        '[Event "A"]\n\n1. e4 {[Event "fake"]} e5 *',
    'no moves at all': '[Event "A"]\n[Result "*"]\n\n*\n',
    'leading blank lines and a bom':
        '\uFEFF\n\n[Event "A"]\n\n1. Nf3 d5 2. g3 *',
    'header-less text': '1. e4 e5 2. f4 exf4 *',
    'move numbers glued to moves': '[Event "A"]\n\n1.e4 e5 2.Nf3 Nc6 3.Bb5 *',
    'black-first with ellipsis':
        '[FEN "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 2"]\n'
        '[SetUp "1"]\n\n1... Nf6 2. Nc3 *',
    'chessable dummy intro':
        '[Event "A"]\n\n1. Z0 (1. d4 d5 2. c4 e6 3. Nc3) *',
    'drops and piece prefixes': '[Event "A"]\n\n1. N@f3 P@e4 2. e4 *',
    'stray text between moves': '[Event "A"]\n\n1. e4 hello e5 2. Nf3 world *',
    'unterminated comment': '[Event "A"]\n\n1. e4 e5 {never closed 2. Nf3',
  };

  group('mainlineSansOf agrees with dartchess', () {
    corpus.forEach((name, pgn) {
      test(name, () {
        expect(mainlineSansOf(pgn), _dartchessMainline(pgn));
      });
    });
  });

  test('every corpus entry with moves actually yields moves', () {
    // Guards the corpus itself: an entry that dartchess reads as empty would
    // make the equivalence test above pass vacuously.
    final empties = corpus.entries
        .where((e) => _dartchessMainline(e.value).isEmpty)
        .map((e) => e.key)
        .toList();
    expect(empties, ['no moves at all']);
  });
}
