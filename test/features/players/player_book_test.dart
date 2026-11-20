// Check my book: the player's games walked through the user's book for the
// other colour, counting the games that leave it on the player's move, not
// the user's; what it says with no book of that colour; and a result let go
// when the games it was read from change. (That the check runs on another
// isolate whatever the app holds is in shell_players_test.dart.)
import 'package:chess_auto_prep/chess/book/book_check.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/features/players/player_book.dart';
import 'package:chess_auto_prep/storage/book_file.dart';
import 'package:chess_auto_prep/storage/book_list.dart';
import 'package:chess_auto_prep/storage/book_snapshot.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/book/books.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/window_fixture.dart';

/// Alex's games: as White leaving the Black book on Alex's second move, as
/// White where the user's side (Bob) left it first, and one as Black.
const _games =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Date "2026.09.20"]\n[Result "1-0"]\n\n'
    '1. e4 c5 2. c3 Nf6 1-0\n\n'
    '[Event "Club"]\n[White "Alex"]\n[Black "Cy"]\n[Date "2026.09.21"]\n[Result "1-0"]\n\n'
    '1. e4 e5 2. Nf3 1-0\n\n'
    '[Event "Club"]\n[White "Bob"]\n[Black "Alex"]\n[Date "2026.09.22"]\n[Result "0-1"]\n\n'
    '1. e4 c5 2. Nf3 0-1\n';

/// A books file that is there and cannot be read.
final class _Unreadable implements BookStore {
  @override
  Future<BookList> read() => throw const FormatException('not JSON');
  @override
  Future<BookSnapshot> snapshot() => throw const FormatException('not JSON');
  @override
  Future<BookSnapshot> write(BookList books) =>
      throw const FormatException('not JSON');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WindowFixture w;
  late Player player;

  setUp(() async {
    w = WindowFixture();
    const ref = DocumentRef('/collections/alex.pgn');
    w.store.documents[ref] = Opened(_games, scriptedRevision(_games));
    player = Player.create('Alex').edited({
      'pgn_files': [ref.path],
    });
    await w.parts.players.directory.save(player);
    await w.library.refresh();
  });
  tearDown(() => w.dispose());

  test('a game leaving the book on the player\'s move is a gap; one the '
      'user\'s side left first is not', () async {
    final analysis = w.parts.players.analysis;
    await analysis.select(player);
    analysis.setSide(Side.white);
    final book = w.parts.players.book;
    await book.check();
    expect(book.busy, isFalse);
    expect(book.status, '2 games against your black book · 1 reach a gap');
    final gap = book.gaps.single;
    expect(analysis.corpus!.games[gap.game].tag('Black'), 'Bob');
    expect(gap.gap.kind, Deviation.theirs);
    expect(gap.gap.playedUci, 'c2c3');
  });

  test('a result is let go when the colour changes', () async {
    final analysis = w.parts.players.analysis;
    await analysis.select(player);
    analysis.setSide(Side.white);
    final book = w.parts.players.book;
    await book.check();
    expect(book.gaps, hasLength(1));
    var told = 0;
    void heard() => told++;
    book.addListener(heard);
    addTearDown(() => book.removeListener(heard));
    analysis.setSide(Side.black);
    expect(book.gaps, isEmpty);
    expect(book.status, isNull);
    expect(told, greaterThan(0));
  });

  test('with no repertoire of the other colour, says so', () async {
    const black = '// Color: Black\n\n[Event "?"]\n[Result "*"]\n\n1. e4 c5 *\n';
    w.store.documents[benkoMain] = Opened(black, scriptedRevision(black));
    await w.library.refresh();
    final analysis = w.parts.players.analysis;
    await analysis.select(player);
    analysis.setSide(Side.black);
    final book = w.parts.players.book;
    await book.check();
    expect(
      book.status,
      'Your book has no white repertoire to check against.',
    );
    expect(book.gaps, isEmpty);
    expect(book.busy, isFalse);
  });

  test('with the books unreadable, says why and checks nothing', () async {
    final books = Books(store: _Unreadable(), root: '/repertoires');
    addTearDown(books.dispose);
    final analysis = w.parts.players.analysis;
    final book = PlayerBook(analysis, w.shelf, books);
    addTearDown(book.dispose);
    await analysis.select(player);
    analysis.setSide(Side.white);
    await book.check();
    expect(
      book.status,
      'Your books could not be read, so the previous view is retained.',
    );
    expect(book.gaps, isEmpty);
    expect(book.busy, isFalse);
  });

  test('taken down while it reads the book, it stops quietly', () async {
    final analysis = w.parts.players.analysis;
    await analysis.select(player);
    analysis.setSide(Side.white);
    final book = PlayerBook(analysis, w.shelf, w.parts.books);
    final checking = book.check();
    book.dispose();
    await expectLater(checking, completes);
    expect(book.status, isNull);
    expect(book.gaps, isEmpty);
  });

  test('with nobody chosen, nothing is checked', () async {
    final book = w.parts.players.book;
    await book.check();
    expect(book.status, isNull);
    expect(book.busy, isFalse);
  });
}
