import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Compact per-depth explored/total mini-bars for the tree-build phase —
/// one vertical bar per ply, filled by the explored fraction at that depth.
///
/// Honest in both frontier disciplines: FIFO fills the bars left to right,
/// best-first fills them all concurrently.  A bar's fill can drop when new
/// candidates appear at that depth (the total grows as parents are
/// explored) — that reflects real remaining work, not a rendering bug.
class DepthProgressBars extends StatelessWidget {
  const DepthProgressBars({
    super.key,
    required this.totals,
    required this.explored,
    this.accent,
  });

  /// Per-ply node counts, index = ply (ply 0 — the root — is skipped).
  final List<int> totals;

  /// Per-ply explored counts, aligned with [totals].
  final List<int> explored;

  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? Theme.of(context).colorScheme.primary;
    final bars = <Widget>[];
    for (var ply = 1; ply < totals.length; ply++) {
      final total = totals[ply];
      if (total <= 0) continue;
      final done = ply < explored.length ? explored[ply] : 0;
      final fraction = (done / total).clamp(0.0, 1.0);
      bars.add(
        Tooltip(
          message: 'Ply $ply: $done/$total explored',
          waitDuration: const Duration(milliseconds: 300),
          child: Container(
            width: 7,
            height: 22,
            decoration: BoxDecoration(
              color: AppColors.surfaceInset,
              borderRadius: BorderRadius.circular(2),
            ),
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              heightFactor: fraction,
              widthFactor: 1.0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: fraction >= 1.0 ? color : color.withAlpha(170),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
        ),
      );
    }
    if (bars.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 2, runSpacing: 2, children: bars);
  }
}
