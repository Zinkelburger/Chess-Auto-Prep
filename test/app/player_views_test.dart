// Player analysis and Players as modes: what their menus offer for the
// player or list in hand; a game opened from the analysis at its start, at
// the board's position or where it left the book, and nothing for a game
// that is not there; and a group's prep sheet copied.
import 'package:chess_auto_prep/app/mode_view.dart';
import 'package:chess_auto_prep/app/player_views.dart';
import 'package:chess_auto_prep/chess/book/book_check.dart';
import 'package:chess_auto_prep/chess/pgn/pgn_reader.dart';
import 'package:chess_auto_prep/chess/players/player.dart';
import 'package:chess_auto_prep/chess/repertoire_index.dart';
import 'package:chess_auto_prep/features/players/analysis_panel.dart';
import 'package:chess_auto_prep/features/players/player_book_pane.dart';
import 'package:chess_auto_prep/features/players/player_tree_pane.dart';
import 'package:chess_auto_prep/features/players/players_screen.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/ui/app_action.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';
import '../support/window_fixture.dart';

const _games =
    '[Event "Club"]\n[White "Alex"]\n[Black "Bob"]\n[Date "2026.09.20"]\n'
    '[Result "1-0"]\n\n1. e4 e5 2. Nf3 Nc6 1-0\n\n'
    '[Event "Club"]\n[White "Bob"]\n[Black "Alex"]\n[Date "2026.09.21"]\n'
    '[Result "0-1"]\n\n1. d4 d5 0-1';

