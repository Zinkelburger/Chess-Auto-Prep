import 'package:flutter/material.dart';

import 'theme.dart';

/// The `⋯` menu on a row of a list: everything that can be done to that one
/// thing, out of the way until it is wanted.
///
/// One shape for every list in the app — the repertoire list, the chapter
/// outline, the study list — so a row's actions are always in the same place
/// and look the same.
class RowActions extends StatelessWidget {
  const RowActions({
    super.key,
    required this.children,
    this.tooltip = 'Actions',
  });

  /// The menu's items, usually `MenuItemButton`s.
  final List<Widget> children;

  /// What the button says it opens, for a list whose rows are not the only
  /// things on the panel.
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: children,
      builder: (context, controller, _) => IconButton(
        icon: const Icon(Icons.more_horiz, size: IconSize.action),
        tooltip: tooltip,
        onPressed: controller.isOpen ? controller.close : controller.open,
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}

/// A menu entry, off while a change to the catalog is in flight: two catalog
/// writes at once is how a half-applied change happens.
MenuItemButton rowAction(
  String label,
  VoidCallback run, {
  required bool busy,
}) => MenuItemButton(onPressed: busy ? null : run, child: Text(label));
