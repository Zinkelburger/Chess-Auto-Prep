import 'package:flutter/material.dart';

import '../ui/app_action.dart';
import '../ui/theme.dart';
import 'shell.dart';

/// The row over the window: the list pane's toggle, the mode menu, and on
/// the right the Actions menu — one menu of everything that can be done
/// now, the same shape in every mode.
class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.mode,
    required this.onMode,
    required this.listShown,
    required this.onToggleList,
    required this.actions,
  });

  final Mode mode;
  final ValueChanged<Mode> onMode;
  final bool listShown;
  final VoidCallback onToggleList;
  final List<AppAction> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.s,
        vertical: Space.xs,
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              listShown
                  ? Icons.keyboard_double_arrow_left
                  : Icons.keyboard_double_arrow_right,
              size: IconSize.action,
            ),
            tooltip: listShown
                ? 'Hide the list (Ctrl+B)'
                : 'Show the list (Ctrl+B)',
            onPressed: onToggleList,
            visualDensity: VisualDensity.compact,
          ),
          _ModeMenu(mode: mode, onMode: onMode),
          const Spacer(),
          _ActionsMenu(actions: actions),
        ],
      ),
    );
  }
}

/// Modes not yet in v2 are listed but disabled, so the menu shows the whole
/// product from day one and each step turns one entry on.
const _modes = [
  'Repertoires',
  'PGN Viewer',
  'Repertoire builder',
  'Repertoire trainer',
  'Study',
  'Tactics',
  'Player analysis',
  'Players & prep',
  'Databases',
  'Engine tournament',
  'Bughouse lab',
];

class _ModeMenu extends StatelessWidget {
  const _ModeMenu({required this.mode, required this.onMode});

  final Mode mode;
  final ValueChanged<Mode> onMode;

  /// The mode this entry switches to, or null when `v2` does not have it yet
  /// and the entry is there only to show that the product does.
  Mode? _modeNamed(String name) =>
      Mode.values.where((mode) => mode.label == name).firstOrNull;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final name in _modes)
          MenuItemButton(
            onPressed: switch (_modeNamed(name)) {
              null => null,
              final named => () => onMode(named),
            },
            leadingIcon: name == mode.label
                ? const Icon(Icons.check, size: IconSize.menu)
                : const SizedBox(width: IconSize.menu),
            child: Text(name),
          ),
      ],
      builder: (context, controller, _) => TextButton.icon(
        onPressed: controller.isOpen ? controller.close : controller.open,
        icon: const Icon(Icons.menu, size: IconSize.action),
        label: Text(mode.label),
      ),
    );
  }
}

/// Every action by name with its key after it, grouped by a thin line.
/// Ctrl+K opens the same list as something to type into.
class _ActionsMenu extends StatelessWidget {
  const _ActionsMenu({required this.actions});

  final List<AppAction> actions;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final children = <Widget>[];
    String? group;
    for (final action in actions) {
      if (action.group != group && children.isNotEmpty) {
        children.add(const Divider(height: 1));
      }
      group = action.group;
      children.add(
        MenuItemButton(
          onPressed: action.run,
          trailingIcon: action.shortcut == null
              ? null
              : Text(action.shortcut!, style: text.labelSmall),
          child: Text(action.label),
        ),
      );
    }
    return MenuAnchor(
      menuChildren: children,
      builder: (context, controller, _) => TextButton.icon(
        onPressed: controller.isOpen ? controller.close : controller.open,
        icon: const Icon(Icons.arrow_drop_down, size: IconSize.action),
        iconAlignment: IconAlignment.end,
        label: const Text('Actions'),
      ),
    );
  }
}
