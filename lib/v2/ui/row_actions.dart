import 'package:flutter/material.dart';

import 'theme.dart';

/// The `⋯` menu on a row of a list: everything that can be done to that one
/// thing, out of the way until it is wanted.
class RowActions extends StatelessWidget {
  const RowActions({super.key, required this.children});

  /// The menu's items, usually `MenuItemButton`s.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: children,
      builder: (context, controller, _) => IconButton(
        icon: const Icon(Icons.more_horiz, size: IconSize.action),
        tooltip: 'Actions',
        onPressed: controller.isOpen ? controller.close : controller.open,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
