import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../models/audit_finding.dart';

/// One row in the audit findings list. Extracted from `audit_findings_panel`.
/// Pure presentation: the parent supplies the
/// resolved [color]/[icon] and the action callbacks.
class FindingTile extends StatelessWidget {
  final AuditFinding finding;
  final bool isSelected;
  final Color color;
  final IconData icon;
  final VoidCallback onSelect;
  final VoidCallback onToggleDismiss;

  /// Show the dismiss context menu at the given global position.
  final void Function(Offset globalPosition) onContextMenu;

  const FindingTile({
    super.key,
    required this.finding,
    required this.isSelected,
    required this.color,
    required this.icon,
    required this.onSelect,
    required this.onToggleDismiss,
    required this.onContextMenu,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapUp: (details) => onContextMenu(details.globalPosition),
      child: Material(
        color: isSelected
            ? Theme.of(context).colorScheme.primaryContainer.withAlpha(60)
            : Colors.transparent,
        child: InkWell(
          onTap: onSelect,
          onLongPress: () {
            final box = context.findRenderObject() as RenderBox?;
            if (box != null) {
              final pos = box.localToGlobal(Offset.zero);
              onContextMenu(Offset(pos.dx + 100, pos.dy));
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            child: Row(
              children: [
                Icon(icon, color: color, size: 16),
                const SizedBox(width: 6),
                if (finding.reachProbLabel != null) ...[
                  SizedBox(
                    width: 48,
                    child: Text(
                      finding.reachProbLabel!,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: finding.dismissed
                            ? AppColors.onSurfaceDim
                            : AppColors.engineLine,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        finding.summary,
                        style: TextStyle(
                          fontSize: 12,
                          color: finding.dismissed
                              ? AppColors.onSurfaceMuted
                              : null,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        finding.movePathString,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.onSurfaceMuted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    finding.dismissed ? Icons.undo : Icons.close,
                    size: 16,
                    color: finding.dismissed
                        ? AppColors.onSurfaceMuted
                        : AppColors.onSurfaceSoft,
                  ),
                  tooltip: finding.dismissed ? 'Restore' : 'Dismiss (D)',
                  onPressed: onToggleDismiss,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  hoverColor: AppColors.hoverOverlay,
                  splashRadius: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
