import 'package:chess_auto_prep/workspace/book/board_book.dart';
import 'package:chess_auto_prep/workspace/book/repertoire_shelf.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/books_fixture.dart';
import '../support/scripted_files.dart';
import '../support/session_fixture.dart';

/// Two games of one file, shown one at a time as a collection is.
const _games = '''
[Event "Club"]
[White "Rival"]
[Black "Me"]
[Result "0-1"]

1. e4 c5 2. Nf3 d6 0-1

[Event "Club"]
[White "Other"]
[Black "Me"]
[Result "*"]

1. d4 Nf6 *
''';

void main() {
  late SessionFixture fixture;
  late ScriptedFiles files;
  late RepertoireShelf shelf;
  late BoardBook book;

  setUp(() async {
    fixture = await openSession(_games);
    await fixture.session.open(fixture.ref, game: 0);
    files = ScriptedFiles();
    shelf = RepertoireShelf(files: files, documents: fixture.store);
    book = BoardBook(
      session: fixture.session,
      shelf: shelf,
      books: booksWith({'e4'}),
    );
  });

  tearDown(() {
    book.dispose();
    shelf.dispose();
    fixture.dispose();
  });

  /// The side the last check read the game as, or null with none made.
  Side? checkedAs() => switch (book.state) {
    BoardBookChecked(:final game) => game.side,
    _ => null,
  };

  test('checks only while something showing it is up', () async {
    fixture.session.flip();
    await pumpEventQueue();
    expect(book.state, isA<BoardBookIdle>());
    book.watch();
    await pumpEventQueue();
    expect(checkedAs(), fixture.session.orientation);
  });

  test('one pane going leaves the check to the other; the last going stops '
      'it until another comes', () async {
    book
      ..watch()
      ..watch();
    await pumpEventQueue();
    final first = checkedAs();
    book.unwatch();
    fixture.session.flip();
    await pumpEventQueue();
    expect(checkedAs(), isNot(first), reason: 'one pane is still up');
    final second = checkedAs();
    book.unwatch();
    fixture.session.flip();
    await pumpEventQueue();
    expect(checkedAs(), second, reason: 'nothing is up to show it');
    book
      ..unwatch()
      ..watch();
    await pumpEventQueue();
    expect(
      checkedAs(),
      fixture.session.orientation,
      reason: 'a pane going twice does not keep the next from checking',
    );
  });

  test('a check still reading finishes for the pane left, and is dropped '
      'when the last pane goes', () async {
    files.hold = true;
    book
      ..watch()
      ..watch();
    await pumpEventQueue();
    expect(book.state, isA<BoardBookReading>());
    book.unwatch();
    files
      ..hold = false
      ..releaseAll();
    await pumpEventQueue();
    expect(checkedAs(), fixture.session.orientation);

    files.hold = true;
    shelf.forget();
    fixture.session.flip();
    await pumpEventQueue();
    book.unwatch();
    files
      ..hold = false
      ..releaseAll();
    await pumpEventQueue();
    expect(
      checkedAs(),
      isNot(fixture.session.orientation),
      reason: 'the check made for nobody is not shown',
    );
  });

  test('a closed board book stays quiet', () async {
    book.dispose();
    book.watch();
    await pumpEventQueue();
    expect(book.state, isA<BoardBookIdle>());
    book = BoardBook(
      session: fixture.session,
      shelf: shelf,
      books: booksWith({'e4'}),
    );
  });
}
