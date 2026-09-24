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
    this.backTo,
    this.forwardTo,
    this.onBack,
    this.onForward,
    required this.offered,
    required this.onSettings,
    required this.listShown,
    required this.onToggleList,
    required this.actions,
    required this.actionsChange,
  });

  final Mode mode;
  final ValueChanged<Mode> onMode;

  /// Where Back and Forward go. Empty history disables the controls while
  /// keeping their places in the toolbar.
  final String? backTo;
  final String? forwardTo;
  final VoidCallback? onBack;
  final VoidCallback? onForward;

  /// Whether this build can offer [Mode] at all: the Bughouse lab needs its
  /// engine, which a build may not carry. A mode not offered is left out
  /// of the menu, not greyed.
  final bool Function(Mode mode) offered;
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
          _ModeMenu(mode: mode, onMode: onMode, offered: offered),
          const SizedBox(width: Space.s),
          _ActionsMenu(actions: actions, changes: actionsChange),
          const SizedBox(width: Space.s),
          IconButton(
            icon: const Icon(Icons.arrow_back, size: IconSize.action),
            tooltip: withKey(
              backTo == null ? 'Back' : 'Back to $backTo',
              'Alt+←',
            ),
            onPressed: backTo == null ? null : onBack,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward, size: IconSize.action),
            tooltip: withKey(
              forwardTo == null ? 'Forward' : 'Forward to $forwardTo',
              'Alt+→',
            ),
            onPressed: forwardTo == null ? null : onForward,
            visualDensity: VisualDensity.compact,
          ),
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
  'Books',
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
  const _ModeMenu({
    required this.mode,
    required this.onMode,
    required this.offered,
  });

  final Mode mode;
  final ValueChanged<Mode> onMode;
  final bool Function(Mode mode) offered;

  /// The mode this entry switches to, or null when `v2` does not have it yet
  /// and the entry is there only to show that the product does.
  Mode? _modeNamed(String name) =>
      Mode.values.where((mode) => mode.label == name).firstOrNull;

  /// Every entry is listed — `v2`'s modes and the ones still to come — but
  /// a mode this build cannot offer.
  bool _listed(String name) => switch (_modeNamed(name)) {
    null => true,
    final named => offered(named),
  };

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        for (final name in _modes)
          if (_listed(name))
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

/// Named sections for the work and submenus for secondary controls.
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
    if (!mounted || _heard != null) return;
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
    // Gather by name, including non-adjacent contributions from the mode
    // and document. Each section is shown once.
    final groups = <String, List<AppAction>>{};
    for (final action in widget.actions()) {
      (groups[action.group ?? 'Actions'] ??= []).add(action);
    }
    Widget entry(AppAction action) => MenuItemButton(
      onPressed: action.run,
      trailingIcon: action.shortcut == null
          ? null
          : Text(action.shortcut!, style: text.labelSmall),
      child: Text(action.label),
    );

    final children = <Widget>[];
    for (final group in groups.entries.where(
      (group) => !_secondary.containsKey(group.key),
    )) {
      if (children.isNotEmpty)
        children.add(
          const Divider(height: 1, indent: Space.l, endIndent: Space.l),
        );
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.l,
            Space.s,
            Space.l,
            Space.xs,
          ),
          child: Text(group.key, style: text.labelSmall),
        ),
      );
      children.addAll(group.value.map(entry));
    }
    final secondary = groups.entries.where(
      (group) => _secondary.containsKey(group.key),
    );
    if (secondary.isNotEmpty && children.isNotEmpty) {
      children.add(
        const Divider(height: 1, indent: Space.l, endIndent: Space.l),
      );
    }
    for (final group in secondary) {
      children.add(
        SubmenuButton(
          leadingIcon: Icon(_secondary[group.key], size: IconSize.menu),
          menuChildren: group.value.map(entry).toList(),
          child: Text(group.key),
        ),
      );
    }
    return children;
  }

  /// Keep the document's work in view; secondary controls expand beside it.
  static const _secondary = {
    'Analysis board': Icons.analytics_outlined,
    'Board': Icons.grid_view_outlined,
    'Copy': Icons.content_copy,
    'Panels': Icons.view_sidebar_outlined,
    'Window': Icons.fullscreen,
  };

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      onOpen: _opened,
      onClose: _closed,
      menuChildren: _heard == null
          ? const []
          : _entries(Theme.of(context).textTheme),
      // Ctrl+K opens the same actions as a list to type into.
      builder: (context, controller, _) => Tooltip(
        message: withKey('Actions', 'Ctrl+K'),
        child: TextButton.icon(
          onPressed: controller.isOpen ? controller.close : controller.open,
          icon: const Icon(Icons.arrow_drop_down, size: IconSize.action),
          iconAlignment: IconAlignment.end,
          label: const Text('Actions'),
        ),
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
