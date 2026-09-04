/// The two shapes a labelled number takes in this app.
///
/// Every pane that shows "Ease 0.72" or a row of headline counts had grown its
/// own private copy — `_StatChip` existed three times over with three
/// different layouts, next to a `_Stat`, a `_StatTile`, a `_MetricChip`, a
/// `_statBadge` and a `_miniStat`. They agreed on the idea and disagreed on
/// every detail: 12 vs 13px labels, bold vs semibold values, `Colors.grey`
/// against [AppColors.onSurfaceMuted], and — the one that actually showed —
/// proportional figures, so a column of evals did not line up.
///
/// Two widgets, because there really are two shapes:
///
/// * [InlineStat] — label and value side by side, for a dense chip strip
///   under a board or inside a details pane.
/// * [StackedStat] — a headline value with its label beneath, for the summary
///   row at the top of a report.
///
/// Both take their type from [AppTextStyles], so the figures are tabular and
/// the greys cannot drift again.
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';

/// `Ease 0.72` — a muted label beside an emphasised value, on one line.
///
/// [separator] is what sits between them: a space by default, `': '` where
/// the surrounding pane reads as a list of properties. [mono] switches both
/// halves to the mono face for values that must align down a column of rows.
class InlineStat extends StatelessWidget {
  const InlineStat({
    super.key,
    required this.label,
    required this.value,
    this.separator = ' ',
    this.mono = false,
    this.valueColor,
  });

  final String label;
  final String value;
  final String separator;
  final bool mono;

  /// Overrides the value's ink — for a stat that is itself a verdict
  /// (a red regression, a green gain). Leave null for ordinary numbers.
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final base = mono ? AppTextStyles.monoDense : AppTextStyles.caption;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label$separator',
          style: base.copyWith(color: AppColors.onSurfaceMuted),
        ),
        Text(
          value,
          style: base.copyWith(
            fontWeight: FontWeight.w600,
            color: valueColor ?? AppColors.ink,
          ),
        ),
      ],
    );
  }
}

/// A headline value with its label beneath it, optionally under an icon.
///
/// Used in the summary strip at the top of a report, where four or five of
/// these sit in a [Row]. Pass [expand] when they share that row evenly;
/// leave it false when the row is scrollable or the widths are content-sized.
class StackedStat extends StatelessWidget {
  const StackedStat({
    super.key,
    required this.value,
    required this.label,
    this.icon,
    this.iconColor,
    this.valueColor,
    this.valueSize = 18,
    this.expand = false,
  });

  final String value;
  final String label;
  final IconData? icon;
  final Color? iconColor;
  final Color? valueColor;

  /// The headline size. 18 is the default summary-strip figure; a denser
  /// card inside a list passes 16.
  final double valueSize;

  final bool expand;

  @override
  Widget build(BuildContext context) {
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, color: iconColor ?? AppColors.onSurfaceMuted, size: 22),
          const SizedBox(height: 4),
        ],
        Text(
          value,
          style: AppTextStyles.title.copyWith(
            fontSize: valueSize,
            fontWeight: FontWeight.bold,
            color: valueColor ?? AppColors.ink,
            fontFeatures: AppTextStyles.tabularFigures,
          ),
        ),
        Text(label, style: AppTextStyles.caption, textAlign: TextAlign.center),
      ],
    );
    return expand ? Expanded(child: column) : column;
  }
}
