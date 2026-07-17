/// Status row for the audit findings panel: audit progress / findings counter,
/// the visible-cap editor, and the dismissed-visibility toggle. Extracted from
/// `AuditFindingsPanel`.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_colors.dart';

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

  static String _formatTimestamp(DateTime ts) {
    final now = DateTime.now();
    final diff = now.difference(ts);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${ts.month}/${ts.day}';
  }

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
                SizedBox(
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
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
              ] else ...[
                if (totalMatching > visibleCount) ...[
                  Text(
                    'Top',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                  const SizedBox(width: 3),
                  SizedBox(
                    width: 34,
                    height: 20,
                    child: TextField(
                      controller: capController,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.onSurfaceSoft,
                      ),
                      textAlign: TextAlign.center,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: const BorderSide(
                            color: AppColors.outline,
                            width: 0.5,
                          ),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: const BorderSide(
                            color: AppColors.outline,
                            width: 0.5,
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(4),
                          borderSide: const BorderSide(
                            color: AppColors.onSurfaceMuted,
                            width: 1,
                          ),
                        ),
                      ),
                      onSubmitted: (_) => onApplyCap(),
                      onTapOutside: (_) {
                        onApplyCap();
                        FocusScope.of(context).unfocus();
                      },
                    ),
                  ),
                  const SizedBox(width: 3),
                  Text(
                    'of $totalMatching',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                  if (reachThreshold != null) ...[
                    const SizedBox(width: 4),
                    Text(
                      '· ≥ $reachThreshold reach',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.engineLine,
                      ),
                    ),
                  ],
                ] else ...[
                  Text(
                    '$visibleCount findings',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                  if (resultTimestamp != null) ...[
                    const SizedBox(width: 6),
                    Text(
                      '· ${_formatTimestamp(resultTimestamp!)}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.onSurfaceMuted,
                      ),
                    ),
                  ],
                ],
              ],
              if (selectedIndex >= 0 && visibleCount > 0) ...[
                const SizedBox(width: 8),
                Text(
                  '${selectedIndex + 1} of $visibleCount',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppColors.onSurfaceMuted,
                  ),
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
