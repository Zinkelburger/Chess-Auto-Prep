import 'package:flutter/material.dart';

import 'action_context_menu.dart';
import 'app_action.dart';
import 'theme.dart';

/// One row of a menu: the top bar's Actions, a row's `⋯`, a pane's `+`.
///
/// Every menu in the app is built from these so its rows look the same: the
/// symbol in muted ink in a 16px slot before the label, the key at the end.
/// [alignMenu] gives the rows without a symbol an empty slot once any row of
/// the menu has one, so the labels line up.
class MenuEntry extends StatelessWidget {
  const MenuEntry(
    this.label,
    this.run, {
    super.key,
    this.icon,
    this.shortcut,
    this.alternatives = const [],
    this.slot = false,
  });

  /// The row for [action], with its symbol, key and right-click places.
  MenuEntry.action(AppAction action, {super.key, this.slot = false})
    : label = action.label,
      run = action.run,
      icon = action.icon,
      shortcut = action.shortcut,
      alternatives = action.alternatives;

  final String label;

  /// Null shows the row off: there is nothing for it to act on now.
  final VoidCallback? run;
  final IconData? icon;

  /// The key that does the same, in a tooltip's words (`Ctrl+S`).
  final String? shortcut;

  /// Where else the same thing can open, offered on a right click.
  final List<AppAction> alternatives;

  /// Hold the symbol's place even without one, so labels line up.
  final bool slot;

  MenuEntry _slotted() => slot
      ? this
      : MenuEntry(
          label,
          run,
          key: key,
          icon: icon,
          shortcut: shortcut,
          alternatives: alternatives,
          slot: true,
        );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = MenuItemButton(
      onPressed: run,
      leadingIcon: icon != null
          ? Icon(
              icon,
              size: IconSize.menu,
              color: run == null ? null : theme.colorScheme.onSurfaceVariant,
            )
          : slot
          ? const SizedBox.square(dimension: IconSize.menu)
          : null,
      trailingIcon: shortcut == null
          ? null
          : Text(shortcut!, style: theme.textTheme.labelSmall),
      child: Text(label),
    );
    if (alternatives.isEmpty) return entry;
    return GestureDetector(
      onSecondaryTapUp: (details) =>
          showActionContextMenu(context, details.globalPosition, alternatives),
      child: entry,
    );
  }
}

/// [entries] with a symbol slot on every [MenuEntry] once any row of the
/// menu has a symbol; the other widgets (dividers, headings, submenus) as
/// they are.
List<Widget> alignMenu(List<Widget> entries) {
  final iconed = entries.any(
    (entry) =>
        (entry is MenuEntry && entry.icon != null) ||
        (entry is SubmenuButton && entry.leadingIcon != null),
  );
  if (!iconed) return entries;
  return [
    for (final entry in entries)
      if (entry is MenuEntry) entry._slotted() else entry,
  ];
}

/// The rows for [actions], aligned.
List<Widget> menuEntries(Iterable<AppAction> actions) =>
    alignMenu([for (final action in actions) MenuEntry.action(action)]);
