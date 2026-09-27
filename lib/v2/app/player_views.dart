import '../chess/fen.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../features/players/analysis_panel.dart';
import '../features/players/player_book_pane.dart';
import '../features/players/player_games.dart';
import '../features/players/player_analysis.dart';
import '../features/players/player_tree_pane.dart';
import '../features/players/players_screen.dart';
import '../storage/chapter_files.dart';
import '../chess/pgn/game_tree.dart';
import '../ui/app_action.dart';
import '../ui/pane_tabs.dart';
import '../workspace/workspace.dart';
import '../workspace/workspace_tabs.dart';
import 'mode_view.dart';
import 'player_wiring.dart';
import 'workspace_requests.dart';

final class PlayerAnalysisView extends ModeView {
  PlayerAnalysisView(Workspace workspace, this.requests, this.players)
    : super(
        workspace,
        PaneTabs(
          const [
            PaneTab(WorkspaceTab.player, 'Player openings', pinned: true),
            PaneTab(WorkspaceTab.moves, 'Game'),
            PaneTab(WorkspaceTab.playerBook, 'My book'),
            PaneTab(WorkspaceTab.explorer, 'Explorer'),
            PaneTab(WorkspaceTab.search, 'Search'),
          ],
          open: const [
            WorkspaceTab.moves,
            WorkspaceTab.explorer,
            WorkspaceTab.search,
          ],
        ),
      );
  final WorkspaceRequests requests;
  final PlayerModes players;
  @override
  Listenable get changes => Listenable.merge([
    players.analysis,
    players.hunt,
    workspace.session,
    workspace.analysis,
  ]);
  @override
  bool get gameCounter => false;
  @override
  void entered() {
    workspace.session.holdsEdits = true;
    unawaited(players.directory.load());
  }

  @override
  void left() {
    workspace.session.holdsEdits = false;
  }

  Future<bool> _open(int index, PlayerPosition? at, {Fen? fen}) async {
    final analysis = players.analysis;
    final corpus = analysis.corpus;
    if (corpus == null || index < 0 || index >= corpus.games.length)
      return false;
    final game = corpus.games[index];
    fen ??= at?.fen;
    if (!await analysis.currentSources()) {
      requests.say(
        'Games changed. Reload this player before opening a result.',
      );
      return false;
    }
    final result = await requests.openGame(
      ChapterRef.at(game.source.file.path),
      game: game.source.index,
      ply: 0,
      side: game.side,
    );
    if (result is! RequestDone || !identical(corpus, analysis.corpus))
      return false;
    if (workspace.session.persistedRevision !=
        analysis.revisionOf(game.source.file)) {
      requests.say(
        'This file changed. Reload the player before opening a result.',
      );
      return false;
    }
    if (fen != null) {
      final path = workspace.session.tree?.mainLineTo(fen);
      if (path != null) workspace.session.goTo(path);
    }
    return true;
  }

  @override
  Widget list(Widget toggle) => AnalysisPanel(
    players: players.directory,
    analysis: players.analysis,
    hunt: players.hunt,
    onOpen: (i, at) => unawaited(_open(i, at)),
    onChoose: players.choose,
    onImport: () => unawaited(players.importPgn()),
    onDownload: (range) => unawaited(players.download(range)),
    onDirectory: players.showDirectory,
    trailing: toggle,
  );
  @override
  Widget? tab(BuildContext context, WorkspaceTab tab) => switch (tab) {
    WorkspaceTab.player => PlayerTreePane(
      analysis: players.analysis,
      session: workspace.session,
      onOpen: (i) => unawaited(_open(i, null, fen: workspace.session.fen)),
    ),
    WorkspaceTab.playerBook => PlayerBookPane(
      book: players.book,
      onBooks: requests.editBooks,
      onOpen: (gap) async {
        if (!await _open(gap.game, null)) return;
        final game = players.analysis.corpus?.games[gap.game];
        if (game != null &&
            workspace.session.source?.path == game.source.file.path)
          workspace.session.goTo(NodePath.of(List.filled(gap.gap.ply + 1, 0)));
      },
    ),
    _ => null,
  };

  @override
  List<AppAction> actions(ModeMenu menu) => [
    AppAction('Players & prep', players.showDirectory, group: 'Player'),
    AppAction(
      'Get latest games',
      players.analysis.player?.accounts.isNotEmpty == true &&
              !players.analysis.busy
          ? () => unawaited(
              players.analysis.select(players.analysis.player!, download: true),
            )
          : null,
      group: 'Player',
    ),
    AppAction(
      'Add PGN games…',
      players.analysis.player == null
          ? null
          : () => unawaited(players.importPgn()),
      group: 'Player',
    ),
    AppAction(
      'Analyze with engine',
      players.analysis.corpus == null || players.hunt.running
          ? null
          : () {
              players.analysis.configure(list: PlayerList.weaknesses);
              unawaited(players.hunt.start());
            },
      group: 'Analysis',
    ),
    AppAction(
      'Check against my book',
      players.analysis.corpus == null
          ? null
          : () {
              tabs.show(WorkspaceTab.playerBook);
              unawaited(players.book.check());
            },
      group: 'Analysis',
    ),
    AppAction(
      'Save line to prep study',
      players.analysis.player == null
          ? null
          : () => unawaited(players.saveLine()),
      group: 'Study',
    ),
    ...documentEntries(menu),
    ...menu.board(),
    ...tabActions(tabs),
  ];
}

final class PlayersView extends ModeView {
  PlayersView(Workspace workspace, this.players)
    : super(workspace, readingTabs());
  final PlayerModes players;
  @override
  Widget list(Widget toggle) => const SizedBox.shrink();
  @override
  void entered() => unawaited(players.directory.load());
  @override
  Listenable get changes => players.directory;
  @override
  List<AppAction> actions(ModeMenu menu) => [
    AppAction(
      'Reload players',
      () => unawaited(players.directory.load()),
      group: 'Players',
    ),
  ];
  @override
  Widget screen(Map<ShortcutActivator, VoidCallback> windowKeys) =>
      CallbackShortcuts(
        bindings: windowKeys,
        child: Focus(
          autofocus: true,
          child: PlayersScreen(
            players: players.directory,
            onAnalyze: players.choose,
            onStudy: (p) => unawaited(players.openStudy(p)),
            onSaved: () => unawaited(players.addSavedPlayers()),
            onLink: (p) => unawaited(players.linkStudy(p)),
            onLinkedStudy: (path, chapter) =>
                unawaited(players.openLinkedStudy(path, chapter)),
            onGroupStudy: (g) => unawaited(players.openGroupStudy(g)),
            onCopy: (g) => unawaited(players.exportGroup(g, copy: true)),
            onExport: (g) => unawaited(players.exportGroup(g)),
          ),
        ),
      );
}
