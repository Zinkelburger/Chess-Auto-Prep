// The My book tab: what it says before a check (no player, no games left
// by the filters, ready), the check's button, and a row per game that left
// the book, saying which kind of gap it is and opening its game.
import 'package:chess_auto_prep/chess/book/book_check.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/chess/repertoire_index.dart';
import 'package:chess_auto_prep/features/players/player_book.dart';
import 'package:chess_auto_prep/features/players/player_book_pane.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/window_fixture.dart';

const _games =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Date "2026.09.20"]\n'
    '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0\n\n'
    '[Event "Club"]\n[White "Alex"]\n[Black "Cy"]\n[Date "2026.09.21"]\n'
    '[Result "0-1"]\n\n1. d4 d5 0-1\n';

LeftBook _left(Deviation kind, String played) => LeftBook(
  kind: kind,
  ply: 1,
  played: played,
  playedUci: 'e7e5',
  book: const [],
  place: BookPlace(
    BookFile(
      path: '/repertoires/KID/Main.pgn',
      name: 'Main',
      index: RepertoireIndex.of(readGame('1. e4 *').tree!, Side.white),
    ),
    const ['e4'],
  ),
  position: '',
);

void main() {
  late WindowFixture w;
  late Player alex;
  final opened = <PlayerBookGap>[];
  var books = 0;

  setUp(() async {
    opened.clear();
    books = 0;
    w = WindowFixture();
    const ref = DocumentRef('/collections/alex.pgn');
    w.store.documents[ref] = Opened(_games, scriptedRevision(_games));
    alex = Player.create('Alex').edited({
      'pgn_files': [ref.path],
    });
    await w.parts.players.directory.save(alex);
  });
  tearDown(() => w.dispose());

  PlayerBook book() => w.parts.players.book;

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: PlayerBookPane(
            book: book(),
            onOpen: opened.add,
            onBooks: () => books++,
          ),
        ),
      ),
    );
  }

  FilledButton check(WidgetTester tester) =>
      tester.widget<FilledButton>(find.byType(FilledButton));

  testWidgets('with nobody chosen, asks for a player and checks nothing', (
    tester,
  ) async {
    await show(tester);
    expect(
      find.text('Choose a player and load their games first.'),
      findsOneWidget,
    );
    expect(check(tester).onPressed, isNull);
    await tester.tap(find.text('Choose book'));
    expect(books, 1);
  });

  testWidgets('with games, offers the check; with none left by the filters, '
      'says so and offers none', (tester) async {
    await tester.runAsync(() => w.parts.players.analysis.select(alex));
    await show(tester);
    expect(
      find.text(
        'Compare this player’s replies with your book for the opposite '
        'colour.',
      ),
      findsOneWidget,
    );
    expect(check(tester).onPressed, isNotNull);
    w.parts.players.analysis.search('nobody');
    await tester.pump();
    expect(
      find.text(
        'No games match. Change the colour or filters in the left panel.',
      ),
      findsOneWidget,
    );
    expect(check(tester).onPressed, isNull);
  });

  testWidgets('while a check runs, the button says so and is off', (
    tester,
  ) async {
    await tester.runAsync(() => w.parts.players.analysis.select(alex));
    book().busy = true;
    await show(tester);
    expect(find.text('Checking…'), findsOneWidget);
    expect(check(tester).onPressed, isNull);
    book().busy = false;
  });

  testWidgets('a game that left the book is a row naming the kind of gap, '
      'and opens where it left', (tester) async {
    await tester.runAsync(() => w.parts.players.analysis.select(alex));
    final theirs = (game: 0, gap: _left(Deviation.theirs, '1...e5'));
    final ended = (game: 1, gap: _left(Deviation.bookEnded, '2.c4'));
    book()
      ..gaps = [theirs, ended]
      ..status = '2 games against your black book · 2 reach a gap';
    await show(tester);
    expect(
      find.text('2 games against your black book · 2 reach a gap'),
      findsOneWidget,
    );
    expect(find.text('Unanswered reply'), findsOneWidget);
    expect(find.text('Past the end of the book'), findsOneWidget);
    expect(find.text('Alex – Bob · 2026.09.20'), findsOneWidget);
    expect(find.text('Alex – Cy · 2026.09.21'), findsOneWidget);
    await tester.tap(find.text('Past the end of the book'));
    expect(opened.single.game, 1);
  });
}
