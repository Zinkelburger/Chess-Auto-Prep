/// Horizontal trail of clickable chips showing navigation history.
library;

import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/navigation_stack.dart';
import 'package:chess_auto_prep/theme/app_colors.dart';

class NavigationTrail extends StatelessWidget {
  final NavigationStack stack;
  final void Function(NavigationEntry entry) onJumpTo;

  const NavigationTrail({
    super.key,
    required this.stack,
    required this.onJumpTo,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: stack,
      builder: (context, _) {
        if (stack.isEmpty) return const SizedBox.shrink();
        return Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).dividerColor,
                width: 0.5,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: stack.length,
                  separatorBuilder: (_, __) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: const Icon(
                      Icons.chevron_right,
                      size: 14,
                      color: AppColors.onSurfaceMuted,
                    ),
                  ),
                  itemBuilder: (context, i) {
                    final entry = stack.entries[i];
                    return Center(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () {
                          final jumped = stack.jumpTo(i);
                          if (jumped != null) onJumpTo(jumped);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.primaryContainer.withAlpha(120),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _iconForReason(entry.reason),
                                size: 12,
                                color: _colorForReason(entry.reason),
                              ),
                              const SizedBox(width: 4),
                              Text(
                                entry.label,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: stack.clear,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: const Icon(
                    Icons.close,
                    size: 14,
                    color: AppColors.onSurfaceMuted,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  static IconData _iconForReason(String reason) {
    switch (reason) {
      case 'trap':
        return Icons.bolt;
      case 'hard_move':
        return Icons.warning_amber_rounded;
      case 'suggestion':
        return Icons.lightbulb_outline;
      default:
        return Icons.place;
    }
  }

  static Color _colorForReason(String reason) {
    switch (reason) {
      case 'trap':
        return AppColors.warning;
      case 'hard_move':
        return AppColors.danger;
      case 'suggestion':
        return AppColors.success;
      default:
        return AppColors.info;
    }
  }
}
