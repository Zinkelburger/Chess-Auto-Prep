part of 'tactics_browse_panel.dart';

class TacticsBrowseHeader extends StatelessWidget {
  const TacticsBrowseHeader({super.key});

  static const _headerStyle = TextStyle(
    fontWeight: FontWeight.bold,
    fontSize: 12,
    color: AppColors.onSurfaceMuted,
  );

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          // Leading space of the rows: board preview + the action buttons.
          SizedBox(width: 168),
          SizedBox(width: 72, child: Text('Type', style: _headerStyle)),
          SizedBox(width: 8),
          SizedBox(width: 80, child: Text('Rating', style: _headerStyle)),
          SizedBox(width: 8),
          Expanded(flex: 3, child: Text('Game', style: _headerStyle)),
          SizedBox(width: 8),
          Expanded(flex: 2, child: Text('Position', style: _headerStyle)),
          SizedBox(width: 8),
          Expanded(flex: 2, child: Text('Played → Best', style: _headerStyle)),
          SizedBox(width: 8),
          SizedBox(
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

  /// Blue / amber / red, the meaning every chess site gives those three.
  /// Custom puzzles carry no engine severity, so they stay in plain ink.
  static Color _severityColor(String mistakeType) => switch (mistakeType) {
    '??' => AppColors.mistakeBlunder,
    '?' => AppColors.mistakeMistake,
    '?!' => AppColors.mistakeInaccuracy,
    _ => AppColors.mistakeCustom,
  };

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
              StaticBoardThumbnail(fen: position.fen),
              const SizedBox(width: 8),
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
                    icon: const Icon(Icons.play_arrow, size: 18),
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
                  // Neutral, like every other icon in the row: a red X on
                  // every line reads as a warning about the tactic rather
                  // than as one of three equal-weight row actions. The
                  // confirm dialog is what guards the delete.
                  icon: const Icon(
                    Icons.close,
                    size: 16,
                    color: AppColors.onSurfaceMuted,
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
                width: 72,
                // The severity in words, matching the trainer's "You played
                // h5 (blunder)". `??`/`?`/`?!` was one glyph the reader had
                // to decode, and the column it saved was never needed. In the
                // usual blue/amber/red, so the column can also be read as a
                // colour while scrolling.
                child: Text(
                  pos.mistakeType == 'custom' ? 'custom' : pos.mistakeLabel,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    color: _severityColor(pos.mistakeType),
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
                // Where the position sits, and nothing else. The flaw
                // tags ("reversed · miss · middlegame · hasty") used to
                // trail this line: taxonomy the miner needs and a solver
                // never reads, four items wide on every row. They are still
                // stored, and still filterable from the bar above.
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
                  // The whole trainable line, not just its first move: a
                  // 3-move tactic listed as "h5 → Qf3" was indistinguishable
                  // from a one-mover.
                  '${pos.userMove} → ${pos.correctLine.join(' ')}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontFamily: 'SourceCodePro',
                  ),
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
