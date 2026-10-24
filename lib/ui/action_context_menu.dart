import 'package:flutter/material.dart';

import 'app_action.dart';
import 'theme.dart';

/// The same destinations are available on tab labels and tool menu entries.
///
/// The menu appears at once, as the menus opened from the top bar do: no
/// fade or grow. Rows look like those menus' rows, each action's symbol in
/// a fixed slot before its label so the labels line up.
Future<void> showActionContextMenu(
  BuildContext context,
  Offset position,
  List<AppAction> actions,
) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final local = overlay.globalToLocal(position);
  final theme = Theme.of(context);
  final iconed = actions.any((action) => action.icon != null);
  final action = await showMenu<VoidCallback>(
    context: context,
    position: RelativeRect.fromSize(local & Size.zero, overlay.size),
    popUpAnimationStyle: AnimationStyle.noAnimation,
    items: [
      for (final action in actions)
        PopupMenuItem(
          value: action.run,
          enabled: action.run != null,
          height: menuRowHeight,
          padding: const EdgeInsets.symmetric(horizontal: Space.l),
          child: Row(
            children: [
              if (iconed) ...[
                SizedBox.square(
                  dimension: IconSize.menu,
                  child: action.icon == null
                      ? null
                      : Icon(
                          action.icon,
                          size: IconSize.menu,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                ),
                const SizedBox(width: Space.m),
              ],
              Flexible(child: Text(action.label)),
            ],
          ),
        ),
    ],
  );
  if (context.mounted) action?.call();
}
