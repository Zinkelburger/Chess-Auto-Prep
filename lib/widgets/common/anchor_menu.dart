/// Context menu anchored at a pointer position, with no open/close animation.
library;

import 'package:flutter/material.dart';

/// Shows a [PopupMenu] at [position] (typically a right-click or long-press
/// global offset). Shared by findings/report panels so dismiss menus stay
/// visually identical.
Future<T?> showAnchorMenu<T>({
  required BuildContext context,
  required Offset position,
  required List<PopupMenuEntry<T>> items,
}) {
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx + 1,
      position.dy + 1,
    ),
    popUpAnimationStyle: AnimationStyle.noAnimation,
    items: items,
  );
}