void main() {
  late WindowFixture w;
  late Player player;
  const ref = DocumentRef('/collections/player.pgn');

  setUp(() async {
    w = WindowFixture();
    w.store.documents[ref] = Opened(_games, scriptedRevision(_games));
    player = Player.create('Alex').edited({
      'pgn_files': [ref.path],
    });
    await w.parts.players.directory.save(player);
  });
  tearDown(() => w.dispose());

  PlayerAnalysisView analysis() {
    final view = PlayerAnalysisView(
      w.parts.workspace,
      w.requests,
      w.parts.players,
    );
    addTearDown(view.dispose);
    return view;
  }

  PlayersView playersView() {
    final view = PlayersView(w.parts.workspace, w.parts.players);
    addTearDown(view.dispose);
    return view;
  }

  Future<ModeMenu> menu(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    void none() {}
    final ModeMenu menu = (
      editing: ValueNotifier(false),
      board: () => const [],
      dialogs: (
        saveCopy: none,
        saveHeld: none,
        exportPgn: none,
        search: none,
        accounts: none,
        newBook: none,
        importCourse: none,
      ),
      context: tester.element(find.byType(SizedBox)),
    );
    return menu;
  }

  AppAction? entry(List<AppAction> actions, String label) =>
      actions.where((action) => action.label == label).firstOrNull;
  bool on(List<AppAction> actions, String label) =>
      entry(actions, label)!.run != null;

  Future<void> choose(WidgetTester tester, Player who) async {
    await tester.runAsync(() => w.parts.players.analysis.select(who));
    await tester.pump();
  }

  Future<void> show(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        home: Scaffold(body: child),
      ),
    );
    await tester.pump();
  }

  /// Lets the open the test started come back.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
  }

  group('Player analysis', () {
    const forAPlayer = [
      'Add PGN…',
      'Analyze with engine',
      'Check against my book',
      'Add line to prep study',
    ];

    testWidgets('with no player, offers nothing to do to one', (tester) async {
      final actions = analysis().actions(await menu(tester));
      for (final label in [...forAPlayer, 'Get games']) {
        expect(on(actions, label), isFalse, reason: label);
      }
    });

    testWidgets('with a player, offers their games; Get games only where '
        'they have an account', (tester) async {
      final view = analysis();
      await choose(tester, player);
      var actions = view.actions(await menu(tester));
      for (final label in forAPlayer) {
        expect(on(actions, label), isTrue, reason: label);
      }
      expect(on(actions, 'Get games'), isFalse);
      final now = w.parts.players.directory.players.single;
      final online = now.edited({'lichess': 'alex'});
      await tester.runAsync(
        () => w.parts.players.directory.save(online, expected: now),
      );
      await tester.pump();
      expect(w.parts.players.analysis.player?.accounts, isNotEmpty);
      actions = view.actions(await menu(tester));
      expect(on(actions, 'Get games'), isTrue);
      entry(actions, 'Get games')!.run!();
      expect(w.parts.players.analysis.status, startsWith('Downloading'));
      await settle(tester);
    });

    testWidgets('a game opens at its start, without a word', (tester) async {
      final view = analysis();
      await choose(tester, player);
      await show(tester, view.list(const SizedBox()));
      tester.widget<AnalysisPanel>(find.byType(AnalysisPanel)).onOpen(1, null);
      await settle(tester);
      expect(w.session.source?.path, ref.path);
      expect(w.session.game, 1);
      expect(w.session.cursor.value.isRoot, isTrue);
      expect(w.requests.status, isNull);
    });

    testWidgets('a game that is not there opens nothing', (tester) async {
      final view = analysis();
      await choose(tester, player);
      await show(tester, view.list(const SizedBox()));
      final panel = tester.widget<AnalysisPanel>(find.byType(AnalysisPanel));
      panel.onOpen(2, null);
      panel.onOpen(-1, null);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(w.session.source?.path, isNot(ref.path));
    });

    testWidgets('from the openings tree, a game opens at the board', (
      tester,
    ) async {
      final view = analysis();
      await choose(tester, player);
      await w.requests.newEmptyAnalysis();
      w.session
        ..playMove('e2e4')
        ..playMove('e7e5');
      final at = w.session.cursor.fen;
      await show(
        tester,
        Builder(builder: (context) => view.tab(context, WorkspaceTab.player)!),
      );
      tester.widget<PlayerTreePane>(find.byType(PlayerTreePane)).onOpen(0);
      await settle(tester);
      expect(w.session.source?.path, ref.path);
      expect(w.session.cursor.fen, at);
    });

    /// The book check's pane up, and the row of game [game], which left
    /// the book at its second move, pressed.
    Future<void> openGap(
      WidgetTester tester,
      PlayerAnalysisView view, {
      int game = 0,
    }) async {
      await show(
        tester,
        Builder(
          builder: (context) => view.tab(context, WorkspaceTab.playerBook)!,
        ),
      );
      final book = BookFile(
        path: '/repertoires/KID/Main.pgn',
        name: 'Main',
        index: RepertoireIndex.of(readGame('1. e4 *').tree!, Side.white),
      );
      tester.widget<PlayerBookPane>(find.byType(PlayerBookPane)).onOpen((
        game: game,
        gap: LeftBook(
          kind: Deviation.theirs,
          ply: 1,
          played: '1...e5',
          playedUci: 'e7e5',
          book: const [],
          place: BookPlace(book, const ['e4']),
          position: '',
        ),
      ));
      await settle(tester);
    }

    testWidgets('from the book check, a game opens where it left the book', (
      tester,
    ) async {
      final view = analysis();
      await choose(tester, player);
      await openGap(tester, view);
      expect(w.session.source?.path, ref.path);
      expect(w.session.cursor.currentMove?.san, 'e5');
    });

    testWidgets('from the book check, a game that is not there opens '
        'nothing', (tester) async {
      final view = analysis();
      await choose(tester, player);
      await openGap(tester, view, game: 5);
      expect(tester.takeException(), isNull);
      expect(w.session.source?.path, isNot(ref.path));
    });

    testWidgets('from the book check, games changed since they were read '
        'are said, and the board stays', (tester) async {
      final view = analysis();
      await choose(tester, player);
      await show(tester, view.list(const SizedBox()));
      tester.widget<AnalysisPanel>(find.byType(AnalysisPanel)).onOpen(0, null);
      await settle(tester);
      expect(w.session.cursor.value.isRoot, isTrue);
      const changed = '$_games\n';
      w.store.documents[ref] = Opened(changed, scriptedRevision(changed));
      await openGap(tester, view);
      expect(
        w.requests.status,
        'Games changed. Reload this player before opening a result.',
      );
      expect(w.session.cursor.value.isRoot, isTrue);
    });
  });

  group('Players', () {
    testWidgets('adds a player, or pastes several, unless the list is busy', (
      tester,
    ) async {
      final view = playersView();
      var actions = view.actions(await menu(tester));
      expect(on(actions, 'Add player…'), isTrue);
      expect(on(actions, 'Paste players…'), isTrue);
      w.parts.players.directory.busy = true;
      actions = view.actions(await menu(tester));
      expect(on(actions, 'Add player…'), isFalse);
      expect(on(actions, 'Paste players…'), isFalse);
      w.parts.players.directory.busy = false;
    });

    testWidgets('in a group, adds players to it; among the groups, makes '
        'one and pastes nothing', (tester) async {
      final view = playersView();
      final directory = w.parts.players.directory;
      final group = PlayerGroup.create('Club');
      await tester.runAsync(() => directory.saveGroup(group));
      directory.showGroup(group.id);
      var actions = view.actions(await menu(tester));
      expect(entry(actions, 'Add players…'), isNotNull);
      directory.showGroups(true);
      actions = view.actions(await menu(tester));
      expect(entry(actions, 'New group…'), isNotNull);
      expect(entry(actions, 'Paste players…'), isNull);
    });

    testWidgets("a group's prep sheet is copied", (tester) async {
      final group = PlayerGroup.create('Club');
      // Room for a person's row as the app lays it out at full width.
      tester.view
        ..physicalSize = const Size(1400, 900)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await show(tester, playersView().screen(const {}));
      tester.widget<PlayersScreen>(find.byType(PlayersScreen)).onCopy(group);
      await settle(tester);
      expect(w.requests.status, 'Prep sheet copied, including saved lines.');
    });
  });
}
