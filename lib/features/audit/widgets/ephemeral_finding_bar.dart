/// Banner shown under the board while previewing a missing-move finding.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../models/audit_finding.dart';

class EphemeralFindingBar extends StatelessWidget {
  final AuditFinding finding;

  /// Navigate the repertoire cursor to the previewed position.
  final VoidCallback onGoToPosition;

  /// Dismiss the preview and restore the normal board state.
  final VoidCallback onDismiss;

  const EphemeralFindingBar({
    super.key,
    required this.finding,
    required this.onGoToPosition,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final move = finding.missingMove ?? '?';
    final label = finding.type == AuditFindingType.uncoveredStrongMove
        ? 'Uncovered: $move (engine-strong, preview)'
        : 'Missing: $move (preview)';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: AppColors.info.withAlpha(30),
        border: Border(top: BorderSide(color: AppColors.info.withAlpha(80))),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.visibility_off_outlined,
            size: 14,
            color: AppColors.info,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.info),
            ),
          ),
          TextButton.icon(
            onPressed: onGoToPosition,
            icon: const Icon(Icons.open_in_new, size: 14),
            label: const Text('Go to position', style: TextStyle(fontSize: 11)),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.info,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(
              Icons.close,
              size: 14,
              color: AppColors.onSurfaceMuted,
            ),
            onPressed: onDismiss,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
          ),
        ],
      ),
    );
  }
}
