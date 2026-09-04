/// Footer row showing the dismissed-findings count with a "Restore all"
/// action, extracted from `AuditFindingsPanel`.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';

class AuditDismissedSection extends StatelessWidget {
  const AuditDismissedSection({
    super.key,
    required this.dismissedCount,
    required this.onRestoreAll,
  });

  final int dismissedCount;
  final VoidCallback onRestoreAll;

  @override
  Widget build(BuildContext context) {
    if (dismissedCount == 0) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.archive_outlined,
            size: 14,
            color: AppColors.onSurfaceMuted,
          ),
          const SizedBox(width: 4),
          Text('$dismissedCount dismissed', style: AppTextStyles.caption),
          const Spacer(),
          TextButton(
            onPressed: onRestoreAll,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 20),
              textStyle: const TextStyle(fontSize: 12),
            ),
            child: const Text('Restore all'),
          ),
        ],
      ),
    );
  }
}
