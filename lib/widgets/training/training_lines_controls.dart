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
                DropdownMenuItem(
                  value: mode,
                  child: Tooltip(
                    message: mode.description,
                    waitDuration: const Duration(milliseconds: 400),
                    child: Text(mode.label),
                  ),
                ),
            ],
            onChanged: (mode) {
              if (mode != null) onChanged(mode);
            },
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: value.description,
            child: Icon(
              Icons.help_outline,
              size: 14,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CHAPTER CONTROL — scope training to one chapter
// ---------------------------------------------------------------------------

class _ChapterControl extends StatelessWidget {
  final List<String> chapters;
  final String? value;
  final void Function(String? chapter)? onChanged;

  const _ChapterControl({
    required this.chapters,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 16,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 6),
          Text(
            'Chapter',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButton<String?>(
              value: value,
              isDense: true,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurface,
              ),
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All chapters (${chapters.length})'),
                ),
                for (final chapter in chapters)
                  DropdownMenuItem<String?>(
                    value: chapter,
                    child: Text(chapter, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: onChanged == null
                  ? null
                  : (chapter) => onChanged!(chapter),
            ),
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
              color: AppColors.srsNew,
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
              color: AppColors.srsDue,
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
// SELECTION BAR — deliberate "mark lines as learned" pass
// ---------------------------------------------------------------------------

class _SelectionBar extends StatelessWidget {
  final int checkedCount;
  final bool saving;
  final VoidCallback onSave;
  final VoidCallback? onCancel;

  const _SelectionBar({
    required this.checkedCount,
    required this.saving,
    required this.onSave,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.srsLearned.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.srsLearned.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Check every line you already know. Saving marks checked lines '
            'as learned; unchecked lines go back to New.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                '$checkedCount checked',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: AppColors.srsLearned,
                ),
              ),
              const Spacer(),
              TextButton(onPressed: onCancel, child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: saving ? null : onSave,
                icon: saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check, size: 16),
                label: const Text('Save learned lines'),
              ),
            ],
          ),
        ],
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
        color: AppColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.auto_fix_high, size: 18, color: AppColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Lines not scored by ease',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: AppColors.warning,
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
