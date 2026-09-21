import 'dart:math';

import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';

import '../ui/theme.dart';
import 'board_view.dart';
import 'chapter_header.dart';
import 'comment_panel.dart';
import 'document_saver.dart';
import 'document_session.dart';
import 'engine_analysis.dart';
import 'engine_pane.dart';
import 'eval_bar.dart';
import 'move_tree_view.dart';

/// The board with its evaluation bar on the left; the chapter, the engine,
/// the moves and their comment on the right. The keys that walk the line and
/// take an edit back are [WorkspaceKeys], above every column that edits the
/// document.
class WorkspaceView extends StatelessWidget {
  const WorkspaceView({
    super.key,
    required this.session,
    required this.saver,
    required this.analysis,
    this.moveMenu,
  });

  final DocumentSession session;
  final DocumentSaver saver;
  final EngineAnalysis analysis;

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
          Area(size: sidePanelWidth, min: paneMinWidth, builder: _column),
        ],
      ),
    );
  }

  Widget _board(BuildContext context, Area area) => Padding(
    padding: const EdgeInsets.all(Space.l),
    child: _BoardWithBar(session: session, analysis: analysis),
  );

  Widget _column(BuildContext context, Area area) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ChapterHeader(session: session, saver: saver),
      const Divider(height: 1),
      EnginePane(analysis: analysis),
      const Divider(height: 1),
      Expanded(
        child: MoveTreeView(session: session, moveMenu: moveMenu),
      ),
      const Divider(height: 1),
      CommentPanel(session: session),
    ],
  );
}

/// The largest square board that fits beside the bar, at the top.
class _BoardWithBar extends StatelessWidget {
  const _BoardWithBar({required this.session, required this.analysis});

  final DocumentSession session;
  final EngineAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = min(
          constraints.maxWidth - evalBarWidth - Space.s,
          constraints.maxHeight,
        );
        return Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: side,
            child: ListenableBuilder(
              listenable: Listenable.merge([session, analysis]),
              builder: (context, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  EvalBar(
                    score: analysis.snapshot?.best?.score,
                    orientation: session.orientation,
                  ),
                  const SizedBox(width: Space.s),
                  SizedBox(
                    width: side,
                    child: BoardView(
                      fen: session.fen,
                      orientation: session.orientation,
                      lastMove: session.currentMove?.uci,
                      onMove: session.playMove,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
