/// Reusable empty-state placeholder with icon, message, and optional action.
///
/// Replaces the duplicated pattern of Icon + spacing + headline + optional
/// subtitle + FilledButton.icon found across 6+ screens/widgets.
library;

import 'package:flutter/material.dart';

class EmptyStatePlaceholder extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final double iconSize;

  /// If non-null, renders a [FilledButton.icon] below the text.
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  /// Optional extra widget rendered below the action button (e.g. recent-files
  /// list or secondary actions).
  final Widget? trailing;

  const EmptyStatePlaceholder({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.iconSize = 64,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSize, color: Colors.grey[500]),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                style: TextStyle(color: Colors.grey[500], fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onAction,
                icon: Icon(actionIcon ?? Icons.add, size: 18),
                label: Text(actionLabel!),
              ),
            ],
            if (trailing != null) ...[const SizedBox(height: 24), trailing!],
          ],
        ),
      ),
    );
  }
}
