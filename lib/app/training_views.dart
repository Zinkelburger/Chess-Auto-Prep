import 'dart:async';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/widgets.dart';

import '../chess/book/book_check.dart' show BookPlace;
import '../chess/fen.dart';
import '../chess/tactics/puzzle.dart';
import '../chess/tactics/source_game.dart' show studyDraft;
import '../features/my_games/book_pane.dart';
import '../features/my_games/game_book.dart';
import '../features/my_games/my_games_panel.dart';
import '../features/tactics/my_games_block.dart';
import '../features/tactics/puzzle_pane.dart';
import '../features/tactics/source_game_pane.dart';
import '../features/tactics/tactics_actions.dart';
import '../features/tactics/tactics_panel.dart';
import '../ui/app_action.dart';
import '../workspace/book_chip.dart';
import '../workspace/repertoire_shelf.dart' show BookFileRef;
import '../workspace/workspace.dart';
import '../workspace/workspace_tabs.dart';
import 'mode.dart';
import 'mode_view.dart';
import 'workspace_requests.dart';

/// Tactics: the puzzle set on the left, the puzzle and the game it came
/// from on the card. It is for solving, so it starts with the engine off
/// and neither heads the card nor counts the file's games: the puzzle says
/// whose game it was and the list is the way to another.
final class TacticsView extends ModeView {
  TacticsView(Workspace workspace, this._requests, this._training)
    : super(workspace, puzzleTabs());

  final WorkspaceRequests _requests;
  final TrainingModes _training;

  @override
  bool get header => false;

  @override
  bool get gameCounter => false;

  @override
  Listenable get changes => Listenable.merge([
    workspace.session,
    workspace.analysis,
    _training.puzzles,
    _training.myGames,
  ]);

  @override
  void entered() {
    if (workspace.analysis.enabled) unawaited(workspace.analysis.disable());
  }

  /// Esc ends the sitting, as the old app's Esc left the puzzle.
  @override
  bool leave() {
    final puzzles = _training.puzzles;
    if (puzzles.run == null) return false;
    puzzles.end();
    return true;
  }

  /// Starts a sitting, from [first] when the list asked for one, with the
  /// Puzzle tab up.
  void _play({Puzzle? first}) {
    tabs.show(WorkspaceTab.puzzle);
    final puzzles = _training.puzzles;
    unawaited(
      first != null
          ? puzzles.show(first)
          : puzzles.run != null
          ? puzzles.continueSession()
          : puzzles.start(),
    );
  }

  /// The solved puzzle's game with the engine on: the Game tab, not
  /// another mode.
  void _analyze() {
    _training.puzzles.inspectAlternative();
    tabs.show(WorkspaceTab.moves);
    unawaited(workspace.analysis.enable());
  }

  /// [puzzle]'s game, or the puzzle alone when it came from none, on a new
  /// analysis board at the puzzle, with the engine on.
  Future<void> _analyzeInGame(Puzzle puzzle) async {
    final game = await _training.sources.gameOf(puzzle);
    if (game == null) {
      return _openBoard(puzzle.fen, puzzle.answer, 0, puzzle.toMove);
    }
    await _openBoard(game.root, game.sans, game.mistake ?? 0, puzzle.toMove);
  }

  Future<void> _openBoard(
    Fen root,
    List<String> sans,
    int ply,
    Side side,
  ) async {
    final opened = await _requests.openLine(
      root: root,
      sans: sans,
      ply: ply,
      side: side,
    );
    if (opened is! RequestDone) return;
    tabs.show(WorkspaceTab.moves);
    unawaited(workspace.analysis.enable());
  }

  @override
  Widget list(Widget toggle) => TacticsPanel(
    set: _training.tactics,
    trainer: _training.puzzles,
    myGames: _training.myGames,
    sources: _training.sources,
    onPlay: _play,
    onAnalyze: (puzzle) => unawaited(_analyzeInGame(puzzle)),
    onAddToStudy: (puzzle) => unawaited(_addGameToStudy(puzzle)),
    trailing: toggle,
  );

  @override
  Widget? tab(BuildContext context, WorkspaceTab tab) => switch (tab) {
    WorkspaceTab.puzzle => ListenableBuilder(
      listenable: _training.tactics,
      builder: (context, _) => PuzzlePane(
        trainer: _training.puzzles,
        onAnalyze: _analyze,
        available: _training.tactics.queue.length,
      ),
    ),
    WorkspaceTab.source => SourceGamePane(
      sources: _training.sources,
      onAnalyze: (puzzle, game, ply) =>
          unawaited(_openBoard(game.root, game.sans, ply, puzzle.toMove)),
    ),
    _ => null,
  };

  @override
  List<AppAction> actions(ModeMenu menu) => [
    ...tacticsActions(
      trainer: _training.puzzles,
      games: _training.myGames,
      session: workspace.session,
      analysis: workspace.analysis,
      tabs: tabs,
      onAccounts: menu.dialogs.accounts,
    ),
    AppAction('Add game to study…', switch (_training.puzzles.up) {
      final up? => () => unawaited(_addGameToStudy(up.puzzle)),
      null => null,
    }, group: 'Tactics'),
  ];

  /// [puzzle]'s game, or the puzzle alone, as a chapter of a study the
  /// user picks.
  Future<void> _addGameToStudy(Puzzle puzzle) async {
    final game = await _training.sources.gameOf(puzzle);
    await _requests.addToStudy([studyDraft(puzzle, game)]);
  }
}

/// My games: the user's games read against their repertoires. ↑ and ↓
/// walk its own list, not the saved file's order, so the board has no
/// game counter; a game opens at the moment its verdict is about.
final class MyGamesView extends ModeView {
  MyGamesView(Workspace workspace, this._requests, this._training)
    : super(workspace, bookTabs());

  final WorkspaceRequests _requests;
  final TrainingModes _training;

  GameBook get _book => _training.book;

  @override
  bool get gameCounter => false;

  @override
  Listenable get changes => Listenable.merge([
    workspace.session,
    workspace.saver,
    workspace.analysis,
    _training.myGames,
    _book,
  ]);

  /// The game on the board, seen from the user's side, at its moment.
  void _open(CheckedGame checked) => unawaited(
    _requests.openGame(
      checked.file,
      game: checked.game.index,
      ply: checked.moment,
      side: checked.game.side,
    ),
  );

  /// The file of the book at [place], in the builder.
  void _readBook(BookPlace place) =>
      unawaited(_requests.readInBuilder(place.file.ref, place.sans));

  @override
  bool walk(int by) {
    final session = workspace.session;
    final next = _book.step(session.source, session.game, by);
    if (next != null) _open(next);
    return true;
  }

  @override
  Widget list(Widget toggle) => MyGamesPanel(
    book: _book,
    session: workspace.session,
    accounts: MyGamesBlock(games: _training.myGames, forPuzzles: false),
    bookChip: BookChip(books: workspace.books, onEdit: _requests.editBooks),
    onOpen: _open,
    trailing: toggle,
  );

  @override
  Widget? tab(BuildContext context, WorkspaceTab tab) =>
      tab == WorkspaceTab.book
      ? BookPane(book: _book, session: workspace.session, onReadBook: _readBook)
      : null;

  @override
  List<AppAction> actions(ModeMenu menu) => [
    ...myGamesActions(_training.myGames, onAccounts: menu.dialogs.accounts),
    ...documentEntries(menu),
    ...tabActions(tabs, layout: layout),
  ];
}
