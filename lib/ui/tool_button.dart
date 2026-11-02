import 'package:flutter/material.dart';

import 'theme.dart';

/// An icon-only button in a bar or a list header: the symbol at the action
/// size, a compact square, and always a tooltip saying what it does.
///
/// With [selected] it is a toggle, drawn in the slate accent while it is on
/// (with [selectedIcon], the filled variant, when the symbol has one).
class ToolButton extends StatelessWidget {
  const ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected,
    this.selectedIcon,
    this.size = IconSize.action,
  });

  final IconData icon;
  final String tooltip;

  /// Null shows the button off.
  final VoidCallback? onPressed;

  /// Whether the toggle is on; null for a plain button.
  final bool? selected;
  final IconData? selectedIcon;

  /// The symbol's size: [IconSize.menu] for a button inside a row, beside
  /// the row's own text.
  final double size;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: Icon(icon, size: size),
    selectedIcon: selectedIcon == null ? null : Icon(selectedIcon, size: size),
    isSelected: selected,
    tooltip: tooltip,
    onPressed: onPressed,
    visualDensity: VisualDensity.compact,
  );
}
