part of 'training_lines_panel.dart';

// ---------------------------------------------------------------------------
// SORT CONTROL
// ---------------------------------------------------------------------------

class _SortControl extends StatelessWidget {
  final LineSortMode value;
  final ValueChanged<LineSortMode> onChanged;

  const _SortControl({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          Icon(
            Icons.sort,
            size: 16,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 6),
          Text(
            'Sort',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<LineSortMode>(
            value: value,
            isDense: true,
            underline: const SizedBox.shrink(),
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
            items: [
              for (final mode in LineSortMode.values)
                DropdownMenuItem(value: mode, child: Text(mode.label)),
            ],
            onChanged: (mode) {
              if (mode != null) onChanged(mode);
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ACTION BAR — Learn / Review buttons
// ---------------------------------------------------------------------------

class _ActionBar extends StatelessWidget {
  final int newCount;
  final int dueCount;
  final VoidCallback? onLearn;
  final VoidCallback? onReview;

  const _ActionBar({
    required this.newCount,
    required this.dueCount,
    this.onLearn,
    this.onReview,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: _ActionButton(
              label: 'Learn',
              count: newCount,
              icon: Icons.school_outlined,
              color: Colors.blue,
              onPressed: onLearn,
              theme: theme,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ActionButton(
              label: 'Review',
              count: dueCount,
              icon: Icons.replay_outlined,
              color: Colors.orange,
              onPressed: onReview,
              theme: theme,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final int count;
  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;
  final ThemeData theme;

  const _ActionButton({
    required this.label,
    required this.count,
    required this.icon,
    required this.color,
    this.onPressed,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = onPressed == null;
    final fg = disabled
        ? theme.colorScheme.onSurface.withValues(alpha: 0.3)
        : color;
    return Material(
      color: color.withValues(alpha: disabled ? 0.05 : 0.12),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: fg.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: fg),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// NEEDS SCORING BANNER
// ---------------------------------------------------------------------------

class _NeedsScoringBanner extends StatelessWidget {
  final VoidCallback? onScoreInBuilder;

  const _NeedsScoringBanner({this.onScoreInBuilder});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_fix_high, size: 18, color: Colors.amber),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Lines not scored by ease',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.amber,
                  ),
                ),
                Text(
                  'Generate in Builder to see difficulty and sort by hardest-first.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          if (onScoreInBuilder != null) ...[
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: onScoreInBuilder,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Score in Builder',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
