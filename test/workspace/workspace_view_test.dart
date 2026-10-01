import 'package:chess_auto_prep/chess/pgn/board_shapes.dart';
import 'package:chess_auto_prep/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:chess_auto_prep/storage/settings_store.dart';
import 'package:chess_auto_prep/ui/pane_tabs.dart';
import 'package:chess_auto_prep/ui/theme.dart';
import 'package:chess_auto_prep/workspace/opening_names.dart';
import 'package:chess_auto_prep/workspace/document_saver.dart';
import 'package:chess_auto_prep/workspace/comment_field.dart';
import 'package:chess_auto_prep/workspace/document_session.dart';
import 'package:chess_auto_prep/workspace/engine_analysis.dart';
import 'package:chess_auto_prep/workspace/engine_jobs.dart';
import 'package:chess_auto_prep/workspace/explorer.dart';
import 'package:chess_auto_prep/workspace/game_fetcher.dart';
import 'package:chess_auto_prep/workspace/gap_hunt.dart';
import 'package:chess_auto_prep/workspace/explorer_pane.dart';
import 'package:chess_auto_prep/storage/finds_store.dart';
import 'package:chess_auto_prep/workspace/fill_gaps.dart';
import 'package:chess_auto_prep/workspace/fill_states.dart';
import 'package:chess_auto_prep/workspace/finds.dart';
import 'package:chess_auto_prep/workspace/move_field.dart';
import 'package:chess_auto_prep/workspace/move_tree_view.dart';
import 'package:chess_auto_prep/workspace/replies.dart';
import 'package:chess_auto_prep/workspace/reading_header.dart';
import 'package:chess_auto_prep/workspace/replies_pane.dart';
import 'package:chess_auto_prep/workspace/workspace_keys.dart';
import 'package:chess_auto_prep/workspace/workspace_tabs.dart';
import 'package:chess_auto_prep/workspace/action_layout.dart';
import 'package:chess_auto_prep/workspace/repertoire_shelf.dart';
import 'package:chess_auto_prep/workspace/repertoire_tree.dart';
import 'package:chess_auto_prep/workspace/workspace.dart';
import 'package:chess_auto_prep/workspace/workspace_view.dart';
import 'package:chess_auto_prep/workspace/board_view.dart';
import 'package:chessground/chessground.dart' show Chessboard;
import 'package:dartchess/dartchess.dart' show Square;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/replies_fixture.dart';
import '../support/scripted_explorer.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';
import '../support/scripted_engine.dart';
import '../support/scripted_policy.dart';
import '../support/session_fixture.dart';
import '../support/viewer_fixture.dart';
import '../support/books_fixture.dart';

