// When the My games book reads: once for any number of panes watching, not
// dropped while one of them is still up, again when the book in use is
// edited, and a step back walks to the very first game.
import 'package:chess_auto_prep/features/my_games/game_book.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/book_fixture.dart';
import '../../support/scripted_files.dart';

void main() {
  late BookFixture fixture;
  setUp(() => fixture = BookFixture());
  tearDown(() => fixture.dispose());

  int reads() => fixture.accounts.snapshots;

  test('two panes watching read once', () async {
    fixture.book
      ..watch()
      ..watch();
    await pumpEventQueue();
    expect(reads(), 1);
  });

  test(
    'a pane leaving while another watches keeps the read under way',
    () async {
      fixture.book
        ..watch()
        ..watch()
        ..unwatch();
      await pumpEventQueue();
      expect(fixture.book.state, isA<BookChecked>());
    },
  );

  test(
    'an unwatch with nothing watching does not stop the next pane',
    () async {
      fixture.book
        ..unwatch()
        ..watch();
      await pumpEventQueue();
      final before = reads();
      fixture.book.recheck();
      await pumpEventQueue();
      expect(reads(), greaterThan(before));
    },
  );

  test('an edit to the book in use is read again', () async {
    fixture.book.watch();
    await pumpEventQueue();
    final before = reads();
    fixture.books.setRepertoire(
      fixture.books.active,
      folder('Najdorf', ['Main']),
      false,
    );
    await pumpEventQueue();
    expect(reads(), greaterThan(before));
  });

  test('a step back from the second game reaches the first', () async {
    fixture.book.watch();
    await pumpEventQueue();
    final games = (fixture.book.state as BookChecked).games;
    final second = games[1];
    expect(
      fixture.book.step(fixture.gamesFile, second.game.index, -1),
      games.first,
    );
  });
}
