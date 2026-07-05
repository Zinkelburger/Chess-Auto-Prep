import 'package:flutter/material.dart';

import '../../models/repertoire_line.dart';
import '../../models/repertoire_move_progress.dart';
import '../../models/repertoire_review_entry.dart';

/// How the Lines tab orders lines within each section.
enum LineSortMode {
  /// Default heuristic: due lines by failure rate, learned lines by due date.
  smart,

  /// Highest cumulative path probability (line importance) first.
  probability,

  /// Hardest to play (lowest playability) first.
  ease,
}

extension LineSortModeLabel on LineSortMode {
  String get label => switch (this) {
        LineSortMode.smart => 'Smart',
        LineSortMode.probability => 'Probability',
        LineSortMode.ease => 'Ease (hardest first)',
      };
}

/// Training-aware lines browser with Learn/Review action buttons and
/// lines grouped into Due / New / Learned sections.
class TrainingLinesPanel extends StatefulWidget {
  final List<RepertoireLine> lines;
  final Map<String, RepertoireReviewEntry> reviewMap;
  final Map<String, RepertoireMoveProgress> moveProgressMap;
  final Map<String, double> playabilityMap;
  final Map<String, ({int ply, double quality, bool isOurMove})> bottleneckMap;
  final bool needsScoring;
  final void Function(RepertoireLine line) onLineSelected;
  final VoidCallback onStartNextNew;
  final VoidCallback onStartNextDue;
  final VoidCallback? onScoreInBuilder;

  const TrainingLinesPanel({
    super.key,
    required this.lines,
    required this.reviewMap,
    required this.moveProgressMap,
    this.playabilityMap = const {},
    this.bottleneckMap = const {},
    this.needsScoring = false,
    required this.onLineSelected,
    required this.onStartNextNew,
    required this.onStartNextDue,
    this.onScoreInBuilder,
  });

  @override
  State<TrainingLinesPanel> createState() => _TrainingLinesPanelState();
}

class _TrainingLinesPanelState extends State<TrainingLinesPanel> {
  LineSortMode _sortMode = LineSortMode.smart;

  /// Highest cumulative probability first; lines without a value sort last.
  int _byProbability(RepertoireLine a, RepertoireLine b) {
    final ai = a.importance;
    final bi = b.importance;
    if (ai == null && bi == null) return 0;
    if (ai == null) return 1;
    if (bi == null) return -1;
    return bi.compareTo(ai);
  }

  /// Hardest to play first (lowest playability); unscored lines sort last.
  int _byEase(RepertoireLine a, RepertoireLine b) {
    final pa = widget.playabilityMap[a.id];
    final pb = widget.playabilityMap[b.id];
    if (pa == null && pb == null) return 0;
    if (pa == null) return 1;
    if (pb == null) return -1;
    return pa.compareTo(pb);
  }

