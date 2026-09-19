import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';
import 'board_view.dart';
import 'document_session.dart';
import 'move_tree_view.dart';

/// The board on the left, the moves on the right, arrow keys to walk them.
class WorkspaceView extends StatelessWidget {
  const WorkspaceView({super.key, required this.session});

  final DocumentSession session;

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
        child: ListenableBuilder(
          listenable: session,
          builder: (context, _) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(Space.l),
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: BoardView(
                      fen: session.fen,
                      orientation: session.orientation,
                      lastMove: session.currentMove?.uci,
                    ),
                  ),
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
                    Expanded(child: MoveTreeView(session: session)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChapterHeader extends StatelessWidget {
  const _ChapterHeader({required this.session});

  final DocumentSession session;

  @override
  Widget build(BuildContext context) {
    final chapter = session.chapter;
    final text = Theme.of(context).textTheme;
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
  }
}
