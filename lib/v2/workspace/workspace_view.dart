import 'dart:math';

import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';

import '../ui/theme.dart';
import 'board_view.dart';
import 'document_saver.dart';
import 'document_session.dart';
import 'edit_strip.dart';
import 'engine_analysis.dart';
import 'engine_pane.dart';
import 'game_counter.dart';
import 'move_tree_view.dart';
import 'nav_row.dart';
import 'reading_header.dart';

/// The board with the game counter under it on the left; on the right the
/// reading column, top to bottom in a fixed order: the heading, the engine,
/// the moves, the edit strip while there is editing or trouble, and the
/// navigation row. The keys that walk the line and take an edit back are
/// [WorkspaceKeys], above every column that edits the document.
class WorkspaceView extends StatelessWidget {
  const WorkspaceView({
    super.key,
    required this.session,
    required this.saver,
    required this.analysis,
    required this.editing,
    this.moveMenu,
  });

  final DocumentSession session;
  final DocumentSaver saver;
  final EngineAnalysis analysis;

  /// Whether the edit strip is open. The shell owns it: the Actions menu
  /// and Ctrl+E turn it, and the strip's Done turns it off.
  final ValueNotifier<bool> editing;

  /// What a right-click on a move offers, which is the mode's business: a
  /// study marks where a quiz starts, and nothing else offers anything yet.
  final MoveMenu? moveMenu;

  /// The board and the column beside it, with a divider the user can drag
  /// between them. The sizes live in the split view's own state, so they
  /// survive a rebuild and are lost with the window.
  @override
  Widget build(BuildContext context) {
    return MultiSplitViewTheme(
      data: paneTheme(Theme.of(context).colorScheme),
      child: MultiSplitView(
        initialAreas: [
          Area(flex: 1, min: boardPaneMinWidth, builder: _board),
          Area(
            size: sidePanelWidth,
            min: readingPaneMinWidth,
            builder: _column,
          ),
        ],
      ),
    );
  }

  Widget _board(BuildContext context, Area area) => Padding(
    padding: const EdgeInsets.all(Space.l),
    child: _BoardAndCounter(session: session),
  );

  Widget _column(BuildContext context, Area area) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ReadingHeader(session: session),
      const Divider(height: 1),
      EnginePane(session: session, analysis: analysis),
      const Divider(height: 1),
      Expanded(
        child: MoveTreeView(session: session, moveMenu: moveMenu),
      ),
      EditStrip(session: session, saver: saver, editing: editing),
      const Divider(height: 1),
      NavRow(session: session),
    ],
  );
}

/// The largest square board that fits above the counter, at the top.
class _BoardAndCounter extends StatelessWidget {
  const _BoardAndCounter({required this.session});

  final DocumentSession session;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = min(
          constraints.maxWidth,
          constraints.maxHeight - navRowHeight - Space.s,
        );
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: side,
            child: Column(
              children: [
                ListenableBuilder(
                  listenable: session,
                  builder: (context, _) => BoardView(
                    fen: session.fen,
                    orientation: session.orientation,
                    lastMove: session.currentMove?.uci,
                    onMove: session.playMove,
                  ),
                ),
                const SizedBox(height: Space.s),
                SizedBox(
                  height: navRowHeight,
                  child: GameCounter(session: session),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
