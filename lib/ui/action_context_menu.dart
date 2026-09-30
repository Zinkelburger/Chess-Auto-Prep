import 'package:flutter/material.dart';

import 'app_action.dart';

/// The same destinations are available on tab labels and tool menu entries.
Future<void> showActionContextMenu(
  BuildContext context,
  Offset position,
  List<AppAction> actions,
) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final local = overlay.globalToLocal(position);
  final action = await showMenu<VoidCallback>(
    context: context,
    position: RelativeRect.fromSize(local & Size.zero, overlay.size),
    items: [
      for (final action in actions)
        PopupMenuItem(
          value: action.run,
          enabled: action.run != null,
          child: Text(action.label),
        ),
    ],
  );
  if (context.mounted) action?.call();
}
