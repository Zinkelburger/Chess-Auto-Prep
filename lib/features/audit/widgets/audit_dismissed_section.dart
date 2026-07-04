/// Footer row showing the dismissed-findings count with a "Restore all"
/// action, extracted from `AuditFindingsPanel`.
library;

import 'package:flutter/material.dart';

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
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.archive_outlined, size: 14, color: Colors.grey[500]),
          const SizedBox(width: 4),
          Text(
            '$dismissedCount dismissed',
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
          const Spacer(),
          TextButton(
            onPressed: onRestoreAll,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 20),
              textStyle: const TextStyle(fontSize: 11),
            ),
            child: const Text('Restore all'),
          ),
        ],
      ),
    );
  }
}
