import 'package:chess_auto_prep/chess/book/book_check.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/board_book.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/viewer_fixture.dart';
import '../support/window_fixture.dart';

/// Two of Me's games as Black: the first leaves the KID chapter's
/// Sicilian with 3...Nf6 where the book plays 3...cxd4.
const _myGames = '''
[Event "Club"]
[White "Rival"]
[Black "Me"]
[Result "0-1"]

1. e4 c5 2. Nf3 d6 3. d4 Nf6 4. Nc3 0-1

[Event "Club"]
[White "Other"]
[Black "Me"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 *
''';

void main() {
  testWidgets('a game that left the book says where under its heading, and '
      'Show my line opens My books at that move', (tester) async {
    final app = WindowFixture();
    addTearDown(app.dispose);
    final ref = collectionRef('mine');
    app.store.documents[ref] = Opened(_myGames, scriptedRevision(_myGames));
    await app.pumpShell(tester);
    await app.requests.openFile(ref);
    await tester.pumpAndSettle();
    expect(app.parts.session.orientation, Side.black, reason: "Me's side");
    expect(
      find.text('You left book: 3...Nf6 (book 3...cxd4) · Main'),
      findsOneWidget,
    );
    await tester.tap(find.text('Show my line'));
    await tester.pumpAndSettle();
    expect(app.parts.session.cursor.indexes, hasLength(6));
    expect(find.text('As Black · Test book'), findsOneWidget);
    expect(find.text('Open in builder'), findsOneWidget);

    await app.requests.openFile(ref, game: 1);
    await tester.pumpAndSettle();
    expect(find.text('Show my line'), findsNothing, reason: 'in book: no news');
    expect(find.text('In book to the end'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('the check follows the side the board is seen from', () async {
    final app = WindowFixture();
    addTearDown(app.dispose);
    final ref = collectionRef('mine');
    app.store.documents[ref] = Opened(_myGames, scriptedRevision(_myGames));
    await app.parts.books.load();
    await app.requests.openFile(ref);
    final book = app.parts.workspace.boardBook!..watch();
    addTearDown(book.unwatch);
    await pumpEventQueue(times: 50);
    final state = book.state as BoardBookChecked;
    expect(state.game.side, Side.black);
    expect((state.verdict as LeftBook).kind, Deviation.mine);
    app.parts.session.flip();
    await pumpEventQueue(times: 50);
    expect(
      (book.state as BoardBookChecked).verdict,
      isA<OtherOpening>(),
      reason: 'the White repertoire has no moves',
    );
    expect(viewerTabs().tabs.map((tab) => tab.title), contains('My books'));
  });
}
