import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../chess/pgn/comment_text.dart';
import '../chess/pgn/game_tree.dart';
import '../chess/pgn/move_label.dart';
import '../ui/app_action.dart';
import '../ui/theme.dart';
import 'comment_blocks.dart';
import 'document_session.dart';
import 'line_preview.dart';

/// The move on the board and what the file says about it, under the board
/// where the eye already is, as Lichess shows it: `14. Nf5!  Good move`
/// on a fixed row, then the note written before the move and the one after
/// it, read as the moves column reads them. At the start of the game it is
/// the game's introduction, then the first move and its note, muted, so a
/// game opened on the empty start already says how it begins; clicking
/// that move plays it, as → does. The card keeps the height it
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
        // A line still being found shows no notes and no move ahead: a
        // note, or the next move, is often the answer.
        final finding = session.shownTo != null;
        final notes = finding
            ? const <(String, Fen, NodePath)>[]
            : _notesAt(tree, path, move);
        final upcoming = finding || move != null
            ? null
            : tree.nodeAt(path.mainChild);
        if (move == null && upcoming == null && notes.isEmpty) {
          return const SizedBox.shrink();
        }
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
              padding: const EdgeInsets.symmetric(
                horizontal: readingCardInset,
                vertical: Space.m,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (move != null) _MoveRow(move: move),
                  for (final (comment, at, from) in notes)
                    _comment(comment, at, from),
                  if (upcoming != null) ...[
                    if (notes.isNotEmpty) const SizedBox(height: Space.m),
                    _MoveRow(
                      move: upcoming,
                      upcoming: true,
                      onTap: session.forward,
                    ),
                    for (final (comment, at, from) in _notesAt(
                      tree,
                      path.mainChild,
                      upcoming,
                    ))
                      _comment(comment, at, from),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _comment(String comment, Fen at, NodePath from) => CommentBlocks(
    comment: comment,
    at: at,
    orientation: session.orientation,
    onHover: hoverMove,
    onLeave: leaveMove,
    from: from,
    shown: session.commentLine,
    onRead: (moves, at) => readFrom(from, moves, at),
  );
}

/// The notes to show at [path], each with the position it is read from and
/// the move a line written in it is played from: the game's introduction at
/// the start, else the note before [move] and the one after it. Notes with
/// nothing to read are left out.
List<(String, Fen, NodePath)> _notesAt(
  GameTree tree,
  NodePath path,
  MoveNode? move,
) => [
  for (final (comment, at, from) in [
    if (move == null)
      (tree.rootComment, tree.rootFen, path)
    else ...[
      (move.startingComment, tree.fenAt(path.parent), path.parent),
      (move.comment, move.fen, path),
    ],
  ])
    if (comment != null && displayComment(comment).isNotEmpty)
      (comment, at, from),
];

/// `14. Nf5!` in the moves' face, and what the glyph means beside it. The
/// move still to come at the start of a game is muted and plays when
/// clicked.
class _MoveRow extends StatelessWidget {
  const _MoveRow({required this.move, this.upcoming = false, this.onTap});

  final MoveNode move;

  /// This move is not on the board yet: it is the one [onTap] plays.
  final bool upcoming;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final glyphs = move.nags.map(nagGlyph).nonNulls.join();
    final meaning = move.nags.map(_meaning).nonNulls.firstOrNull;
    final ink = upcoming ? scheme.onSurfaceVariant : scheme.onSurface;
    final row = Text.rich(
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
              style: readingGlossText.copyWith(color: scheme.onSurfaceVariant),
            ),
        ],
      ),
      style: readingMoveText.copyWith(color: ink),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.xs),
      child: onTap == null
          ? row
          : Align(
              alignment: Alignment.centerLeft,
              child: Tooltip(
                message: withKey('Play ${move.san}', '→'),
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(Space.xs),
                  child: row,
                ),
              ),
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
