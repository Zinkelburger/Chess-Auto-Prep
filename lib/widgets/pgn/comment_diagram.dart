import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../theme/app_text_styles.dart';
import '../chess_board_widget.dart';

/// A position quoted in a comment, independent of the game's move tree.
class CommentDiagramBoard extends StatelessWidget {
  final String fen;

  const CommentDiagramBoard({super.key, required this.fen});

  @override
  Widget build(BuildContext context) {
    final Position position;
    try {
      position = Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      // Malformed source material should remain readable, never disappear.
      return SelectableText(fen, style: AppTextStyles.mono);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tooltip(
            message: fen,
            child: AspectRatio(
              aspectRatio: 1,
              child: ChessBoardWidget(
                position: position,
                enableUserMoves: false,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Comment position · ${position.turn == Side.white ? 'White' : 'Black'} to move',
            style: AppTextStyles.caption,
          ),
        ],
      ),
    );
  }
}
