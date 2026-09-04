/// Shared Previous/Next stepping for the app's ranked lists (weak positions,
/// hole/trick findings). One controller shape and one header row so every
/// list answers to the same keys — the app-wide convention is **←/→ move
/// through a game, [AppShortcut.previousItem]/[AppShortcut.nextItem] step
/// whatever queue is in front of you**. That pair is ↑/↓; the labels
/// on the buttons come from the registry, so they cannot drift from the keys
/// the screens actually bind.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/app_text_styles.dart';
import '../../utils/app_shortcuts.dart';
import '../shortcut_tooltip.dart';

/// A list whose selection can be stepped from outside.
abstract interface class ListNavTarget {
  void stepNext();
  void stepPrevious();
}

/// Forwards the host screen's previous/next shortcuts to whichever list is
/// attached.
/// The screen's Focus owns all key events, so a Focus inside the list would
/// never see them — same attach pattern as `PgnViewerWidgetController`.
class ListNavController {
  ListNavTarget? _target;

  void attach(ListNavTarget target) => _target = target;

  void detach(ListNavTarget target) {
    if (identical(_target, target)) _target = null;
  }

  void selectNext() => _target?.stepNext();

  void selectPrevious() => _target?.stepPrevious();
}

/// The Prev/Next header row: two compact buttons (game-nav-bar styling) and
/// an optional trailing counter ("3 of 41"). Buttons disable at the ends of
/// the list; pass null [counterText] when a status row nearby already shows
/// the count.
class ListNavRow extends StatelessWidget {
  const ListNavRow({
    super.key,
    required this.itemLabel,
    required this.canPrevious,
    required this.canNext,
    required this.onPrevious,
    required this.onNext,
    this.counterText,
  });

  /// What a row is, for the tooltips: "position", "finding".
  final String itemLabel;

  final bool canPrevious;
  final bool canNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final String? counterText;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Row(
        children: [
          _button(
            description: 'Previous $itemLabel',
            shortcut: AppShortcut.previousItem,
            icon: Icons.skip_previous,
            label: 'Prev',
            onPressed: canPrevious ? onPrevious : null,
          ),
          const SizedBox(width: 4),
          _button(
            description: 'Next $itemLabel',
            shortcut: AppShortcut.nextItem,
            icon: Icons.skip_next,
            label: 'Next',
            onPressed: canNext ? onNext : null,
          ),
          const Spacer(),
          if (counterText != null)
            Flexible(
              child: Text(
                counterText!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTextStyles.caption,
              ),
            ),
        ],
      ),
    );
  }

  Widget _button({
    required String description,
    required AppShortcut shortcut,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return ShortcutTooltip(
      description: description,
      shortcut: shortcut,
      child: TextButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }
}

/// Scroll a fixed-extent list row into view after a keyboard/button step.
/// Tap selection never calls this — only stepping, where the next row may
/// sit off-screen.
void ensureRowVisible(
  ScrollController controller,
  int index,
  double itemExtent,
) {
  if (!controller.hasClients) return;
  final rowTop = index * itemExtent;
  final viewTop = controller.offset;
  final viewHeight = controller.position.viewportDimension;
  double? target;
  if (rowTop < viewTop) {
    target = rowTop;
  } else if (rowTop + itemExtent > viewTop + viewHeight) {
    target = rowTop + itemExtent - viewHeight;
  }
  if (target != null) {
    unawaited(
      controller.animateTo(
        target,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      ),
    );
  }
}
