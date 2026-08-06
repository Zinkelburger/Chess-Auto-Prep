import 'package:flutter/material.dart';

import '../utils/app_shortcuts.dart';

/// Builds a hover tooltip for an action backed by a keyboard shortcut.
///
/// Format: `Description (Shortcut)`. The shortcut is always an [AppShortcut]
/// registry entry rather than a typed-out string — that is what stops a
/// tooltip from advertising a key the screen no longer binds. Use this (or
/// [ShortcutTooltip] / [ShortcutIconButton]) for every control that has a
/// shortcut handler.
String actionTooltip(String description, {required AppShortcut shortcut}) =>
    '${description.trim()} (${shortcut.label})';

/// Like [actionTooltip], but omits the suffix when there is no shortcut.
String actionTooltipIf(String description, {AppShortcut? shortcut}) =>
    shortcut == null
    ? description.trim()
    : actionTooltip(description, shortcut: shortcut);

/// Tooltip that always includes a keyboard shortcut on hover.
class ShortcutTooltip extends StatelessWidget {
  const ShortcutTooltip({
    super.key,
    required this.description,
    required this.shortcut,
    required this.child,
    this.waitDuration,
  });

  final String description;
  final AppShortcut shortcut;
  final Widget child;
  final Duration? waitDuration;

  String get message => actionTooltip(description, shortcut: shortcut);

  @override
  Widget build(BuildContext context) {
    if (waitDuration != null) {
      return Tooltip(
        message: message,
        waitDuration: waitDuration,
        child: child,
      );
    }
    return Tooltip(message: message, child: child);
  }
}

/// [IconButton] that requires an associated keyboard shortcut in its tooltip.
class ShortcutIconButton extends StatelessWidget {
  const ShortcutIconButton({
    super.key,
    required this.description,
    required this.shortcut,
    required this.onPressed,
    required this.icon,
    this.autofocus,
    this.color,
    this.disabledColor,
    this.focusColor,
    this.highlightColor,
    this.hoverColor,
    this.splashColor,
    this.splashRadius,
    this.iconSize,
    this.padding,
    this.alignment,
    this.constraints,
    this.style,
    this.isSelected,
    this.selectedIcon,
    this.visualDensity,
  });

  final String description;
  final AppShortcut shortcut;
  final VoidCallback? onPressed;
  final Widget icon;
  final bool? autofocus;
  final Color? color;
  final Color? disabledColor;
  final Color? focusColor;
  final Color? highlightColor;
  final Color? hoverColor;
  final Color? splashColor;
  final double? splashRadius;
  final double? iconSize;
  final EdgeInsetsGeometry? padding;
  final AlignmentGeometry? alignment;
  final BoxConstraints? constraints;
  final ButtonStyle? style;
  final bool? isSelected;
  final Widget? selectedIcon;
  final VisualDensity? visualDensity;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: actionTooltip(description, shortcut: shortcut),
      onPressed: onPressed,
      icon: icon,
      autofocus: autofocus ?? false,
      color: color,
      disabledColor: disabledColor,
      focusColor: focusColor,
      highlightColor: highlightColor,
      hoverColor: hoverColor,
      splashColor: splashColor,
      splashRadius: splashRadius,
      iconSize: iconSize,
      padding: padding,
      alignment: alignment,
      constraints: constraints,
      style: style,
      isSelected: isSelected,
      selectedIcon: selectedIcon,
      visualDensity: visualDensity,
    );
  }
}

/// Convenience wrapper matching [ShortcutTooltip] defaults (no delay).
Widget shortcutTooltip({
  required String description,
  required AppShortcut shortcut,
  required Widget child,
}) {
  return ShortcutTooltip(
    description: description,
    shortcut: shortcut,
    child: child,
  );
}
