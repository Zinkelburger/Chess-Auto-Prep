import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../chess/pgn/comment_text.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/move_label.dart';
import '../ui/theme.dart';
import 'comment_blocks.dart';
import 'document_session.dart';
import 'line_preview.dart';

/// The move on the board and what the file says about it, under the board
/// where the eye already is, as Lichess shows it: `14. Nf5!  Good move`
/// on a fixed row, then the note written before the move and the one after
/// it, read as the moves column reads them. At the start of the game it is
/// the game's introduction, with no move row. The card keeps the height it
/// is given whatever it holds, so stepping through the moves never moves
/// it; a long note scrolls inside it. With nothing to say there is no card.
class MoveNote extends StatefulWidget {
  const MoveNote({super.key, required this.session});

  final DocumentSession session;

  @override
  State<MoveNote> createState() => _MoveNoteState();
}

class _MoveNoteState extends State<MoveNote> with CommentPreviews<MoveNote> {
  @override
  DocumentSession get session => widget.session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session.anyChange,
      builder: (context, _) {
        final tree = session.tree;
        if (tree == null) return const SizedBox.shrink();
        final path = session.cursor;
        final move = session.currentMove;
        // Each note with the position it is read from and the move a line
        // written in it is played from.
        final notes = <(String?, Fen, NodePath)>[
          if (move == null)
            (tree.rootComment, tree.rootFen, path)
          else ...[
            (move.startingComment, tree.fenAt(path.parent), path.parent),
            (move.comment, move.fen, path),
          ],
        ].where((note) => displayComment(note.$1 ?? '').isNotEmpty).toList();
        if (move == null && notes.isEmpty) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        return LinePreviewOverlay(
          preview: preview,
          orientation: session.orientation,
          child: Material(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(readingCardRadius),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              // A new move starts its note at the top.
              key: ValueKey(path),
              padding: const EdgeInsets.fromLTRB(
                readingCardInset,
                Space.m,
                readingCardInset,
                Space.m,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (move != null) _MoveRow(move: move),
                  for (final (comment, at, from) in notes)
                    CommentBlocks(
                      comment: comment!,
                      at: at,
                      orientation: session.orientation,
                      onHover: hoverMove,
                      onLeave: leaveMove,
                      onPlay: (moves) => playFrom(from, moves),
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

/// `14. Nf5!` in the moves' face, and what the glyph means beside it.
class _MoveRow extends StatelessWidget {
  const _MoveRow({required this.move});

  final MoveNode move;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glyphs = move.nags.map(nagGlyph).nonNulls.join();
    final meaning = move.nags.map(_meaning).nonNulls.firstOrNull;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.xs),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${moveNumberLabel(move, startsLine: true)} ',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            TextSpan(
              text: '${move.san}$glyphs',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (meaning != null)
              TextSpan(
                text: '   $meaning',
                style: readingProseText.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontSize: 14,
                ),
              ),
          ],
        ),
        style: readingMoveText.copyWith(color: scheme.onSurface),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// What a reader says for each of the six glyphs.
String? _meaning(int nag) => switch (nag) {
  1 => 'Good move',
  2 => 'Mistake',
  3 => 'Brilliant move',
  4 => 'Blunder',
  5 => 'Interesting move',
  6 => 'Dubious move',
  _ => null,
};
