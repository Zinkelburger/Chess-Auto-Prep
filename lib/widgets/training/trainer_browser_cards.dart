part of 'trainer_browser.dart';

// ---------------------------------------------------------------------------
// HEADER — title, progress, and the only two coloured buttons on the page
// ---------------------------------------------------------------------------

class _BrowserHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final LineCounts counts;
  final bool dense;
  final VoidCallback? onBack;
  final VoidCallback? onLearn;
  final VoidCallback? onReview;

  /// Read the lines on screen as one page; null hides the button.
  final VoidCallback? onRead;
  final int learnBatchSize;
  final int reviewBatchSize;
  final VoidCallback? onOpenChapterSetup;
  final bool? playingWhite;
  final VoidCallback? onChangePlayingSide;
  final VoidCallback? onOpenSettings;

  const _BrowserHeader({
    required this.title,
    this.subtitle,
    required this.counts,
    required this.dense,
    this.onBack,
    this.onLearn,
    this.onReview,
    this.onRead,
    this.learnBatchSize = 0,
    this.reviewBatchSize = 0,
    this.onOpenChapterSetup,
    this.playingWhite,
    this.onChangePlayingSide,
    this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(dense ? 10 : 16, 12, dense ? 10 : 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (onBack != null) ...[
                IconButton(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                  tooltip: 'Back to all chapters',
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: dense
                          ? theme.textTheme.titleSmall
                          : theme.textTheme.titleLarge,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(
                        subtitle!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceMuted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (playingWhite != null)
                _PlayingSideButton(
                  playingWhite: playingWhite!,
                  dense: dense,
                  onPressed: onChangePlayingSide,
                ),
              if (onOpenChapterSetup != null)
                TextButton.icon(
                  onPressed: onOpenChapterSetup,
                  icon: const Icon(
                    Icons.auto_awesome_motion_outlined,
                    size: 16,
                  ),
                  label: const Text('Chapters…'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.onSurfaceSoft,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              if (onOpenSettings != null)
                IconButton(
                  onPressed: onOpenSettings,
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Training settings…',
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 12),
          _ProgressStrip(counts: counts),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _PrimaryAction(
                  label: 'Learn',
                  hint: 'untrained',
                  icon: Icons.play_arrow_rounded,
                  color: AppColors.srsNew,
                  count: counts.untrained,
                  batchSize: learnBatchSize,
                  dense: dense,
                  onPressed: counts.untrained > 0 ? onLearn : null,
                  emptyHint: 'Nothing left to learn',
                ),
              ),
              SizedBox(width: dense ? 8 : 12),
              Expanded(
                child: _PrimaryAction(
                  label: 'Review',
                  hint: 'due now',
                  icon: Icons.refresh_rounded,
                  color: AppColors.srsDue,
                  count: counts.due,
                  batchSize: reviewBatchSize,
                  dense: dense,
                  onPressed: counts.due > 0 ? onReview : null,
                  emptyHint: 'Nothing due',
                ),
              ),
              if (onRead != null) ...[
                SizedBox(width: dense ? 8 : 12),
                _ReadAction(dense: dense, onPressed: onRead!),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// The third thing to do with a chapter besides Learn and Review: read it.
/// Neutral on purpose — the two coloured tiles are the training actions, and
/// this is the one that touches no training state.
class _ReadAction extends StatelessWidget {
  final bool dense;
  final VoidCallback onPressed;

  const _ReadAction({required this.dense, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.outline),
      ),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Tooltip(
          message: 'Board and notes for every line, on one page',
          waitDuration: const Duration(milliseconds: 400),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 12 : 16,
              vertical: dense ? 10 : 14,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.menu_book_outlined,
                  size: dense ? 20 : 24,
                  color: AppColors.onSurfaceSoft,
                ),
                SizedBox(width: dense ? 8 : 10),
                Text(
                  'Read',
                  style:
                      (dense
                              ? theme.textTheme.titleSmall
                              : theme.textTheme.titleMedium)
                          ?.copyWith(
                            color: AppColors.onSurfaceSoft,
                            fontWeight: FontWeight.w700,
                          ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Black Repertoire" — which side of the loaded file is being trained.
///
/// A header control, not a settings-screen row, because for an imported course
/// this is a *guess*: the file says nothing, so the trainer reads it off the
/// move tree. When the guess is wrong every line asks for the opponent's move,
/// and the only place the user is looking is this list.
class _PlayingSideButton extends StatelessWidget {
  final bool playingWhite;
  final bool dense;
  final VoidCallback? onPressed;

  const _PlayingSideButton({
    required this.playingWhite,
    required this.dense,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final side = playingWhite ? 'White' : 'Black';
    return Tooltip(
      message:
          'This file trains $side — you are asked for '
          "${playingWhite ? "White's" : "Black's"} moves.\n"
          'Click to change which side it trains.',
      waitDuration: const Duration(milliseconds: 400),
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(
          playingWhite ? Icons.circle_outlined : Icons.circle,
          size: 13,
        ),
        label: Text(dense ? side : '$side Repertoire'),
        style: TextButton.styleFrom(
          foregroundColor: AppColors.onSurfaceSoft,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }
}

/// The two big buttons. Bright fill when there is work to do, flat grey when
/// there isn't — "muted" is the whole signal that Review can wait.
class _PrimaryAction extends StatelessWidget {
  final String label;
  final String hint;
  final String emptyHint;
  final IconData icon;
  final Color color;
  final int count;

  /// Lines this press will cover, or 0 when uncapped.
  final int batchSize;
  final bool dense;
  final VoidCallback? onPressed;

  const _PrimaryAction({
    required this.label,
    required this.hint,
    required this.emptyHint,
    required this.icon,
    required this.color,
    required this.count,
    required this.batchSize,
    required this.dense,
    this.onPressed,
  });

  /// "10 now · 920 to go" when the sitting is capped, "12 untrained" when the
  /// whole pool fits in one run.
  String get _subtitle {
    if (batchSize <= 0 || batchSize >= count) return '$count $hint';
    return '$batchSize now · ${count - batchSize} to go';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onPressed != null;
    final fill = enabled ? color : AppColors.surfaceContainer;
    // Dark ink on the bright fills: white fails AA on both #42A5F5 and
    // #FFA726 (see AppColors.onWarning).
    final ink = enabled ? AppColors.onWarning : AppColors.onSurfaceDisabled;

    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? 12 : 16,
            vertical: dense ? 10 : 14,
          ),
          child: Row(
            children: [
              Icon(icon, size: dense ? 20 : 24, color: ink),
              SizedBox(width: dense ? 8 : 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style:
                          (dense
                                  ? theme.textTheme.titleSmall
                                  : theme.textTheme.titleMedium)
                              ?.copyWith(
                                color: ink,
                                fontWeight: FontWeight.w700,
                              ),
                    ),
                    Text(
                      enabled ? _subtitle : emptyHint,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: ink,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// learned / due / untrained as one bar plus a plain-word legend.
class _ProgressStrip extends StatelessWidget {
  final LineCounts counts;

  const _ProgressStrip({required this.counts});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (counts.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                if (counts.learned > 0)
                  Expanded(
                    flex: counts.learned,
                    child: Container(color: AppColors.srsLearned),
                  ),
                if (counts.due > 0)
                  Expanded(
                    flex: counts.due,
                    child: Container(color: AppColors.srsDue),
                  ),
                if (counts.untrained > 0)
                  Expanded(
                    flex: counts.untrained,
                    child: Container(color: AppColors.surfaceInset),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${counts.learned} learned · ${counts.due} due · '
          '${counts.untrained} untrained',
          style: theme.textTheme.bodySmall?.copyWith(
            color: AppColors.onSurfaceMuted,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// LIST TOOLBAR
// ---------------------------------------------------------------------------

class _ListToolbar extends StatelessWidget {
  final String label;
  final LineSortMode sortMode;
  final ValueChanged<LineSortMode>? onSortChanged;
  final VoidCallback? onMarkKnown;

  const _ListToolbar({
    required this.label,
    required this.sortMode,
    this.onSortChanged,
    this.onMarkKnown,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 0),
      child: Row(
        children: [
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              color: AppColors.onSurfaceSoft,
            ),
          ),
          const Spacer(),
          if (onMarkKnown != null)
            Tooltip(
              message:
                  'Check off the lines you already know (learned elsewhere, '
                  'played for years) so they start on the review schedule '
                  'instead of as untrained.',
              waitDuration: const Duration(milliseconds: 400),
              child: TextButton.icon(
                onPressed: onMarkKnown,
                icon: const Icon(Icons.checklist, size: 16),
                label: const Text('Mark lines I know'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.onSurfaceSoft,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          if (onSortChanged != null) ...[
            const SizedBox(width: 8),
            const Icon(Icons.sort, size: 16, color: AppColors.onSurfaceMuted),
            const SizedBox(width: 6),
            DropdownButton<LineSortMode>(
              value: sortMode,
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
                if (mode != null) onSortChanged!(mode);
              },
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// CHAPTER CARD
// ---------------------------------------------------------------------------

class _ChapterCard extends StatelessWidget {
  final String title;
  final LineCounts counts;

  /// Rows in the chapter, which is not [LineCounts.total]: model games are
  /// listed but never trained, so a "Model games" chapter counted zero and
  /// announced itself as "0 lines".
  final int lineCount;
  final bool dense;
  final VoidCallback onTap;

  const _ChapterCard({
    required this.title,
    required this.counts,
    required this.lineCount,
    required this.dense,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: EdgeInsets.fromLTRB(dense ? 12 : 16, 12, 8, 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.divider),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      _ProgressStrip(counts: counts),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  counts.isEmpty && lineCount > 0
                      ? '$lineCount model game'
                            '${lineCount == 1 ? '' : 's'}'
                      : '$lineCount line${lineCount == 1 ? '' : 's'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
                const Icon(
                  Icons.chevron_right,
                  color: AppColors.onSurfaceMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// LINE CARD
// ---------------------------------------------------------------------------

class _LineCard extends StatelessWidget {
  final RepertoireLine line;
  final LineStatus status;
  final RepertoireReviewEntry? entry;

  /// Leading moves that auto-play instead of being quizzed (dimmed).
  final int introLength;
  final bool dense;
  final bool selecting;
  final bool checked;
  final VoidCallback? onPreview;
  final VoidCallback onTap;

  const _LineCard({
    required this.line,
    required this.status,
    this.entry,
    required this.introLength,
    required this.dense,
    required this.selecting,
    required this.checked,
    this.onPreview,
    required this.onTap,
  });

  /// "Untrained" / "Due 3d ago" / "Learned · in 5d" — plain words, muted ink.
  String get _statusText {
    switch (status) {
      case LineStatus.untrained:
        return 'Untrained';
      case LineStatus.due:
        final due = entry?.dueDateUtc;
        if (due == null) return 'Due';
        final ago = DateTime.now().toUtc().difference(due);
        if (ago.inHours < 1) return 'Due now';
        if (ago.inHours < 24) return 'Due ${ago.inHours}h ago';
        return 'Due ${ago.inDays}d ago';
      case LineStatus.learned:
        final due = entry?.dueDateUtc;
        if (due == null) return 'Learned';
        final until = due.difference(DateTime.now().toUtc());
        if (until.inHours < 24) return 'Learned · in ${until.inHours}h';
        return 'Learned · in ${until.inDays}d';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trainedText = formatLineMovesText(line, start: introLength);
    // Every line in a course chapter shares its whole opening, so printing
    // the intro in full made twenty rows read identically for the first sixty
    // characters — and the moves that actually tell them apart sat off the
    // right edge. Show just enough of it to land the reader in the position.
    const introTailPlies = 4;
    final introFrom = introLength > introTailPlies
        ? introLength - introTailPlies
        : 0;
    final introText = introLength > 0
        ? '${introFrom > 0 ? '… ' : ''}'
              '${formatLineMovesText(line, start: introFrom, end: introLength)}'
        : '';
    const moveStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 11.5,
      height: 1.3,
      color: AppColors.onSurfaceMuted,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: checked
            ? AppColors.srsLearned.withValues(alpha: 0.08)
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: EdgeInsets.fromLTRB(dense ? 10 : 14, 10, 8, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: checked
                    ? AppColors.srsLearned.withValues(alpha: 0.5)
                    : AppColors.divider,
              ),
            ),
            child: Row(
              children: [
                if (selecting) ...[
                  Icon(
                    checked ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 20,
                    color: checked
                        ? AppColors.srsLearned
                        : AppColors.onSurfaceMuted,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // The name gets the whole row and up to two lines.
                      // Course exports already truncate their titles at ~30
                      // characters; ellipsising them again turned
                      // "10.Bd2 Be4 11.Qc1 c6 12.a4 #3" into a row of lines
                      // that all read the same.
                      Text(
                        line.name,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        line.isModelGame ? 'Model game' : _statusText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceMuted,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text.rich(
                        TextSpan(
                          children: [
                            if (introText.isNotEmpty)
                              TextSpan(
                                text: '$introText ',
                                style: moveStyle.copyWith(
                                  color: AppColors.onSurfaceDisabled,
                                ),
                              ),
                            TextSpan(text: trainedText, style: moveStyle),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (!selecting) ...[
                  if (onPreview != null)
                    IconButton(
                      onPressed: onPreview,
                      icon: const Icon(Icons.auto_stories_outlined, size: 17),
                      tooltip:
                          'Read this line — board and comments,\n'
                          'no training',
                      visualDensity: VisualDensity.compact,
                      color: AppColors.onSurfaceMuted,
                    ),
                  const SizedBox(width: 2),
                  _ActionPill(
                    label: line.isModelGame ? 'Read' : status.actionLabel,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "Learn ›" affordance on a line row. Visual only — the whole card is
/// the tap target, so there is no second, smaller thing to aim at.
///
/// Full-strength ink on the verb, not the muted grey the rest of the row uses.
/// A grey-outlined pill with grey text is exactly what Material draws for a
/// *disabled* outlined button, so a list of them read as a page where nothing
/// could be clicked. The card stays neutral; only the verb carries weight.
class _ActionPill extends StatelessWidget {
  final String label;

  const _ActionPill({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: theme.colorScheme.outline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          Icon(
            Icons.chevron_right,
            size: 16,
            color: theme.colorScheme.onSurface,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SELECTION BAR — deliberate "mark lines I already know" pass
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
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.outline),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Check every line you already know. Saving puts the checked '
              'lines on the review schedule; unchecked ones go back to '
              'untrained.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.onSurfaceSoft,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '$checkedCount checked',
            style: theme.textTheme.labelMedium?.copyWith(
              color: AppColors.onSurfaceSoft,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: onCancel, child: const Text('Cancel')),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: saving ? null : onSave,
            icon: saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check, size: 16),
            label: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
