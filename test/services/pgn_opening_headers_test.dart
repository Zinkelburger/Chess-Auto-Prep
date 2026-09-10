import 'package:flutter_test/flutter_test.dart';
import 'package:dartchess/dartchess.dart';
import 'package:chess_auto_prep/core/pgn/pgn_collection_helpers.dart';
import 'package:chess_auto_prep/services/opening_book_service.dart';
import 'package:chess_auto_prep/services/pgn_opening_headers.dart';
import 'package:chess_auto_prep/services/pgn_parsing_service.dart';

void main() {
  test(
    'fills missing tags preserving all movetext and authoritative headers',
    () {
      const moves = '{Intro} 1. e4! {Keep me} e5 (1... c5 2. Nf3) 2. Nf3 *';
      final game = parseMultiGamePgn(
        '[ECO "C20"]\n[Opening "?"]\n\n$moves',
      ).single;
      const opening = OpeningBookEntry(
        eco: 'C40',
        name: 'King’s "Knight"',
        ply: 3,
      );
      expect(fillOpeningHeaders(game, opening), isTrue);
      expect(game.headers['ECO'], 'C20');
      expect(PgnGame.parsePgn(game.pgnText).headers['Opening'], opening.name);
      expect(game.pgnText.substring(movetextStart(game.pgnText)), moves);
      expect(RegExp(r'\[Opening ').allMatches(game.pgnText), hasLength(1));
      final saved = game.pgnText;
      expect(fillOpeningHeaders(game, opening), isFalse);
      expect(game.pgnText, saved);
    },
  );

  test('classifies mainline positions and transpositions, ignoring sidelines', () {
    final book = OpeningBook(
      buildOpeningBookFromTsv([
        'eco\tname\tpgn\n'
            'C20\tKing Pawn\t1. e4 e5\n'
            'B90\tNajdorf\t1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6\n'
            'D30\tQueen Gambit\t1. d4 d5 2. c4 e6 3. Nc3 Nf6\n',
      ]),
    );
    final games = [
      '[White "A"]\n\n1. e4 e5 (1... c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6) *',
      '[White "B"]\n\n1. d4 Nf6 2. c4 e6 3. Nc3 d5 *',
      '[White "C"]\n\n*',
    ].map((text) => (headers: extractHeaders(text), pgnText: text)).toList();
    final matches = classifyMainlineOpenings((book: book, games: games));
    expect(matches.map((entry) => entry?.eco), ['C20', 'D30', null]);
  });
}
