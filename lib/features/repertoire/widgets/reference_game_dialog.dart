import 'package:dartchess/dartchess.dart';
import 'package:flutter/material.dart';

import '../../../models/pgn_game_entry.dart';
import '../../../theme/app_text_styles.dart';
import '../../../widgets/chess_board_widget.dart';
import '../../../widgets/pgn_viewer_widget.dart';

/// A separate cursor lets a reference game be inspected without losing the
/// repertoire position or writing reference moves into the chapter.
Future<void> showReferenceGame(
  BuildContext context,
  PgnGameEntry game,
  String fen,
) => showDialog<void>(
  context: context,
  builder: (_) => _ReferenceGameDialog(game: game, fen: fen),
);

class _ReferenceGameDialog extends StatefulWidget {
  const _ReferenceGameDialog({required this.game, required this.fen});
  final PgnGameEntry game;
  final String fen;
  @override
  State<_ReferenceGameDialog> createState() => _ReferenceGameDialogState();
}

class _ReferenceGameDialogState extends State<_ReferenceGameDialog> {
  final _reader = PgnViewerWidgetController();
  Position _position = Chess.initial;

  @override
  Widget build(BuildContext context) => Dialog(
    child: SizedBox(
      width: 1000,
      height: 620,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.game.label,
                    style: AppTextStyles.body,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Close reference game',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final board = Padding(
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: ChessBoardWidget(position: _position),
                    ),
                  ),
                );
                final notation = PgnViewerWidget(
                  pgnText: widget.game.pgnText,
                  controller: _reader,
                  onGameLoaded: () {
                    if (!mounted) return;
                    _reader.goToFen(widget.fen);
                  },
                  onPositionChanged: (position) {
                    if (mounted) setState(() => _position = position);
                  },
                );
                return constraints.maxWidth < 650
                    ? Column(
                        children: [
                          Expanded(child: board),
                          Expanded(child: notation),
                        ],
                      )
                    : Row(
                        children: [
                          Expanded(child: board),
                          Expanded(child: notation),
                        ],
                      );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
