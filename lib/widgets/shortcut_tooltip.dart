import 'package:flutter/material.dart';

/// Single-key shortcuts shared across screens (tooltip text must match handlers).
abstract final class AppShortcuts {
  /// Tactics: toggle auto-advance after solve. Training: toggle learn auto-advance.
  static const autoAdvanceToggle = 'J';
}

/// Builds a hover tooltip for an action backed by a keyboard shortcut.
///
/// Format: `Description (Shortcut)` — use this (or [ShortcutTooltip] /
/// [ShortcutIconButton]) for every control that has a shortcut handler.
String actionTooltip(String description, {required String shortcut}) {
  final d = description.trim();
  final s = shortcut.trim();
  if (s.isEmpty) return d;
  return '$d ($s)';
}

/// Like [actionTooltip], but omits the shortcut suffix when [shortcut] is null/empty.
String actionTooltipIf(String description, {String? shortcut}) {
  final s = shortcut?.trim();
  if (s == null || s.isEmpty) return description.trim();
  return actionTooltip(description, shortcut: s);
}

/// Tooltip that always includes a keyboard shortcut on hover.
///
/// Set [preferDelayed] for dense control clusters (e.g. tactics training buttons)
/// so each hover waits [waitDuration] (default 500ms) before showing the tooltip.
class ShortcutTooltip extends StatelessWidget {
  const ShortcutTooltip({
    super.key,
    required this.description,
    required this.shortcut,
    required this.child,
    this.waitDuration,
    this.preferDelayed = false,
  });

  final String description;
  final String shortcut;
  final Widget child;
  final Duration? waitDuration;
  final bool preferDelayed;

  String get message => actionTooltip(description, shortcut: shortcut);

  @override
  Widget build(BuildContext context) {
    assert(
      shortcut.trim().isNotEmpty,
      'ShortcutTooltip requires a non-empty shortcut',
    );
    if (preferDelayed || waitDuration != null) {
      return Tooltip(
        message: message,
        waitDuration: waitDuration ?? const Duration(milliseconds: 500),
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
  final String shortcut;
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
    assert(
      shortcut.trim().isNotEmpty,
      'ShortcutIconButton requires a non-empty shortcut',
    );
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

/// Convenience wrapper with a short hover delay (tactics training panel).
Widget shortcutTooltip({
  required String description,
  required String shortcut,
  required Widget child,
}) {
  return ShortcutTooltip(
    description: description,
    shortcut: shortcut,
    preferDelayed: true,
    child: child,
  );
}
