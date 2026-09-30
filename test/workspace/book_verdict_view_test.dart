import 'package:chess_auto_prep/chess/book/book_check.dart';
import 'package:chess_auto_prep/chess/book/played_game.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/repertoire_index.dart';
import 'package:chess_auto_prep/workspace/book_verdict_view.dart';
import 'package:flutter_test/flutter_test.dart';

const _sicilian = '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 *
''';

/// Where a game opens for its verdict: every host (My games, the board's
/// book tab, Player analysis) asks [bookMoment] or [leftBookMoment].
void main() {
  final chapter = parseChapter(name: 'Open', text: _sicilian);
  final books = [
    BookFile(
      path: '/books/Open.pgn',
      name: 'Open',
      index: RepertoireIndex.of(chapter.tree, chapter.side),
    ),
  ];
  PlayedGame game(String moves) => readPlayedGame(
    '[White "Me"]\n[Black "Rival"]\n[Result "*"]\n\n$moves *',
    index: 0,
    username: 'me',
  )!;

  test('a game that left the book opens through the move that left it', () {
    final played = game('1. e4 c5 2. Nc3 Nc6');
    final left = checkGame(played, books) as LeftBook;
    expect(left.kind, Deviation.mine);
    expect(leftBookMoment(left), 3);
    expect(bookMoment(left, played), 3);
  });

  test('a game past the end of the book opens on its last book move, not '
      'the move after', () {
    final played = game('1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4');
    final left = checkGame(played, books) as LeftBook;
    expect(left.kind, Deviation.bookEnded);
    expect(left.ply, 5);
    expect(leftBookMoment(left), 5);
    expect(bookMoment(left, played), 5);
  });
}