  @override
  Widget build(BuildContext context) {
    final reviewMap = widget.reviewMap;
    final newLines = <RepertoireLine>[];
    final dueLines = <RepertoireLine>[];
    final learnedLines = <RepertoireLine>[];

    for (final line in widget.lines) {
      final entry = reviewMap[line.id];
      if (entry == null || entry.isNew) {
        newLines.add(line);
      } else if (entry.isDue) {
        dueLines.add(line);
      } else {
        learnedLines.add(line);
      }
    }

    switch (_sortMode) {
      case LineSortMode.smart:
        dueLines.sort((a, b) {
          final ea = reviewMap[a.id]!;
          final eb = reviewMap[b.id]!;
          final ratioA = ea.passCount + ea.failCount > 0
              ? ea.failCount / (ea.passCount + ea.failCount)
              : 0.0;
          final ratioB = eb.passCount + eb.failCount > 0
              ? eb.failCount / (eb.passCount + eb.failCount)
              : 0.0;
          final cmp = ratioB.compareTo(ratioA);
          if (cmp != 0) return cmp;
          final aDate = ea.lastReviewedUtc ?? DateTime(2000);
          final bDate = eb.lastReviewedUtc ?? DateTime(2000);
          return aDate.compareTo(bDate);
        });
        learnedLines.sort((a, b) {
          final ea = reviewMap[a.id]!;
          final eb = reviewMap[b.id]!;
          final aDate = ea.dueDateUtc ?? DateTime(2100);
          final bDate = eb.dueDateUtc ?? DateTime(2100);
          return aDate.compareTo(bDate);
        });
      case LineSortMode.probability:
        newLines.sort(_byProbability);
        dueLines.sort(_byProbability);
        learnedLines.sort(_byProbability);
      case LineSortMode.ease:
        newLines.sort(_byEase);
        dueLines.sort(_byEase);
        learnedLines.sort(_byEase);
    }

    return Column(
      children: [
        _ActionBar(
          newCount: newLines.length,
          dueCount: dueLines.length,
          onLearn: newLines.isNotEmpty ? widget.onStartNextNew : null,
          onReview: dueLines.isNotEmpty ? widget.onStartNextDue : null,
        ),
        _SortControl(
          value: _sortMode,
          onChanged: (mode) => setState(() => _sortMode = mode),
        ),
        if (widget.needsScoring)
          _NeedsScoringBanner(onScoreInBuilder: widget.onScoreInBuilder),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            children: [
              if (dueLines.isNotEmpty) ...[
                _SectionHeader(
                  title: 'Due for Review',
                  count: dueLines.length,
                  color: Colors.orange,
                ),
                for (final line in dueLines)
                  _LineRow(
                    line: line,
                    entry: reviewMap[line.id],
                    moveProgressMap: widget.moveProgressMap,
                    playability: widget.playabilityMap[line.id],
                    bottleneck: widget.bottleneckMap[line.id],
                    onTap: () => widget.onLineSelected(line),
                  ),
                const SizedBox(height: 8),
              ],
              if (newLines.isNotEmpty) ...[
                _SectionHeader(
                  title: 'New',
                  count: newLines.length,
                  color: Colors.blue,
                ),
                for (final line in newLines)
                  _LineRow(
                    line: line,
                    entry: reviewMap[line.id],
                    moveProgressMap: widget.moveProgressMap,
                    playability: widget.playabilityMap[line.id],
                    bottleneck: widget.bottleneckMap[line.id],
                    onTap: () => widget.onLineSelected(line),
                  ),
                const SizedBox(height: 8),
              ],
              if (learnedLines.isNotEmpty) ...[
                _CollapsibleSection(
                  title: 'Learned',
                  count: learnedLines.length,
                  color: Colors.green,
                  children: [
                    for (final line in learnedLines)
                      _LineRow(
                        line: line,
                        entry: reviewMap[line.id],
                        moveProgressMap: widget.moveProgressMap,
                        playability: widget.playabilityMap[line.id],
                        bottleneck: widget.bottleneckMap[line.id],
                        onTap: () => widget.onLineSelected(line),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

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
    final fg = disabled ? theme.colorScheme.onSurface.withValues(alpha: 0.3) : color;
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
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
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
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
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
  final VoidCallback onTap;

  const _LineRow({
    required this.line,
    this.entry,
    required this.moveProgressMap,
    this.playability,
    this.bottleneck,
    required this.onTap,
  });

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
    if (entry == null || entry!.isNew) return Colors.blue;
    if (entry!.isDue) return Colors.orange;
    return Colors.green;
  }

  double _moveMastery() {
    if (line.moves.isEmpty) return 0;
    int learned = 0;
    for (int i = 0; i < line.moves.length; i++) {
      final key = '${line.id}:$i';
      final prog = moveProgressMap[key];
      if (prog != null && prog.learned) learned++;
    }
    return learned / line.moves.length;
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: (line.color.toLowerCase() == 'white'
                            ? Colors.white
                            : Colors.black)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    line.color.toLowerCase() == 'white' ? 'W' : 'B',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.6),
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
            Row(
              children: [
                Text(
                  '${line.moves.length} moves',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                ),
                if (playability != null) ...[
                  const SizedBox(width: 8),
                  _PlayabilityChip(value: playability!),
                ],
                if (!isNew && entry != null) ...[
                  const SizedBox(width: 12),
                  _PassFailChip(
                    pass: entry!.passCount,
                    fail: entry!.failCount,
                  ),
                ],
                if (!isNew && mastery > 0) ...[
                  const Spacer(),
                  SizedBox(
                    width: 50,
                    child: _MasteryBar(value: mastery),
                  ),
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
            color: Colors.green,
          ),
        ),
        Text(
          '/',
          style: TextStyle(
            fontSize: 11,
            color: Colors.grey[600],
          ),
        ),
        Text(
          '$fail',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: fail > 0 ? Colors.red : Colors.grey,
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
          backgroundColor:
              Theme.of(context).colorScheme.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation(
            value >= 1.0 ? Colors.green : Colors.blue.withValues(alpha: 0.7),
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
      color = Colors.green;
      label = 'Easy';
    } else if (value >= 0.4) {
      color = Colors.orange;
      label = 'Medium';
    } else {
      color = Colors.red;
      label = 'Hard';
    }

    return Tooltip(
      message: 'Line playability: ${(value * 100).toStringAsFixed(0)}%\n'
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
          const Icon(Icons.warning_amber_rounded, size: 11, color: Colors.red),
          const SizedBox(width: 3),
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: Colors.red),
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Score in Builder', style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }
}
