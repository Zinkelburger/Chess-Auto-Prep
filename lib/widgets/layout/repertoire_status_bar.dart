/// Minimal status bar — only shows actionable badges when there's something to act on.
library;

import 'package:flutter/material.dart';

class RepertoireStatusBar extends StatelessWidget {
  final int findingsCount;
  final String? jobsStatus;

  final VoidCallback? onFindingsTap;
  final VoidCallback? onJobsTap;

  const RepertoireStatusBar({
    super.key,
    this.findingsCount = 0,
    this.jobsStatus,
    this.onFindingsTap,
    this.onJobsTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasContent = findingsCount > 0 || jobsStatus != null;
    if (!hasContent) return const SizedBox.shrink();

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      child: Row(
        children: [
          if (jobsStatus != null)
            _StatusBadge(
              icon: Icons.auto_awesome,
              label: jobsStatus!,
              color: Colors.teal,
              onTap: onJobsTap,
            ),
          if (jobsStatus != null && findingsCount > 0)
            const SizedBox(width: 12),
          if (findingsCount > 0)
            _StatusBadge(
              icon: Icons.policy_outlined,
              label: '$findingsCount findings',
              color: Colors.orange,
              onTap: onFindingsTap,
            ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _StatusBadge({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withAlpha(25),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
