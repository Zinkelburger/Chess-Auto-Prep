import 'package:flutter/material.dart';

import '../ui/app_action.dart';
import '../ui/theme.dart';
import 'mode.dart';

/// The row over the window: the mode menu and, beside it, the Actions menu
/// — one menu of everything that can be done now, the same shape in every
/// mode. Both sit at the left, where the pointer already is; the settings
/// gear sits alone at the right end, where the old app kept it (owner,
/// 2026-09-22), and the rest of the row is empty. While the list pane is
/// hidden, the `»` that brings it back sits before the menus, where the
/// pane would be; shown, the pane carries its own `«` in its top right
/// corner, so the toggle is always at the pane's edge.
class TopBar extends StatelessWidget {
  const TopBar({
    super.key,
    required this.mode,
    required this.onMode,
    required this.onSettings,
    required this.listShown,
    required this.onToggleList,
    required this.actions,
    required this.actionsChange,
  });

  final Mode mode;
  final ValueChanged<Mode> onMode;
  final VoidCallback onSettings;
  final bool listShown;
  final VoidCallback onToggleList;

  /// Everything the Actions menu offers, asked each time it opens rather
  /// than each time something it reads changes: the engine alone would ask
  /// five times a second.
  final List<AppAction> Function() actions;

  /// Notifies when what [actions] reads changes, so an open menu keeps up.
  final Listenable actionsChange;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.s,
        vertical: Space.xs,
      ),
      child: Row(
        children: [
          if (!listShown) ListToggle(shown: false, onPressed: onToggleList),
          _ModeMenu(mode: mode, onMode: onMode),
          const SizedBox(width: Space.s),
          _ActionsMenu(actions: actions, changes: actionsChange),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: IconSize.action),
            tooltip: withKey('Settings', 'Ctrl+,'),
            onPressed: onSettings,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// Modes not yet in v2 are listed but disabled, so the menu shows the whole
/// product from day one and each step turns one entry on. The library and
/// the builder are one mode, named for the building (owner, 2026-09-22).
const _modes = [
  'Repertoire builder',
  'PGN Viewer',
  'Repertoire trainer',
  'Study',
  'Tactics',
  'My games',
  'Player analysis',
  'Players & prep',
  'Databases',
  'Engine tournament',
  'Bughouse lab',
];

/// The modes, and nothing else: the settings are the gear at the other end
/// of the row.
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
/// Ctrl+K opens the same list as something to type into. The entries are
/// made when the menu opens and kept up to date only while it is open.
class _ActionsMenu extends StatefulWidget {
  const _ActionsMenu({required this.actions, required this.changes});

  final List<AppAction> Function() actions;
  final Listenable changes;

  @override
  State<_ActionsMenu> createState() => _ActionsMenuState();
}

class _ActionsMenuState extends State<_ActionsMenu> {
  /// What the menu is listening to while it is open; null while shut.
  Listenable? _heard;

  @override
  void didUpdateWidget(_ActionsMenu old) {
    super.didUpdateWidget(old);
    final heard = _heard;
    if (heard == null || heard == widget.changes) return;
    heard.removeListener(_changed);
    _heard = widget.changes..addListener(_changed);
  }

  @override
  void dispose() {
    _heard?.removeListener(_changed);
    super.dispose();
  }

  void _opened() {
    if (_heard != null) return;
    _heard = widget.changes..addListener(_changed);
    setState(() {});
  }

  void _closed() {
    _heard?.removeListener(_changed);
    _heard = null;
    if (mounted) setState(() {});
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  List<Widget> _entries(TextTheme text) {
    final children = <Widget>[];
    String? group;
    for (final action in widget.actions()) {
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
    return children;
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      onOpen: _opened,
      onClose: _closed,
      menuChildren: _heard == null
          ? const []
          : _entries(Theme.of(context).textTheme),
      builder: (context, controller, _) => TextButton.icon(
        onPressed: controller.isOpen ? controller.close : controller.open,
        icon: const Icon(Icons.arrow_drop_down, size: IconSize.action),
        iconAlignment: IconAlignment.end,
        label: const Text('Actions'),
      ),
    );
  }
}

/// The button that hides or shows the list pane: `«` in the pane's corner
/// while it is shown, `»` in the top bar while it is not.
class ListToggle extends StatelessWidget {
  const ListToggle({super.key, required this.shown, required this.onPressed});

  final bool shown;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: Icon(
      shown
          ? Icons.keyboard_double_arrow_left
          : Icons.keyboard_double_arrow_right,
      size: IconSize.action,
    ),
    tooltip: withKey(shown ? 'Hide the list' : 'Show the list', 'Ctrl+B'),
    onPressed: onPressed,
    visualDensity: VisualDensity.compact,
  );
}
