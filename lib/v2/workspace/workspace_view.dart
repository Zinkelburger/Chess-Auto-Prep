import 'dart:math';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';
import 'board_view.dart';
import 'document_session.dart';
import 'engine_analysis.dart';
import 'engine_pane.dart';
import 'eval_bar.dart';
import 'move_tree_view.dart';

/// The board with its evaluation bar on the left; the chapter, the engine
/// and the moves on the right; arrow keys to walk the line.
class WorkspaceView extends StatelessWidget {
  const WorkspaceView({
    super.key,
    required this.session,
    required this.analysis,
  });

  final DocumentSession session;
  final EngineAnalysis analysis;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): session.back,
        const SingleActivator(LogicalKeyboardKey.arrowRight): session.forward,
        const SingleActivator(LogicalKeyboardKey.arrowUp): session.toStart,
        const SingleActivator(LogicalKeyboardKey.arrowDown): session.toEnd,
      },
      child: Focus(
        autofocus: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(Space.l),
                child: _BoardWithBar(session: session, analysis: analysis),
              ),
            ),
            const VerticalDivider(width: 1),
            SizedBox(
              width: 360,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ChapterHeader(session: session),
                  const Divider(height: 1),
                  EnginePane(analysis: analysis),
                  const Divider(height: 1),
                  Expanded(child: MoveTreeView(session: session)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
          constraints.maxWidth - EvalBar.width - Space.s,
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
                    score: analysis.snapshot?.best.score,
                    orientation: session.orientation,
                  ),
                  const SizedBox(width: Space.s),
                  SizedBox(
                    width: side,
                    child: BoardView(
                      fen: session.fen,
                      orientation: session.orientation,
                      lastMove: session.currentMove?.uci,
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

class _ChapterHeader extends StatelessWidget {
  const _ChapterHeader({required this.session});

  final DocumentSession session;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final chapter = session.chapter;
        if (chapter == null) {
          return Padding(
            padding: const EdgeInsets.all(Space.m),
            child: Text('Open a chapter', style: text.bodySmall),
          );
        }
        final side = chapter.side == Side.white ? 'White' : 'Black';
        final lines = '${chapter.gameCount} lines';
        final skipped = chapter.skippedGames == 0
            ? ''
            : ', ${chapter.skippedGames} from another position';
        return Padding(
          padding: const EdgeInsets.all(Space.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(chapter.name, style: text.titleMedium),
              const SizedBox(height: Space.xs),
              Text('$side · $lines$skipped', style: text.bodySmall),
            ],
          ),
        );
      },
    );
  }
}
