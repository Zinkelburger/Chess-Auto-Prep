import 'package:flutter/material.dart';

import 'theme.dart';

/// The `⋯` menu on a list row.
///
/// One shape for every list in the app: the repertoire list and the study
/// list both hang their row operations here, so a row's actions are always
/// in the same place and look the same.
class RowActions extends StatelessWidget {
  const RowActions({
    super.key,
    required this.children,
    this.tooltip = 'Actions',
  });

  final List<Widget> children;

  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: children,
      builder: (context, controller, _) => IconButton(
        icon: const Icon(Icons.more_horiz, size: IconSize.action),
        tooltip: tooltip,
        onPressed: controller.isOpen ? controller.close : controller.open,
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
