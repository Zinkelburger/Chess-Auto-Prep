import 'dart:math';

import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';

import '../storage/settings_store.dart';
import '../ui/pane_tabs.dart';
import '../ui/theme.dart';
import 'board_view.dart';
import 'document_saver.dart';
import 'document_session.dart';
import 'edit_strip.dart';
import 'engine_analysis.dart';
import 'engine_pane.dart';
import 'explorer.dart';
import 'explorer_pane.dart';
import 'fill_gaps.dart';
import 'fill_line.dart';
import 'game_counter.dart';
import 'game_fetcher.dart';
import 'gap_hunt.dart';
import 'move_note.dart';
import 'move_tree_view.dart';
import 'nav_row.dart';
import 'reading_header.dart';
import 'replies.dart';
import 'replies_pane.dart';
import 'workspace_tabs.dart';

/// The board with the game counter and the move's note under it on the
/// left; on the right the reading card, top to bottom in a fixed order: the
/// heading, the engine, the fill's line while there is a fill to speak of,
/// the tab strip, the moves, the opponent's replies or the explorer, the
/// edit strip while there is editing or trouble, and the navigation row.
/// The two halves start equal, as the old app's did. The keys that
/// walk the line and take an edit back are [WorkspaceKeys], above every
/// column that edits the document.
class WorkspaceView extends StatelessWidget {
  const WorkspaceView({
    super.key,
    required this.session,
    required this.saver,
    required this.analysis,
    required this.replies,
    required this.gaps,
    required this.explorer,
    required this.games,
    required this.fill,
    required this.tabs,
    required this.editing,
    required this.settings,
    this.moveMenu,
    this.onExplorerGame,
  });

  final DocumentSession session;
  final DocumentSaver saver;
  final EngineAnalysis analysis;
  final Replies replies;
  final GapHunt gaps;
  final Explorer explorer;
  final GameFetcher games;

  /// Asked to open a game the explorer lists, which is the shell's
  /// business: another mode shows it.
  final ValueChanged<ExplorerGame>? onExplorerGame;

  /// The run that writes proposed lines, for its one line on the card.
  final FillGaps fill;

  /// Which of the card's tabs are open and which is up. The shell owns it,
  /// as it owns [editing]: the keys and the Actions menu turn it too.
  final PaneTabs<WorkspaceTab> tabs;

  /// For what the board draws: the coordinates, today.
  final SettingsStore settings;

  /// Whether the edit strip is open. The shell owns it: the Actions menu
  /// and Ctrl+E turn it, and the strip's Done turns it off.
  final ValueNotifier<bool> editing;

  /// What a right-click on a move offers, which is the mode's business: a
  /// study marks where a quiz starts, and nothing else offers anything yet.
  final MoveMenu? moveMenu;

  /// The board and the card beside it, half the workspace each, with a
  /// divider the user can drag between them. The sizes live in the split
  /// view's own state, so they survive a rebuild and are lost with the
  /// window. The board shrinks to what its half leaves it.
  @override
  Widget build(BuildContext context) {
    return MultiSplitViewTheme(
      data: paneTheme(Theme.of(context).colorScheme),
      child: MultiSplitView(
        initialAreas: [
          Area(flex: 1, min: boardPaneMinWidth, builder: _board),
          Area(flex: 1, min: readingPaneMinWidth, builder: _column),
        ],
      ),
    );
  }

  Widget _board(BuildContext context, Area area) => Padding(
    padding: const EdgeInsets.all(Space.l),
    child: _BoardAndCounter(session: session, settings: settings),
  );

  /// The reading column is a card: darker than the window around it, its
  /// corners rounded, the board's margin kept on three sides and the
  /// divider's on the fourth. The words sit in from its edge.
  Widget _column(BuildContext context, Area area) => Padding(
    padding: const EdgeInsets.fromLTRB(0, Space.l, Space.l, Space.l),
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(readingCardRadius),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReadingHeader(session: session),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: readingCardInset - Space.s,
            ),
            child: EnginePane(session: session, analysis: analysis),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: readingCardInset),
            child: FillLine(fill: fill),
          ),
          Expanded(
            child: _Tabbed(
              session: session,
              replies: replies,
              gaps: gaps,
              explorer: explorer,
              games: games,
              tabs: tabs,
              moveMenu: moveMenu,
              onExplorerGame: onExplorerGame,
            ),
          ),
          EditStrip(session: session, saver: saver, editing: editing),
          const Divider(height: 1),
          NavRow(session: session),
        ],
      ),
    ),
  );
}

