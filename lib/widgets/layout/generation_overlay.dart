/// Generation modal overlay for Edit mode context zone (B4 Phase 4).
///
/// Keeps [generationContent] mounted via [Offstage] so builds can continue
/// while the panel is hidden. The underlying [child] zone stays in the tree
/// so wide-layout PGN remains readable beside the overlay column.
library;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Stacks [generationContent] over [child] when [visible].
class GenerationOverlay extends StatelessWidget {
  const GenerationOverlay({
    super.key,
    required this.visible,
    required this.onClose,
    required this.generationContent,
    required this.child,
    this.isGenerating = false,
  });

  final bool visible;
  final VoidCallback onClose;
  final Widget generationContent;
  final Widget child;
  final bool isGenerating;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Offstage(
          offstage: !visible,
          child: _GenerationOverlayPanel(
            onClose: onClose,
            isGenerating: isGenerating,
            child: generationContent,
          ),
        ),
      ],
    );
  }
}

class _GenerationOverlayPanel extends StatelessWidget {
  const _GenerationOverlayPanel({
    required this.onClose,
    required this.isGenerating,
    required this.child,
  });

  final VoidCallback onClose;
  final bool isGenerating;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 12,
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: theme.dividerColor),
              ),
              color: isGenerating
                  ? AppColors.warningSurface.withValues(alpha: 0.12)
                  : null,
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Generate Repertoire',
                            style: theme.textTheme.titleSmall,
                          ),
                          if (isGenerating)
                            Text(
                              'Build continues in the background when closed',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close (G to reopen)',
                      onPressed: onClose,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}