void main() {
  late SessionFixture fixture;
  late DocumentSession session;
  late DocumentSaver saver;
  late EngineAnalysis analysis;
  late Replies replies;
  late GapHunt gaps;
  late GameFetcher games;
  late Explorer explorer;
  late FillGaps fill;
  late ValueNotifier<bool> editing;
  late MoveEntry moves;
  late PaneTabs<WorkspaceTab> tabs;
  late SettingsStore settings;

  /// The comment's box; the move field under the board is always there.
  final comment = find.descendant(
    of: find.byType(CommentField),
    matching: find.byType(TextField),
  );

  /// The engine stays off; its pane has its own test.
  void startAnalysis() {
    analysis = EngineAnalysis(
      session,
      () async => const StartFailed('no engine in this test'),
    );
    final owners = RepliesFixture(
      session,
      policy: const NoOpinion(),
      settings: settings,
    );
    (replies, gaps) = (owners.replies, owners.gaps);
    addTearDown(owners.dispose);
    explorer = Explorer(
      session: session,
      settings: settings,
      databases: ExplorerDatabases(
        lichess: ScriptedExplorerApi(),
        book: ScriptedBook(),
        thisFile: ScriptedLocalGames(),
        myGames: ScriptedLocalGames(),
      ),
      debounce: Duration.zero,
    );
    addTearDown(explorer.dispose);
    games = gamesOver(fixture.store);
    addTearDown(games.dispose);
    fill = FillGaps(
      session: session,
      jobs: EngineJobs(analysis),
      documents: ScriptedDocumentStore(),
      tools: (_) async => const FillUnavailable('no engine in this test'),
    );
    addTearDown(fill.dispose);
  }

  Workspace workspace() {
    final shelf = RepertoireShelf(
      files: ScriptedFiles(),
      documents: fixture.store,
    );
    final books = booksWith();
    final tree = RepertoireTree(session: session, shelf: shelf, books: books);
    addTearDown(tree.dispose);
    return Workspace(
      session: session,
      saver: saver,
      settings: settings,
      analysis: analysis,
      explorer: explorer,
      games: games,
      replies: replies,
      gaps: gaps,
      shelf: shelf,
      books: books,
      tree: tree,
      fill: fill,
      finds: Finds(store: FindsStore.inMemory),
      myGamesTree: ScriptedLocalGames(),
      openings: OpeningNames(() async => const []),
      coresAvailable: 4,
    );
  }

  Future<void> pump(WidgetTester tester, {ActionLayout? layout}) async {
    await tester.binding.setSurfaceSize(const Size(1200, 820));
    await tester.pumpWidget(
      MaterialApp(
        theme: darkTheme(),
        // The keys belong above every column that edits the document, which
        // is where the shell puts them; here the workspace is the only one.
        home: Scaffold(
          body: WorkspaceKeys(
            session: session,
            analysis: analysis,
            editing: editing,
            tabs: tabs,
            moves: moves,
            child: WorkspaceView(
              workspace: workspace(),
              tabs: layout?.tabs ?? tabs,
              layout: layout,
              editing: editing,
              moves: moves,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  setUp(() async {
    fixture = await openSession(blackChapter);
    session = fixture.session;
    saver = fixture.saver;
    editing = ValueNotifier(false);
    moves = MoveEntry();
    tabs = newWorkspaceTabs()..show(WorkspaceTab.moves);
    settings = SettingsStore();
    startAnalysis();
  });

  tearDown(() {
    settings.dispose();
    tabs.dispose();
    editing.dispose();
    moves.dispose();
    analysis.dispose();
    fixture.dispose();
  });

  testWidgets('shows the chapter, its lines and its variations, and the '
      'navigation row', (tester) async {
    await pump(tester);
    expect(find.text('Main'), findsOneWidget);
    expect(
      find.text('Black · 2 lines, 1 from another position'),
      findsOneWidget,
    );
    Finder inMoves(Finder finder) =>
        find.descendant(of: find.byType(MoveTreeView), matching: finder);
    expect(inMoves(find.textContaining('c5')), findsOneWidget);
    expect(inMoves(find.textContaining('Nc3')), findsOneWidget);
    expect(inMoves(find.text('The Sicilian')), findsOneWidget);
    expect(find.textContaining('[%eval'), findsNothing);
    // The note under the board already names the first move.
    expect(find.byTooltip('Play c5 (→)'), findsOneWidget);
    expect(find.byTooltip('Forward (→)'), findsOneWidget);
    expect(find.byTooltip('End (End)'), findsOneWidget);
  });

  testWidgets('reading shows no comment field, no save line and no undo', (
    tester,
  ) async {
    await pump(tester);
    expect(comment, findsNothing);
    expect(find.text('Saved'), findsNothing);
    expect(find.byTooltip('Undo (Ctrl+Z)'), findsNothing);
    expect(find.text('Engine'), findsOneWidget, reason: 'off keeps the switch');
  });

  testWidgets('Ctrl+E opens the edit strip and Done closes it', (tester) async {
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(editing.value, isTrue);
    expect(comment, findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(comment, findsNothing);
  });

  testWidgets('a right-drag on the board draws an arrow into the comment of '
      'the move under the cursor, the board shows it, and a left click takes '
      'it out again', (tester) async {
    await pump(tester);
    session.goTo(NodePath.of(const [0]));
    await tester.pump();
    final board = find.byType(Chessboard);
    final corner = tester.getTopLeft(board);
    final side = tester.getSize(board).width / 8;
    // Black's chapter: the board has Black below, so files run h to a.
    Offset at(int file, int rank) =>
        corner + Offset((7 - file + 0.5) * side, (rank + 0.5) * side);
    final gesture = await tester.startGesture(
      at(6, 0),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await gesture.moveTo(at(5, 2));
    await gesture.up();
    await tester.pump();
    expect(
      session.commentAt(session.cursor),
      'The Sicilian [%eval 0.30] [%cal Gg1f3]',
    );
    expect(
      tester.widget<BoardArrows>(find.byType(BoardArrows)).arrows,
      contains(const BoardShape(Square.g1, Square.f3, ShapeColour.green)),
    );
    expect(find.textContaining('[%cal'), findsNothing);
    await tester.tapAt(at(4, 4));
    await tester.pump();
    expect(session.commentAt(session.cursor), 'The Sicilian [%eval 0.30]');
    expect(
      tester.widget<BoardArrows>(find.byType(BoardArrows)).arrows,
      isEmpty,
    );
  });

  testWidgets('clicking a variation move puts the cursor on it', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.textContaining('Nc3'));
    await tester.pump();
    expect(session.cursor, NodePath.of([0, 1]));
    expect(session.currentMove?.san, 'Nc3');
    // Two moves render as "2... Nc6"; walk on instead of picking one.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(session.cursor, NodePath.of([0, 1, 0]));
    await tester.tap(find.textContaining('cxd4'));
    await tester.pump();
    expect(session.cursor, NodePath.of([0, 0, 0, 0, 0]));
  });

  testWidgets('the arrows walk the line; Home and End are its ends', (
    tester,
  ) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(session.currentMove?.san, 'Nf3');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(session.currentMove?.san, 'c5');
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    expect(session.currentMove?.san, 'cxd4');
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    expect(session.cursor.isRoot, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    expect(session.currentMove?.san, 'cxd4');
    await tester.sendKeyEvent(LogicalKeyboardKey.pageUp);
    expect(session.cursor.isRoot, isTrue);
  });

  testWidgets('four real Explorer panes and Expectimax fit the workspace', (
    tester,
  ) async {
    final layout = ActionLayout(newWorkspaceTabs(), explorer)..arrange(4);
    addTearDown(layout.dispose);
    for (var index = 0; index < 4; index++) {
      layout.pane(index).show(WorkspaceTab.explorer);
    }
    await pump(tester, layout: layout);
    await tester.pumpAndSettle();
    expect(find.byType(ExplorerPane), findsNWidgets(4));
    expect(tester.takeException(), isNull);
    layout.pane(0).show(WorkspaceTab.search);
    await tester.pumpAndSettle();
    expect(find.byType(ExplorerPane), findsNWidgets(3));
    expect(find.text('Settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('game heading stays above the Action Tabs in every reading tab', (
    tester,
  ) async {
    await pump(tester);
    for (final tab in [
      WorkspaceTab.moves,
      WorkspaceTab.replies,
      WorkspaceTab.explorer,
    ]) {
      tabs.show(tab);
      await tester.pumpAndSettle();
      expect(
        tester.getBottomLeft(find.byType(ReadingHeader)).dy,
        lessThanOrEqualTo(
          tester.getTopLeft(find.byType(PaneTabStrip<WorkspaceTab>)).dy,
        ),
      );
    }
  });

  testWidgets('engine off returns its line space and keeps the switch', (
    tester,
  ) async {
    analysis.dispose();
    final engine = ScriptedEngine();
    analysis = EngineAnalysis(session, () async => Started(engine));
    await pump(tester);
    final field = find.byTooltip('Type a move (/)');
    final offAt = tester.getTopLeft(field).dy;
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(field).dy - offAt,
      engineRowHeight * analysis.multiPv,
    );
    await tester.tap(find.byTooltip('Turn engine off (E)'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(field).dy, offAt);
  });

  testWidgets('the engine gear makes room for its settings while it is open', (
    tester,
  ) async {
    await pump(tester);
    final field = find.byTooltip('Type a move (/)');
    final offAt = tester.getTopLeft(field).dy;
    await tester.tap(find.byTooltip('Engine settings'));
    await tester.pumpAndSettle();
    expect(find.text('CPU cores'), findsOneWidget);
    expect(tester.getTopLeft(field).dy - offAt, engineRowHeight * 3);
    await tester.tap(find.byTooltip('Show lines'));
    await tester.pumpAndSettle();
    expect(find.text('CPU cores'), findsNothing);
    expect(tester.getTopLeft(field).dy, offAt);
  });

  testWidgets('F turns the board over; E asks for the engine', (tester) async {
    await pump(tester);
    expect(session.orientation.name, 'black');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    expect(session.orientation.name, 'white');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pumpAndSettle();
    expect(analysis.state, isA<EngineFailed>(), reason: 'it was asked');
  });

  testWidgets('up and down walk the games of a viewed file, under the '
      'board too', (tester) async {
    final viewed = await viewerOver(threeGameFile);
    addTearDown(viewed.dispose);
    await viewed.open();
    session = viewed.session;
    saver = viewed.saver;
    analysis.dispose();
    startAnalysis();
    await pump(tester);
    expect(find.text('of 3'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(session.game, 1);
    expect(find.text('Ding, Liren – Giri, Anish'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(session.game, 0);
    await tester.tap(find.byTooltip('Next game (↓)'));
    await tester.pump();
    expect(session.game, 1);
  });

  testWidgets('a merged chapter has no games to walk and no counter', (
    tester,
  ) async {
    await pump(tester);
    expect(find.textContaining('of '), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(session.game, isNull);
  });

  testWidgets('typing in the comment keeps the arrows and Ctrl+Z', (
    tester,
  ) async {
    final sicilian = NodePath.of([0]);
    editing.value = true;
    await pump(tester);
    session.goTo(sicilian);
    session.setComment(sicilian, 'Mine'); // one edit there is to take back
    await tester.pumpAndSettle();
    final field = comment;
    await tester.tap(field);
    await tester.enterText(field, 'Mine words');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(session.cursor, sicilian, reason: 'the arrow moved the caret');
    final editable = tester.widget<EditableText>(
      find.descendant(of: comment, matching: find.byType(EditableText)),
    );
    expect(editable.controller.selection.baseOffset, 'Mine words'.length - 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      session.commentAt(sicilian),
      contains('Mine'),
      reason: 'Ctrl+Z belongs to the field, not the document',
    );
    expect(saver.canUndo, isTrue);
  });

  testWidgets('Ctrl+Tab walks the tabs, Ctrl+W closes the one that is up '
      'and the strip goes with it', (tester) async {
    tabs = PaneTabs(
      tabs.tabs,
      open: const [
        WorkspaceTab.moves,
        WorkspaceTab.train,
        WorkspaceTab.replies,
        WorkspaceTab.explorer,
        WorkspaceTab.search,
      ],
    );
    await pump(tester);
    expect(find.text('Moves'), findsOneWidget);
    expect(find.text('Replies'), findsOneWidget);
    expect(find.byType(MoveTreeView), findsOneWidget);
    expect(find.byType(RepliesPane), findsNothing);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(tabs.selected, WorkspaceTab.train);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.pumpAndSettle();
    expect(tabs.selected, WorkspaceTab.moves);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(tabs.selected, WorkspaceTab.replies);
    expect(find.byType(RepliesPane), findsOneWidget);
    expect(find.text('Next gap'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.pumpAndSettle();
    expect(tabs.open, [
      WorkspaceTab.moves,
      WorkspaceTab.explorer,
      WorkspaceTab.search,
    ]);
    expect(find.byType(MoveTreeView), findsOneWidget);
    expect(find.text('Next gap'), findsNothing);
    // The explorer is the third tab, its databases along its top.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(tabs.selected, WorkspaceTab.explorer);
    expect(find.byType(ExplorerPane), findsOneWidget);
    expect(find.text('Masters'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(tabs.open, [WorkspaceTab.moves, WorkspaceTab.search]);
    tabs.close(WorkspaceTab.search);
    await tester.pumpAndSettle();
    expect(tabs.open, [WorkspaceTab.moves]);
    expect(find.text('Moves'), findsOneWidget, reason: 'stable tab strip');
    tabs.show(WorkspaceTab.replies);
    await tester.pumpAndSettle();
    expect(find.byType(RepliesPane), findsOneWidget);
  });

  testWidgets('with nothing open it is the analysis board', (tester) async {
    final empty = ScriptedDocumentStore();
    saver = DocumentSaver(empty, delay: Duration.zero);
    session = DocumentSession(empty, saver);
    analysis.dispose();
    startAnalysis();
    await pump(tester);
    expect(find.text('Analysis'), findsNothing);
    expect(find.text('Temporary analysis'), findsNothing);
    expect(find.text('No moves'), findsOneWidget);
  });
}