/// The moves, the opponent's replies or the explorer, under the strip that
/// says which. The tabs are the window's: the shell owns them, the keys
/// walk them and the Actions menu opens and closes them, so this only
/// draws what is up. A new thing the card can show is one more arm of
/// [_body], and one more of [_trailing] when it owns a control.
class _Tabbed extends StatelessWidget {
  const _Tabbed({
    required this.session,
    required this.replies,
    required this.gaps,
    required this.explorer,
    required this.games,
    required this.tabs,
    required this.moveMenu,
    required this.onExplorerGame,
  });

  final DocumentSession session;
  final Replies replies;
  final GapHunt gaps;
  final Explorer explorer;
  final GameFetcher games;
  final PaneTabs<WorkspaceTab> tabs;
  final MoveMenu? moveMenu;
  final ValueChanged<ExplorerGame>? onExplorerGame;

  Widget _body(WorkspaceTab tab) => switch (tab) {
    WorkspaceTab.moves => MoveTreeView(session: session, moveMenu: moveMenu),
    WorkspaceTab.replies => RepliesPane(
      session: session,
      replies: replies,
      gaps: gaps,
    ),
    WorkspaceTab.explorer => ExplorerPane(
      session: session,
      explorer: explorer,
      games: games,
      onOpenGame: onExplorerGame,
    ),
  };

  Widget? _trailing(WorkspaceTab tab) => switch (tab) {
    WorkspaceTab.moves => null,
    WorkspaceTab.replies => _NextGap(gaps: gaps),
    WorkspaceTab.explorer => ExplorerGear(explorer: explorer),
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tabs,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: readingCardInset - Space.m,
            ),
            child: PaneTabStrip(
              tabs: tabs,
              closeShortcut: 'Ctrl+W',
              trailing: _trailing(tabs.selected),
            ),
          ),
          Expanded(child: _body(tabs.selected)),
        ],
      ),
    );
  }
}

/// The one control the Replies tab owns: the way to the next unanswered
/// position. Off while there is no gap to go to.
class _NextGap extends StatelessWidget {
  const _NextGap({required this.gaps});

  final GapHunt gaps;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: gaps,
      builder: (context, _) {
        final found = gaps.walk?.gaps ?? const [];
        return TextButton.icon(
          onPressed: found.isEmpty ? null : gaps.nextGap,
          icon: const Icon(Icons.skip_next, size: IconSize.action),
          label: const Text('Next gap'),
        );
      },
    );
  }
}

/// The largest square board that fits above the counter, at the top, and
/// the move's note in what the board leaves below, when that is enough to
/// read a few lines in.
class _BoardAndCounter extends StatelessWidget {
  const _BoardAndCounter({required this.session, required this.settings});

  final DocumentSession session;
  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = min(
          constraints.maxWidth,
          constraints.maxHeight - navRowHeight - Space.s,
        );
        final below = constraints.maxHeight - side - navRowHeight - 2 * Space.s;
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: side,
            child: Column(
              children: [
                ListenableBuilder(
                  listenable: Listenable.merge([session.anyChange, settings]),
                  builder: (context, _) => BoardView(
                    fen: session.fen,
                    orientation: session.orientation,
                    lastMove: session.currentMove?.uci,
                    onMove: session.playMove,
                    coordinates: settings.value.boardCoordinates,
                  ),
                ),
                const SizedBox(height: Space.s),
                SizedBox(
                  height: navRowHeight,
                  child: GameCounter(session: session),
                ),
                if (below >= moveNoteMinHeight) ...[
                  const SizedBox(height: Space.s),
                  SizedBox(
                    width: side,
                    height: below,
                    child: MoveNote(session: session),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
