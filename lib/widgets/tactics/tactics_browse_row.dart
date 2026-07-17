part of 'tactics_browse_panel.dart';

class TacticsBrowseHeader extends StatelessWidget {
  const TacticsBrowseHeader({super.key, this.showBoards = false});

  /// Match the leading space of the rows (board preview + action buttons).
  final bool showBoards;

  static const _headerStyle = TextStyle(
    fontWeight: FontWeight.bold,
    fontSize: 12,
    color: AppColors.onSurfaceMuted,
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
                : (index.isEven ? Colors.transparent : AppColors.rowStripe),
            border: const Border(bottom: BorderSide(color: AppColors.divider)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              if (showBoard) ...[
                StaticBoardThumbnail(fen: position.fen),
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
                      color: AppColors.success,
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
                  // Deliberately subdued: a full-strength red X on every row
                  // would shout louder than the content it deletes.
                  icon: Icon(
                    Icons.close,
                    size: 16,
                    color: AppColors.danger.withValues(alpha: 0.6),
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
                      '??' => AppColors.mistakeBlunder,
                      '?!' => AppColors.mistakeInaccuracy,
                      'custom' => AppColors.mistakeCustom,
                      _ => AppColors.mistakeMistake,
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
            color: star <= rating ? AppColors.starAccent : AppColors.starEmpty,
          ),
        );
      }),
    );
  }
}
