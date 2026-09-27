import 'package:chess_auto_prep/v2/chess/book/book_check.dart';
import 'package:chess_auto_prep/v2/chess/book/played_game.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/repertoire_index.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

/// A White Sicilian file: 2.Nf3 and 3.d4, with 2...d6 answered and
/// 2...e6 answered by 3.d4 too.
const openSicilian = '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 *

[Event "Open"]
[Result "*"]

1. e4 c5 2. Nf3 e6 3. d4 *
''';

/// A second White file that also answers 1...c5, with 2.c3 in one line.
const alapin = '''
// Color: White

[Event "Alapin"]
[Result "*"]

1. e4 c5 2. c3 d5 *
''';

/// A Black file against 1.e4.
const najdorf = '''
// Color: Black

[Event "Najdorf"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 *
''';

BookFile book(String text, String name) {
  final chapter = parseChapter(name: name, text: text);
  return BookFile(
    path: '/books/$name.pgn',
    name: name,
    index: RepertoireIndex.of(chapter.tree, chapter.side),
  );
}

/// A game of "Me"'s with [side], [moves] its movetext.
PlayedGame game(String moves, {Side side = Side.white, String result = '*'}) {
  final white = side == Side.white ? 'Me' : 'Rival';
  final black = side == Side.white ? 'Rival' : 'Me';
  final text =
      '[White "$white"]\n[Black "$black"]\n[Result "$result"]\n\n$moves $result';
  return readPlayedGame(text, index: 0, username: 'me')!;
}

void main() {
  final white = [book(openSicilian, 'Open'), book(alapin, 'Alapin')];

  test('the user\'s own move the book does not play is theirs to fix', () {
    final verdict = checkGame(game('1. e4 c5 2. Nc3'), white) as LeftBook;
    expect(verdict.kind, Deviation.mine);
    expect(verdict.ply, 2);
    expect(verdict.played, '2.Nc3');
    // Both files answer 1...c5; the one with more lines comes first.
    expect([for (final m in verdict.book) m.label], ['2.Nf3', '2.c3']);
    expect(verdict.place.file.name, 'Open');
    expect(verdict.place.sans, ['e4', 'c5']);
  });

  test('an opponent\'s move the book has no answer for is a gap', () {
    final verdict =
        checkGame(game('1. e4 c5 2. Nf3 Nc6 3. d4'), white) as LeftBook;
    expect(verdict.kind, Deviation.theirs);
    expect(verdict.ply, 3);
    expect(verdict.played, '2...Nc6');
    expect([for (final m in verdict.book) m.label], ['2...d6', '2...e6']);
  });

  test('a game that plays on past the end of a line ran out of book', () {
    final verdict =
        checkGame(game('1. e4 c5 2. Nf3 d6 3. d4 cxd4'), white) as LeftBook;
    expect(verdict.kind, Deviation.bookEnded);
    expect(verdict.ply, 5);
    expect(verdict.played, '3...cxd4');
    expect(verdict.book, isEmpty);
    expect(verdict.place.sans, ['e4', 'c5', 'Nf3', 'd6', 'd4']);
  });

  test('a transposition is in the book, and the book\'s order is kept', () {
    final verdict =
        checkGame(game('1. Nf3 c5 2. e4 d6 3. d4 cxd4'), white) as LeftBook;
    expect(verdict.kind, Deviation.bookEnded);
    expect(verdict.ply, 5);
    expect(verdict.place.sans, ['e4', 'c5', 'Nf3', 'd6', 'd4']);
  });

  test('a game that left and came back is judged where it last left', () {
    // 1...d6 is not in the book, but 2...c5 reaches the book's position
    // after 2...d6, and the game goes on in it to its end.
    final verdict =
        checkGame(game('1. e4 d6 2. Nf3 c5 3. d4 cxd4'), white) as LeftBook;
    expect(verdict.kind, Deviation.bookEnded);
    expect(verdict.ply, 5);
  });

  test('a game that ends inside the book is in it throughout', () {
    expect(
      checkGame(game('1. e4 c5 2. Nf3 d6'), white),
      isA<InBookThroughout>(),
    );
  });

  test('leaving before a full move is another opening', () {
    expect(checkGame(game('1. d4 d5'), white), isA<OtherOpening>());
    expect(checkGame(game('1. e4 e5 2. Nf3'), white), isA<OtherOpening>());
  });

  test('a side with no repertoire says so', () {
    expect(
      checkGame(game('1. e4 c5 2. Nf3', side: Side.black), white),
      isA<NoBook>(),
    );
  });

  test('a Black game is read against the Black books', () {
    final verdict =
        checkGame(game('1. e4 c5 2. Nc3 Nc6', side: Side.black), [
              ...white,
              book(najdorf, 'Najdorf'),
            ])
            as LeftBook;
    expect(verdict.kind, Deviation.theirs);
    expect(verdict.played, '2.Nc3');
    expect([for (final m in verdict.book) m.label], ['2.Nf3']);
    expect(verdict.place.file.name, 'Najdorf');
  });

  test('games that left the same way share a key; another move does not', () {
    final a = checkGame(game('1. e4 c5 2. Nc3 Nc6'), white) as LeftBook;
    final b = checkGame(game('1. e4 c5 2. Nc3 e6'), white) as LeftBook;
    final c = checkGame(game('1. e4 c5 2. d4'), white) as LeftBook;
    expect(a.sameWay, b.sameWay);
    expect(a.sameWay, isNot(c.sameWay));
  });

  group('a played game', () {
    test('is read from the user\'s side, whichever colour they had', () {
      final won = game('1. e4 e5', result: '1-0');
      expect(won.side, Side.white);
      expect(won.opponent, 'Rival');
      expect(won.outcome, GameOutcome.won);
      expect(won.moves.map((m) => m.label), ['1.e4', '1...e5']);
      expect(won.positions, hasLength(3));
      final lost = game('1. e4 e5', side: Side.black, result: '1-0');
      expect(lost.outcome, GameOutcome.lost);
    });

    test('is not the user\'s when neither player is them, nor a variant', () {
      const other = '[White "A"]\n[Black "B"]\n\n1. e4 *';
      expect(readPlayedGame(other, index: 0, username: 'me'), isNull);
      const variant =
          '[White "Me"]\n[Black "B"]\n[Variant "Crazyhouse"]\n\n1. e4 *';
      expect(readPlayedGame(variant, index: 0, username: 'me'), isNull);
    });
  });
}
