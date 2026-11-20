// The Player openings tab: what the chosen player's games did from the
// board's position, a row per move with its games and share, the move
// played on the board when its row is pressed, the games listed under them,
// and what it says where the games never went. (A game opened from the tab
// is in player_views_test.dart.)
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/features/players/player_analysis.dart';
import 'package:chess_auto_prep/features/players/player_tree_pane.dart';
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
    '[Result "1/2-1/2"]\n\n1. e4 c5 1/2-1/2\n\n'
    '[Event "Club"]\n[White "Alex"]\n[Black "Dee"]\n[Date "2026.09.22"]\n'
    '[Result "0-1"]\n\n1. d4 d5 0-1\n\n'
    '[Event "Club"]\n[White "Eve"]\n[Black "Alex"]\n[Date "2026.09.23"]\n'
    '[Result "1-0"]\n\n1. c4 e5 1-0\n';

void main() {
  late WindowFixture w;
  late Player alex;
  final opened = <int>[];
  var starts = 0, saves = 0;

  setUp(() async {
    opened.clear();
    starts = saves = 0;
    w = WindowFixture();
    const ref = DocumentRef('/collections/alex.pgn');
    w.store.documents[ref] = Opened(_games, scriptedRevision(_games));
    alex = Player.create('Alex').edited({
      'pgn_files': [ref.path],
    });
    await w.parts.players.directory.save(alex);
  });
  tearDown(() => w.dispose());

  PlayerAnalysis analysis() => w.parts.players.analysis;

  Future<void> show(WidgetTester tester, {bool canSave = false}) async {
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: PlayerTreePane(
            analysis: analysis(),
            session: w.session,
            onOpen: opened.add,
            onStart: () => starts++,
            onSave: canSave ? () => saves++ : null,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> board(WidgetTester tester, List<String> moves) async {
    await tester.runAsync(() => w.requests.newEmptyAnalysis());
    for (final move in moves) {
      w.session.playMove(move);
    }
    await tester.pump();
  }

  testWidgets('with nobody chosen, asks for a player', (tester) async {
    await show(tester);
    expect(find.text('Choose a player to see what they play.'), findsOneWidget);
  });

  testWidgets('a player with no games says so', (tester) async {
    const empty = DocumentRef('/collections/none.pgn');
    w.store.documents[empty] = Opened('', scriptedRevision(''));
    final zed = Player.create('Zed').edited({
      'pgn_files': [empty.path],
    });
    await tester.runAsync(() => analysis().select(zed));
    await show(tester);
    expect(find.text('This player has no games yet.'), findsOneWidget);
  });

  testWidgets('from the start, a row per move with its games and share; a '
      'row plays its move and a game opens', (tester) async {
    await tester.runAsync(() => analysis().select(alex));
    await board(tester, const []);
    await show(tester, canSave: true);
    expect(find.text('Alex as White · 3 games'), findsOneWidget);
    expect(find.text('2 · 67%'), findsOneWidget);
    expect(find.text('1 · 33%'), findsOneWidget);
    // Nothing is on the board yet, so there is no line to save.
    expect(find.text('Add line to prep study'), findsNothing);
    expect(find.text('Alex – Bob'), findsOneWidget);
    expect(find.text('Eve – Alex'), findsNothing);
    await tester.tap(find.text('Alex – Dee'));
    expect(opened, [2]);
    await tester.tap(find.text('e4'));
    await tester.pump();
    expect(w.session.cursor.currentMove?.san, 'e4');
    expect(find.text('Alex as White · 2 games'), findsOneWidget);
    expect(find.text('1 · 50%'), findsNWidgets(2));
    await tester.tap(find.text('Add line to prep study'));
    expect(saves, 1);
  });

  testWidgets('as Black, the player\'s games of that colour', (tester) async {
    await tester.runAsync(() => analysis().select(alex));
    analysis().setSide(Side.black);
    await board(tester, const []);
    await show(tester);
    expect(find.text('Alex as Black · 1 game'), findsOneWidget);
    expect(find.text('1 · 100%'), findsOneWidget);
  });

  testWidgets('where the games never went, offers their first move; with '
      'every game filtered out, says so instead', (tester) async {
    await tester.runAsync(() => analysis().select(alex));
    await board(tester, const ['a2a3']);
    await show(tester, canSave: true);
    expect(
      find.text('None of these games reached the position on the board.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Go to the first move'));
    expect(starts, 1);
    await tester.tap(find.text('Add line to prep study'));
    expect(saves, 1);

    analysis().search('nobody');
    await tester.pump();
    expect(
      find.text('No games match. Try the other colour or loosen the filters.'),
      findsOneWidget,
    );
    expect(find.text('Go to the first move'), findsNothing);
  });
}
