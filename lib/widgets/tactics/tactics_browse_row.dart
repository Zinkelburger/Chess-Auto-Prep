part of 'tactics_browse_panel.dart';

class TacticsBrowseHeader extends StatelessWidget {
  const TacticsBrowseHeader({super.key, this.showBoards = false});

  /// Match the leading space of the rows (board preview + action buttons).
  final bool showBoards;

  static const _headerStyle = TextStyle(
    fontWeight: FontWeight.bold,
    fontSize: 12,
    color: Colors.grey,
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          SizedBox(width: showBoards ? 168 : 100),
          const SizedBox(width: 32, child: Text('Type', style: _headerStyle)),
          const SizedBox(width: 8),
          const SizedBox(width: 80, child: Text('Rating', style: _headerStyle)),
          const SizedBox(width: 8),
          const Expanded(flex: 3, child: Text('Game', style: _headerStyle)),
          const SizedBox(width: 8),
          const Expanded(flex: 2, child: Text('Context', style: _headerStyle)),
          const SizedBox(width: 8),
          const Expanded(
            flex: 2,
            child: Text('Played → Best', style: _headerStyle),
          ),
          const SizedBox(width: 8),
          const SizedBox(
            width: 60,
            child: Text(
              'Stats',
              style: _headerStyle,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}

class TacticsBrowseRow extends StatelessWidget {
  const TacticsBrowseRow({
    super.key,
    required this.position,
    required this.index,
    required this.isSelected,
    required this.onTap,
    this.onTrain,
    required this.onDelete,
    required this.onEdit,
    this.onSetRating,
    this.selectMode = false,
    this.checked = false,
    this.showBoard = false,
  });

  final TacticsPosition position;
  final int index;
  final bool isSelected;
  final VoidCallback onTap;

  /// Loads this tactic onto the board for training. Hidden when null.
  final VoidCallback? onTrain;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final ValueChanged<int>? onSetRating;
  final bool selectMode;
  final bool checked;

  /// Show a small board preview of the position.
  final bool showBoard;

  @override
  Widget build(BuildContext context) {
    final pos = position;

    final isDimmed = pos.rating == 1;

    return InkWell(
      onTap: onTap,
      child: Opacity(
        opacity: isDimmed ? 0.45 : 1.0,
        child: Container(
          decoration: BoxDecoration(
            color: isSelected || checked
                ? Theme.of(
                    context,
                  ).colorScheme.primaryContainer.withValues(alpha: 0.3)
                : (index.isEven
                      ? Colors.transparent
                      : Colors.white.withValues(alpha: 0.02)),
            border: Border(
              bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.15)),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              if (showBoard) ...[
                _BoardThumbnail(fen: position.fen),
                const SizedBox(width: 8),
              ],
              if (selectMode)
                Checkbox(
                  value: checked,
                  onChanged: (_) => onTap(),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                )
              else ...[
                if (onTrain != null)
                  IconButton(
                    onPressed: onTrain,
                    icon: const Icon(
                      Icons.play_arrow,
                      size: 18,
                      color: Colors.green,
                    ),
                    tooltip: 'Train this tactic',
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    padding: EdgeInsets.zero,
                  ),
                IconButton(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit, size: 16),
                  tooltip: 'Edit tactic',
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
                ),
                IconButton(
                  onPressed: onDelete,
                  icon: Icon(
                    Icons.close,
                    size: 16,
                    color: Colors.red.withValues(alpha: 0.6),
                  ),
                  tooltip: 'Delete tactic',
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  padding: EdgeInsets.zero,
                ),
              ],
              const SizedBox(width: 4),
              SizedBox(
                width: 32,
                child: Text(
                  pos.mistakeType == 'custom' ? '✎' : pos.mistakeType,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: switch (pos.mistakeType) {
                      '??' => Colors.red,
                      '?!' => Colors.yellow,
                      'custom' => Colors.lightBlue,
                      _ => Colors.orange,
                    },
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 80,
                child: _BrowseStarRating(
                  rating: pos.rating,
                  onSetRating: onSetRating,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 3,
                child: Text(
                  '${pos.gameWhite} vs ${pos.gameBlack}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: Text(
                  pos.positionContext,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: Text(
                  '${pos.userMove} → ${pos.bestMove}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                ),
              ),
              const SizedBox(width: 8),
              PuzzleStatsDisplay(position: pos),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small static board preview for a browse row, oriented so the side to move
/// is at the bottom (same perspective as training).
class _BoardThumbnail extends StatelessWidget {
  const _BoardThumbnail({required this.fen});

  final String fen;

  static const double _size = 60;

  @override
  Widget build(BuildContext context) {
    final Position position;
    try {
      position = Chess.fromSetup(Setup.parseFen(fen));
    } catch (_) {
      return const SizedBox(
        width: _size,
        height: _size,
        child: Icon(Icons.broken_image_outlined, size: 20, color: Colors.grey),
      );
    }
    return SizedBox(
      width: _size,
      height: _size,
      // RepaintBoundary keeps the 64-square board raster out of the list's
      // scroll repaints — without it every scrolled frame redraws each board.
      child: RepaintBoundary(
        child: IgnorePointer(
          child: ChessBoardWidget(
            position: position,
            flipped: position.turn == Side.black,
            enableUserMoves: false,
          ),
        ),
      ),
    );
  }
}

class _BrowseStarRating extends StatelessWidget {
  const _BrowseStarRating({required this.rating, this.onSetRating});

  final int rating;
  final ValueChanged<int>? onSetRating;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final star = i + 1;
        return GestureDetector(
          onTap: onSetRating != null
              ? () => onSetRating!(rating == star ? 0 : star)
              : null,
          child: Icon(
            star <= rating ? Icons.star : Icons.star_border,
            size: 14,
            color: star <= rating ? Colors.amber : Colors.grey[700],
          ),
        );
      }),
    );
  }
}
