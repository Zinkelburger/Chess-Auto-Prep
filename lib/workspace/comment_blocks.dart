import 'dart:async';

import 'package:chessground/chessground.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../chess/fen.dart';
import '../chess/pgn/comment_layout.dart';
import '../chess/pv_text.dart';
import '../chess/pgn/game_tree.dart';
import '../ui/theme.dart';
import 'comment_line.dart';
import 'document_session.dart';
import 'line_preview.dart';

/// Asked when the pointer rests on a move written in a comment, with where
/// on the screen it is; and when it leaves.
typedef HoverMove = void Function(PvMove move, Offset anchor);

/// Asked to show the line [moves], written from the position the comment
/// belongs to, as far as its move at [at].
typedef ReadMoves = void Function(List<PvMove> moves, int at);

/// What a view that shows comments does with the moves written in them: a
/// board under the pointer once it rests on one, and a click puts the line
/// on the board as far as that move, without writing it into the file. The
/// view hands [preview] to a [LinePreviewOverlay].
mixin CommentPreviews<T extends StatefulWidget> on State<T> {
  DocumentSession get session;

  final preview = ValueNotifier<LinePreview?>(null);
  Timer? _settle;

  @override
  void dispose() {
    _settle?.cancel();
    preview.dispose();
    super.dispose();
  }

  /// The board appears once the pointer has rested on a move.
  void hoverMove(PvMove move, Offset anchor) {
    _settle?.cancel();
    _settle = Timer(previewDelay, () {
      if (!mounted) return;
      preview.value = LinePreview(
        fen: move.after,
        lastMove: move.uci,
        anchor: anchor,
      );
    });
  }

  void leaveMove() {
    _settle?.cancel();
    preview.value = null;
  }

  /// Shows [moves], written in the comment on the move at [from], as far
  /// as the one at [at].
  void readFrom(NodePath from, List<PvMove> moves, int at) {
    leaveMove();
    session.showCommentLine(from, moves, at);
  }
}

/// A comment as it reads: paragraphs at a book's measure, headings, quotes,
/// diagrams, and lines of analysis whose moves float a board under the
/// pointer and, when they follow on from the move the comment is on, go on
/// the board when clicked; the move on the board is marked.
class CommentBlocks extends StatelessWidget {
  const CommentBlocks({
    super.key,
    required this.comment,
    required this.at,
    required this.orientation,
    required this.onHover,
    required this.onLeave,
    required this.from,
    required this.shown,
    required this.onRead,
  });

  /// The comment as the file has it, tokens and all.
  final String comment;

  /// The position the comment is read from.
  final Fen at;

  final Side orientation;
  final HoverMove onHover;
  final VoidCallback onLeave;

  /// The move the comment belongs to.
  final NodePath from;

  /// The comment line on the board, to mark its move.
  final ValueListenable<CommentLine?> shown;
  final ReadMoves onRead;

  @override
  Widget build(BuildContext context) {
    final blocks = layoutComment(comment, at: at);
    if (blocks.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: proseMaxWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final block in blocks)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.s),
              child: _block(context, block),
            ),
        ],
      ),
    );
  }

  Widget _block(BuildContext context, CommentBlock block) {
    final scheme = Theme.of(context).colorScheme;
    return switch (block) {
      Paragraph(:final spans) => _paragraph(context, spans),
      Heading(:final text) => Text(
        text,
        style: readingProseText.copyWith(
          color: scheme.onSurface,
          fontWeight: FontWeight.w600,
        ),
      ),
      Quote(:final spans) => Container(
        padding: const EdgeInsets.only(left: Space.m),
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: scheme.outline, width: 2)),
        ),
        child: _paragraph(context, spans),
      ),
      Diagram(:final fen) => StaticChessboard(
        size: diagramSize,
        orientation: orientation,
        fen: fen.value,
        settings: BoardTheme.of(context).previewSettings,
      ),
    };
  }

  Widget _paragraph(BuildContext context, List<CommentSpan> spans) {
    final scheme = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        style: readingProseText.copyWith(color: scheme.onSurface),
        children: [
          for (final span in spans)
            switch (span) {
              Words(:final text) => TextSpan(text: text),
              MoveRun(:final moves, :final fromComment) => TextSpan(
                children: [
                  for (final (index, move) in moves.indexed) ...[
                    if (index > 0) const TextSpan(text: ' '),
                    WidgetSpan(
                      alignment: PlaceholderAlignment.baseline,
                      baseline: TextBaseline.alphabetic,
                      child: _InlineMove(
                        move: move,
                        from: from,
                        shown: shown,
                        onHover: onHover,
                        onLeave: onLeave,
                        onTap: fromComment == null
                            ? null
                            : () => onRead(
                                fromComment,
                                fromComment.length - moves.length + index,
                              ),
                      ),
                    ),
                  ],
                ],
              ),
            },
        ],
      ),
    );
  }
}

/// One move written in the prose: set in the move face, in the accent when
/// it can be read on the board, marked as the move list marks the cursor
/// while it is on the board, and under the pointer a board with the
/// position after it.
class _InlineMove extends StatelessWidget {
  const _InlineMove({
    required this.move,
    required this.from,
    required this.shown,
    required this.onHover,
    required this.onLeave,
    required this.onTap,
  });

  final PvMove move;
  final NodePath from;
  final ValueListenable<CommentLine?> shown;
  final HoverMove onHover;
  final VoidCallback onLeave;
  final VoidCallback? onTap;

  /// The bottom centre of this move on the screen, where its board hangs.
  Offset _anchor(BuildContext context) {
    final box = context.findRenderObject() as RenderBox;
    return box.localToGlobal(Offset(box.size.width / 2, box.size.height));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return MouseRegion(
      onEnter: (_) => onHover(move, _anchor(context)),
      onExit: (_) => onLeave(),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(3),
        hoverColor: scheme.primary.withValues(alpha: 0.1),
        child: ValueListenableBuilder<CommentLine?>(
          valueListenable: shown,
          builder: (context, line, child) => DecoratedBox(
            decoration: BoxDecoration(
              color: line != null && line.shows(from, move)
                  ? scheme.primary.withValues(alpha: 0.35)
                  : null,
              borderRadius: BorderRadius.circular(3),
            ),
            child: child,
          ),
          child: Text(
            move.text,
            style: readingMoveText.copyWith(
              color: onTap == null ? scheme.onSurface : scheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}
