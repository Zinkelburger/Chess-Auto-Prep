import 'package:chess_auto_prep/v2/chess/book/book_check.dart';
import 'package:chess_auto_prep/v2/features/my_games/book_pane.dart';
import 'package:chess_auto_prep/v2/features/my_games/game_book.dart'
    show GameBook;
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/book_fixture.dart';

/// The Book tab over a real [GameBook] and session on scripted files: the
/// verdict on the game on the board, the moves beside it and the doors.
void main() {
  late BookFixture fixture;
  late DocumentSaver saver;
  late DocumentSession session;

  setUp(() {
    fixture = BookFixture();
    saver = DocumentSaver(fixture.store, delay: Duration.zero);
    session = DocumentSession(fixture.store, saver);
  });

  tearDown(() {
    fixture.dispose();
    session.dispose();
    saver.dispose();
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  late List<BookPlace> read;

  Future<void> pumpPane(WidgetTester tester, int game) async {
    read = [];
    await session.open(fixture.gamesFile, game: game);
    await pump(
      tester,
      BookPane(book: fixture.book, session: session, onReadBook: read.add),
    );
  }

  testWidgets('sets the move played beside what the book plays', (
    tester,
  ) async {
    await pumpPane(tester, 3);
    expect(find.text('You left book: 2.Nc3 (book 2.Nf3)'), findsOneWidget);
    expect(find.text('vs Rival (2105) · Lost · 2026.09.20'), findsOneWidget);
    expect(find.text('2.Nc3'), findsOneWidget);
    expect(find.text('2.Nf3'), findsOneWidget);
    expect(find.text('2 lines'), findsOneWidget);
    expect(find.text('2...d6 3.d4'), findsOneWidget);
  });

  testWidgets('goes back to the move, and into the book where it left', (
    tester,
  ) async {
    await pumpPane(tester, 3);
    session.toEnd();
    await tester.tap(find.text('Show the move'));
    expect(session.cursor.indexes, [0, 0, 0]);
    await tester.tap(find.text('Open in builder'));
    expect(read.single.file.path, sicilianRef.path);
    expect(read.single.sans, ['e4', 'c5']);
    await tester.tap(find.text('Sicilian'));
    expect(read.last.sans, ['e4', 'c5', 'Nf3']);
  });

  testWidgets('a game in another opening says it is not a mistake', (
    tester,
  ) async {
    await pumpPane(tester, 0);
    expect(find.text('Another opening'), findsOneWidget);
    expect(find.textContaining('not a mistake'), findsOneWidget);
    expect(find.text('Open in builder'), findsNothing);
  });

  testWidgets('a document that is not one of the games asks for one', (
    tester,
  ) async {
    await session.open(sicilianRef);
    await pump(
      tester,
      BookPane(book: fixture.book, session: session, onReadBook: (_) {}),
    );
    expect(find.textContaining('Open one of your games'), findsOneWidget);
  });
}
