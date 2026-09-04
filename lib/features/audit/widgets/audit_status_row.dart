/// Status row for the audit findings panel: audit progress / findings counter,
/// the visible-cap editor, and the dismissed-visibility toggle. Extracted from
/// `AuditFindingsPanel`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/time_format.dart';
import 'hunt_controls.dart';

class AuditStatusRow extends StatelessWidget {
  const AuditStatusRow({
    super.key,
    required this.isAuditing,
    required this.nodesChecked,
    required this.totalNodes,
    required this.visibleCount,
    required this.totalMatching,
    required this.selectedIndex,
    required this.hideDismissed,
    required this.capController,
    required this.reachThreshold,
    required this.resultTimestamp,
    required this.onRerunAudit,
    required this.onApplyCap,
    required this.onToggleHideDismissed,
  });

  final bool isAuditing;
  final int nodesChecked;
  final int totalNodes;
  final int visibleCount;
  final int totalMatching;
  final int selectedIndex;
  final bool hideDismissed;
  final TextEditingController capController;
  final String? reachThreshold;
  final DateTime? resultTimestamp;
  final VoidCallback? onRerunAudit;
  final VoidCallback onApplyCap;
  final VoidCallback onToggleHideDismissed;

  @override
  Widget build(BuildContext context) {
    final progressFraction = totalNodes > 0 ? nodesChecked / totalNodes : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isAuditing && totalNodes > 0)
          LinearProgressIndicator(
            value: progressFraction,
            minHeight: 2,
            backgroundColor: AppColors.surfaceInset,
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              if (isAuditing) ...[
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  totalNodes > 0
                      ? '$nodesChecked / $totalNodes positions · $visibleCount findings'
                      : 'Starting audit...',
                  style: AppTextStyles.caption,
                ),
              ] else ...[
                if (totalMatching > visibleCount) ...[
                  const Text('Top', style: AppTextStyles.caption),
                  const SizedBox(width: 3),
                  SizedBox(
                    width: 34,
                    height: 20,
                    child: VisibleCapField(
                      controller: capController,
                      onApply: onApplyCap,
                    ),
                  ),
                  const SizedBox(width: 3),
                  Text('of $totalMatching', style: AppTextStyles.caption),
                  if (reachThreshold != null) ...[
                    const SizedBox(width: 4),
                    Text(
                      '· ≥ $reachThreshold reach',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.engineLine,
                      ),
                    ),
                  ],
                ] else ...[
                  Text('$visibleCount findings', style: AppTextStyles.caption),
                  if (resultTimestamp != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '· ${formatTimeAgo(resultTimestamp!)}',
                      style: AppTextStyles.caption,
                    ),
                  ],
                ],
              ],
              if (selectedIndex >= 0 && visibleCount > 0) ...[
                const SizedBox(width: 8),
                Text(
                  '${selectedIndex + 1} of $visibleCount',
                  style: AppTextStyles.caption,
                ),
              ],
              const Spacer(),
              if (onRerunAudit != null)
                Tooltip(
                  message: 'New audit with different settings',
                  child: IconButton(
                    icon: const Icon(
                      Icons.refresh,
                      size: 14,
                      color: AppColors.onSurfaceMuted,
                    ),
                    onPressed: onRerunAudit,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                    ),
                  ),
                ),
              Tooltip(
                message: hideDismissed ? 'Show dismissed' : 'Hide dismissed',
                child: IconButton(
                  icon: Icon(
                    hideDismissed
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 14,
                    color: AppColors.onSurfaceMuted,
                  ),
                  onPressed: onToggleHideDismissed,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 24,
                    minHeight: 24,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
