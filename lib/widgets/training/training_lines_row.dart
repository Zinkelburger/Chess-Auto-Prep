part of 'training_lines_panel.dart';

// ---------------------------------------------------------------------------
// SECTION HEADERS
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final Color color;

  const _SectionHeader({
    required this.title,
    required this.count,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '($count)',
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.onSurfaceMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _CollapsibleSection extends StatefulWidget {
  final String title;
  final int count;
  final Color color;
  final List<Widget> children;

  const _CollapsibleSection({
    required this.title,
    required this.count,
    required this.color,
    required this.children,
  });

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 14,
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: widget.color,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '(${widget.count})',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
                const Spacer(),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
              ],
            ),
          ),
        ),
        if (_expanded) ...widget.children,
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// LINE ROW
// ---------------------------------------------------------------------------

class _LineRow extends StatelessWidget {
  final RepertoireLine line;
  final RepertoireReviewEntry? entry;
  final Map<String, RepertoireMoveProgress> moveProgressMap;
  final double? playability;
  final ({int ply, double quality, bool isOurMove})? bottleneck;
  final bool introEnabled;
  final VoidCallback onTap;

  const _LineRow({
    required this.line,
    this.entry,
    required this.moveProgressMap,
    this.playability,
    this.bottleneck,
    this.introEnabled = false,
    required this.onTap,
  });

  int get _introLength => introEnabled ? line.uncommentedIntroLength : 0;

  String _statusLabel() {
    if (entry == null || entry!.isNew) return 'New';
    if (entry!.isDue) {
      if (entry!.dueDateUtc == null) return 'Due';
      final ago = DateTime.now().toUtc().difference(entry!.dueDateUtc!);
      if (ago.inMinutes < 60) return 'Due ${ago.inMinutes}m ago';
      if (ago.inHours < 24) return 'Due ${ago.inHours}h ago';
      return 'Due ${ago.inDays}d ago';
    }
    if (entry!.dueDateUtc != null) {
      final until = entry!.dueDateUtc!.difference(DateTime.now().toUtc());
      if (until.inHours < 24) return 'Next: ${until.inHours}h';
      return 'Next: ${until.inDays}d';
    }
    return 'Learned';
  }

  Color _statusColor(ThemeData theme) {
    if (entry == null || entry!.isNew) return AppColors.srsNew;
    if (entry!.isDue) return AppColors.srsDue;
    return AppColors.srsLearned;
  }

  double _moveMastery() {
    // Auto-played intro moves are never quizzed, so they don't count.
    final start = _introLength < line.moves.length ? _introLength : 0;
    final total = line.moves.length - start;
    if (total <= 0) return 0;
    int learned = 0;
    for (int i = start; i < line.moves.length; i++) {
      final key = '${line.id}:$i';
      final prog = moveProgressMap[key];
      if (prog != null && prog.learned) learned++;
    }
    return learned / total;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusColor = _statusColor(theme);
    final mastery = _moveMastery();
    final isNew = entry == null || entry!.isNew;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color:
                        (line.color.toLowerCase() == 'white'
                                ? AppColors.sideWhite
                                : AppColors.sideBlack)
                            .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    line.color.toLowerCase() == 'white' ? 'W' : 'B',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    line.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _statusLabel(),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: statusColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            _MovesPreview(line: line, introLength: _introLength),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  _introLength > 0
                      ? '${line.moves.length - _introLength} to train'
                            ' · $_introLength auto'
                      : '${line.moves.length} moves',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
                if (playability != null) ...[
                  const SizedBox(width: 8),
                  _PlayabilityChip(value: playability!),
                ],
                if (!isNew && entry != null) ...[
                  const SizedBox(width: 12),
                  _PassFailChip(pass: entry!.passCount, fail: entry!.failCount),
                ],
                if (!isNew && mastery > 0) ...[
                  const Spacer(),
                  SizedBox(width: 50, child: _MasteryBar(value: mastery)),
                ],
              ],
            ),
            if (bottleneck != null && bottleneck!.quality < 0.3)
              _BottleneckHint(
                line: line,
                ply: bottleneck!.ply,
                quality: bottleneck!.quality,
                isOurMove: bottleneck!.isOurMove,
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MOVES PREVIEW — full movetext, auto-played intro dimmed
// ---------------------------------------------------------------------------

class _MovesPreview extends StatelessWidget {
  final RepertoireLine line;
  final int introLength;

  const _MovesPreview({required this.line, required this.introLength});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (line.moves.isEmpty) return const SizedBox.shrink();

    final introText = introLength > 0
        ? formatLineMovesText(line, end: introLength)
        : '';
    final trainedText = formatLineMovesText(line, start: introLength);
    final baseStyle = TextStyle(
      fontSize: 11,
      height: 1.35,
      fontFamily: 'monospace',
      color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
    );

    return Tooltip(
      message: formatLineMovesText(line),
      waitDuration: const Duration(milliseconds: 600),
      child: Text.rich(
        TextSpan(
          children: [
            if (introText.isNotEmpty)
              TextSpan(
                text: '$introText ',
                style: baseStyle.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
                ),
              ),
            TextSpan(text: trainedText, style: baseStyle),
          ],
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SMALL HELPER WIDGETS
// ---------------------------------------------------------------------------

class _PassFailChip extends StatelessWidget {
  final int pass;
  final int fail;

  const _PassFailChip({required this.pass, required this.fail});

  @override
  Widget build(BuildContext context) {
    if (pass == 0 && fail == 0) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$pass',
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppColors.success,
          ),
        ),
        const Text(
          '/',
          style: TextStyle(fontSize: 11, color: AppColors.onSurfaceMuted),
        ),
        Text(
          '$fail',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: fail > 0 ? AppColors.danger : AppColors.onSurfaceMuted,
          ),
        ),
      ],
    );
  }
}

class _MasteryBar extends StatelessWidget {
  final double value;

  const _MasteryBar({required this.value});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 4,
        child: LinearProgressIndicator(
          value: value.clamp(0.0, 1.0),
          backgroundColor: Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation(
            value >= 1.0
                ? AppColors.success
                : AppColors.srsNew.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PLAYABILITY CHIP
// ---------------------------------------------------------------------------

class _PlayabilityChip extends StatelessWidget {
  final double value;

  const _PlayabilityChip({required this.value});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String label;
    if (value >= 0.7) {
      color = AppColors.success;
      label = 'Easy';
    } else if (value >= 0.4) {
      color = AppColors.warning;
      label = 'Medium';
    } else {
      color = AppColors.danger;
      label = 'Hard';
    }

    return Tooltip(
      message:
          'Line playability: ${(value * 100).toStringAsFixed(0)}%\n'
          'How natural your moves are to find',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.4), width: 0.5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// BOTTLENECK HINT
// ---------------------------------------------------------------------------

class _BottleneckHint extends StatelessWidget {
  final RepertoireLine line;
  final int ply;
  final double quality;
  final bool isOurMove;

  const _BottleneckHint({
    required this.line,
    required this.ply,
    required this.quality,
    required this.isOurMove,
  });

  @override
  Widget build(BuildContext context) {
    final moveNum = (ply ~/ 2) + 1;
    final moveSan = ply < line.moves.length ? line.moves[ply] : '?';
    final label = isOurMove
        ? 'Hard move: $moveNum. $moveSan'
        : 'Easy for opponent: $moveNum. $moveSan';

    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 11,
            color: AppColors.danger,
          ),
          const SizedBox(width: 3),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: AppColors.danger),
          ),
        ],
      ),
    );
  }
}
