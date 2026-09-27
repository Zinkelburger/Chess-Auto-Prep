import 'package:chess_auto_prep/v2/chess/explorer_answer.dart';
import 'package:chess_auto_prep/v2/chess/explorer_choice.dart';
import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/v2/net/lichess_explorer.dart';
import 'package:chess_auto_prep/v2/storage/my_accounts.dart';
import 'package:chess_auto_prep/v2/storage/my_games_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/ui/theme.dart';
import 'package:chess_auto_prep/v2/workspace/explorer.dart';
import 'package:chess_auto_prep/v2/workspace/explorer_pane.dart';
import 'package:chess_auto_prep/v2/workspace/file_filter.dart';
import 'package:chess_auto_prep/v2/workspace/local_games.dart';
import 'package:chessground/chessground.dart' show StaticChessboard;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/my_games_fixture.dart';
import '../support/scripted_explorer.dart';
import '../support/scripted_store.dart';
import '../support/session_fixture.dart';
import '../support/books_fixture.dart';
import '../support/scripted_files.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_shelf.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_tree.dart';

const chapter = '''
// Color: White

[Event "Open"]
[Result "*"]

1. e4 e5 *
''';

void main() {
  late SessionFixture fixture;
  late SettingsStore settings;
  late ScriptedExplorerApi lichess;
  late ScriptedBook book;
  late Explorer explorer;
  final opened = <ExplorerGame>[];

  setUp(() async {
    fixture = await openSession(chapter);
    settings = SettingsStore();
    lichess = ScriptedExplorerApi();
    book = ScriptedBook(present: true);
    opened.clear();
  });

  tearDown(() {
    settings.dispose();
    fixture.dispose();
  });

  /// The owner is made inside the test body, so its futures run under the
  /// test's clock.
  Future<void> show(
    WidgetTester tester, {
    LocalGames? thisFile,
    SavedGames? myGames,
  }) async {
    explorer = explorerOver(
      fixture.session,
      settings: settings,
      lichess: lichess,
      book: book,
      thisFile: thisFile,
      myGames: myGames,
    );
    addTearDown(explorer.dispose);
    final games = gamesOver(fixture.store, lichess: lichess, book: book);
    addTearDown(games.dispose);
    final books = booksWith();
    final tree = RepertoireTree(
      session: fixture.session,
      shelf: RepertoireShelf(files: ScriptedFiles(), documents: fixture.store),
      books: books,
    );
    addTearDown(tree.dispose);
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(
          body: Column(
            children: [
              Expanded(
                child: SizedBox(
                  // The test font's letters are square: six sources need
                  // the room.
                  width: 960,
                  child: ExplorerPane(
                    session: fixture.session,
                    explorer: explorer,
                    games: games,
                    tree: tree,
                    books: books,
                    onOpenGame: opened.add,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows the databases, the moves with their games and shares, a '
      'tick on the one the chapter plays, the totals and the games', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('Masters'), findsOneWidget);
    expect(find.text('Move'), findsOneWidget);
    expect(find.textContaining('e4'), findsOneWidget);
    expect(find.text('180 · 60%'), findsOneWidget);
    expect(find.text('120 · 40%'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget, reason: 'e4 only');
    expect(find.text('Σ'), findsOneWidget);
    expect(find.text('300'), findsOneWidget);
    expect(find.byType(ResultBar), findsNWidgets(3));
    expect(find.text('56%'), findsOneWidget, reason: 'e4: 100 of 180 white');
    expect(find.text('Carlsen, M (2830) – Nakamura, H (2780)'), findsOneWidget);
    expect(find.text('1-0'), findsOneWidget);
    expect(find.text('2024'), findsOneWidget);
  });

  testWidgets('the board floated over a move goes when the board moves on '
      'under the still pointer', (tester) async {
    lichess.answer = (query) =>
        ExplorerFetched(query.fen == Fen.initial ? startAnswer : afterE4Answer);
    await show(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.textContaining('d4')));
    await tester.pump(previewDelay);
    expect(find.byType(StaticChessboard), findsOneWidget);
    fixture.session.forward();
    await tester.pumpAndSettle();
    expect(find.textContaining('d4'), findsNothing, reason: 'its row is gone');
    expect(find.byType(StaticChessboard), findsNothing);
  });

  testWidgets('clicking a move plays it into the document', (tester) async {
    await show(tester);
    await tester.tap(find.textContaining('d4'));
    await tester.pumpAndSettle();
    expect(fixture.session.currentMove?.san, 'd4');
    expect(fixture.onDisk, contains('d4'), reason: 'written');
  });

  testWidgets('clicking a game asks for it to be opened', (tester) async {
    await show(tester);
    await tester.tap(find.textContaining('Carlsen'));
    expect(opened.single.id, 'abcd1234');
  });

  testWidgets('the databases sit side by side at the top; Filters unfolds '
      'the chosen one\'s chips and says what they are set to', (tester) async {
    await show(tester);
    expect(find.text('Masters'), findsOneWidget);
    expect(find.text('TWIC'), findsOneWidget);
    expect(find.text('Filters'), findsNothing, reason: 'Masters has none');
    await tester.tap(find.text('Lichess'));
    await tester.pumpAndSettle();
    expect(settings.value.explorer.source, ExplorerSource.lichess);
    expect(lichess.asked.last.choice.source, ExplorerSource.lichess);
    expect(find.text('blitz rapid classical · 2000+'), findsOneWidget);
    expect(find.text('Speed'), findsNothing, reason: 'folded');
    await tester.tap(find.text('blitz rapid classical · 2000+'));
    await tester.pumpAndSettle();
    expect(find.text('Speed'), findsOneWidget);
    await tester.tap(find.text('bullet'));
    await tester.pumpAndSettle();
    expect(settings.value.explorer.speeds, contains(LichessSpeed.bullet));
    await tester.tap(find.text('1600'));
    await tester.pumpAndSettle();
    expect(settings.value.explorer.ratings, contains(1600));
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    expect(find.text('Speed'), findsNothing);
    expect(
      find.text('bullet blitz rapid classical · 1600 2000 2200 2500'),
      findsOneWidget,
    );
    await tester.tap(find.text('TWIC'));
    await tester.pumpAndSettle();
    expect(settings.value.explorer.source, ExplorerSource.twic);
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Classical OTB only'));
    await tester.pumpAndSettle();
    expect(settings.value.explorer.classicalOnly, isTrue);
  });

  testWidgets('This file is the open file\'s games and My games the '
      'user\'s saved ones, each with its games under the moves', (
    tester,
  ) async {
    final filter = FileFilter(fixture.session, delay: Duration.zero);
    addTearDown(filter.dispose);
    final thisFile = FileTree(filter: filter);
    addTearDown(thisFile.dispose);
    final saved = ScriptedDocumentStore();
    final cache = GamesCache(saved, folder: '/games_library');
    const mine =
        '[Event "Rated blitz game"]\n[Site "https://lichess.org/Mine1234"]\n'
        '[Date "2026.09.01"]\n[White "Me"]\n[Black "Rival"]\n'
        '[Result "0-1"]\n\n1. d4 d5 0-1\n';
    saved.documents[cache.refFor(GameSite.lichess, 'Me')] = Opened(
      mine,
      scriptedRevision(mine),
    );
    final myGames = MyGamesTree(
      accounts: MemoryAccounts({GameSite.lichess: const Account('Me')}),
      cache: cache,
      store: ScriptedGameStore(),
    );
    addTearDown(myGames.dispose);
    await show(tester, thisFile: thisFile, myGames: myGames);

    await tester.tap(find.text('This file'));
    await tester.pumpAndSettle();
    expect(find.text('e4'), findsOneWidget);
    expect(find.text('1 · 100%'), findsOneWidget);
    expect(find.text('1 game'), findsOneWidget, reason: 'the summary');
    expect(find.text('Masters'), findsOneWidget, reason: 'the row stays');
    expect(lichess.asked.map((q) => q.choice.source), [ExplorerSource.masters]);

    await tester.tap(find.text('My games'));
    await tester.pumpAndSettle();
    expect(find.text('d4'), findsOneWidget);
    expect(find.text('e4'), findsNothing);
    expect(find.text('Me – Rival'), findsOneWidget);
    expect(find.text('0-1'), findsOneWidget);
    await tester.tap(find.text('Me – Rival'));
    expect(opened.single.id, 'lichess_Mine1234');
  });

  testWidgets('a failure is a sentence with Try again, and the table comes '
      'when the answer does', (tester) async {
    lichess.answer = (_) =>
        const ExplorerNotFetched(ExplorerProblem.unreachable);
    await show(tester);
    expect(
      find.text(
        'Could not reach the Lichess database — it needs a connection. '
        'TWIC works offline.',
      ),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    lichess.answer = (_) => const ExplorerFetched(startAnswer);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('180 · 60%'), findsOneWidget);
  });

  testWidgets('a rating whose bar part is narrow carries no number', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: const Scaffold(
          body: SizedBox(
            width: 300,
            child: ResultBar(white: 95, draws: 3, black: 2),
          ),
        ),
      ),
    );
    expect(find.text('95%'), findsOneWidget);
    expect(find.text('3%'), findsNothing);
  });

  testWidgets('a part too narrow for its number is still drawn full height', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: const Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              child: ResultBar(white: 60, draws: 5, black: 35),
            ),
          ),
        ),
      ),
    );
    final draws = find.byWidgetPredicate(
      (w) => w is ColoredBox && w.color == resultBarDraw,
    );
    expect(tester.getSize(draws).height, explorerBarHeight);
    expect(find.text('5%'), findsNothing);
  });
}
