import 'package:flutter/material.dart';

import '../ui/app_action.dart';
import '../ui/choice_dialog.dart';
import '../ui/action_context_menu.dart';
import '../ui/theme.dart';
import 'mode.dart';
import '../ui/app_keys.dart';

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
    this.activity,
    this.onActivity,
  });

  final Mode mode;
  final String? activity;
  final VoidCallback? onActivity;
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
          IconButton(
            icon: const Icon(Icons.arrow_back, size: IconSize.action),
            tooltip: AppKey.historyBack.tip(
              backTo == null ? 'Back' : 'Back to $backTo',
            ),
            onPressed: backTo == null ? null : onBack,
            visualDensity: VisualDensity.compact,
          ),
          IconButton(
            icon: const Icon(Icons.arrow_forward, size: IconSize.action),
            tooltip: AppKey.historyForward.tip(
              forwardTo == null ? 'Forward' : 'Forward to $forwardTo',
            ),
            onPressed: forwardTo == null ? null : onForward,
            visualDensity: VisualDensity.compact,
          ),
          _ModeMenu(mode: mode, onMode: onMode, offered: offered),
          const SizedBox(width: Space.s),
          _ActionsMenu(actions: actions, changes: actionsChange),
          const Spacer(),
          if (activity != null)
            Flexible(
              child: TextButton(
                onPressed: onActivity,
                child: Text(
                  '$activity · running',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: IconSize.action),
            tooltip: AppKey.settings.tip('Settings'),
            onPressed: onSettings,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

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

  Future<void> _find(BuildContext context) async {
    final chosen = await showChoiceDialog<Mode>(
      context,
      title: 'Find a mode',
      options: Mode.values.where(offered).toList(),
      label: (mode) => mode.label,
      hint: 'Type a mode name',
      empty: 'No modes available',
    );
    if (context.mounted && chosen != null) onMode(chosen);
  }

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        MenuItemButton(
          onPressed: () => _find(context),
          child: const Text('Find a mode…'),
        ),
        for (final group in modeGroups.entries) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(Space.s),
            child: Text(
              group.key,
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          for (final named in group.value)
            if (offered(named))
              MenuItemButton(
                onPressed: () => onMode(named),
                leadingIcon: named == mode
                    ? const Icon(Icons.check, size: IconSize.menu)
                    : const SizedBox(width: IconSize.menu),
                child: Text(named.label),
              ),
        ],
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
    Widget entry(AppAction action) => GestureDetector(
      onSecondaryTapUp: action.alternatives.isEmpty
          ? null
          : (details) => showActionContextMenu(
              context,
              details.globalPosition,
              action.alternatives,
            ),
      child: MenuItemButton(
        onPressed: action.run,
        leadingIcon: action.icon == null
            ? null
            : Icon(action.icon, size: IconSize.menu),
        trailingIcon: action.shortcut == null
            ? null
            : Text(action.shortcut!, style: text.labelSmall),
        child: Text(action.label),
      ),
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
    'Copy': Icons.content_copy,
    'Panels': Icons.tab_outlined,
    'Action Tabs': Icons.tab,
    'Layout': Icons.grid_view,
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
        message: AppKey.actions.tip('Actions'),
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
    tooltip: AppKey.toggleList.tip(shown ? 'Hide the list' : 'Show the list'),
    onPressed: onPressed,
    visualDensity: VisualDensity.compact,
  );
}
