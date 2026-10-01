import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/action_context_menu.dart';
import '../ui/app_action.dart';
import '../ui/pane_tabs.dart';
import '../ui/theme.dart';
import 'action_layout.dart';
import 'workspace_tabs.dart';

/// Docking affordances appear during a drag, leaving the reading area quiet.
class ActionPanes extends StatefulWidget {
  const ActionPanes({
    super.key,
    required this.layout,
    required this.body,
    this.actions,
  });
  final ActionLayout layout;
  final Widget Function(BuildContext, int, WorkspaceTab) body;

  /// What the mode puts in every pane's `+` under its tabs: the things it
  /// keeps out of sight until they are asked for.
  final List<AppAction> Function()? actions;

  @override
  State<ActionPanes> createState() => _ActionPanesState();
}

class _ActionPanesState extends State<ActionPanes> {
  PaneTabDrag<WorkspaceTab>? _drag;
  ActionLayout get layout => widget.layout;

  void _dragChanged(PaneTabDrag<WorkspaceTab>? drag) {
    if (!mounted) return;
    setState(() => _drag = drag);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: layout,
    builder: (context, _) => _grid(layout.root),
  );

  Widget _grid(ActionPaneNode node) => switch (node) {
    ActionPaneLeaf() => _pane(context, node.index),
    ActionPaneSplit() => Flex(
      direction: node.direction == PaneSplitDirection.right
          ? Axis.horizontal
          : Axis.vertical,
      children: [
        Expanded(child: _grid(node.first)),
        Expanded(child: _grid(node.second)),
      ],
    ),
  };

  /// Moves alone on the card is the page of a book: no strip and no frame,
  /// the `+` in its corner.
  bool get _page =>
      layout.count == 1 &&
      layout.openIn(0).length == 1 &&
      layout.openIn(0).single == WorkspaceTab.moves;

  Widget _pane(BuildContext context, int index) {
    final tabs = layout.pane(index);
    final scheme = Theme.of(context).colorScheme;
    final drag = _drag;
    if (_page) {
      return Stack(
        key: ValueKey('action-pane-$index'),
        fit: StackFit.expand,
        children: [
          _body(context, index, tabs.selected),
          Positioned(top: Space.xs, right: Space.xs, child: _paneMenu(index)),
        ],
      );
    }
    return Listener(
      onPointerDown: (_) => layout.select(index),
      child: Focus(
        onFocusChange: (focused) {
          if (mounted && focused) layout.select(index);
        },
        // A Material, not a decorated box: list rows in the tabs paint
        // their hover and ink on the nearest Material, which must be this
        // pane's surface rather than something beneath it.
        child: Padding(
          padding: const EdgeInsets.all(Space.xs),
          child: Material(
            key: ValueKey('action-pane-$index'),
            color: scheme.surface,
            shape: RoundedRectangleBorder(
              side: BorderSide(
                color: layout.active == index && layout.count > 1
                    ? scheme.onSurfaceVariant.withValues(alpha: 0.55)
                    : scheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(paneTabRadius),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _paneHeader(context, index),
                const Divider(height: 1),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (!layout.isEmpty(index))
                        _body(context, index, tabs.selected),
                      if (drag != null && layout.sourceOf(drag.source) != null)
                        _docking(index, drag),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, int index, WorkspaceTab tab) =>
      LayoutBuilder(
        builder: (context, size) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: math.max(actionPaneMinWidth, size.maxWidth),
            height: size.maxHeight,
            child: widget.body(context, index, tab),
          ),
        ),
      );

  List<AppAction> _tabActions(int index, WorkspaceTab tab) => [
    if (!layout.pane(index).tabOf(tab).pinned)
      ...layout.destinations(tab, from: index),
    AppAction(
      'Close tab',
      layout.canClose(index, tab) ? () => layout.closeTab(index, tab) : null,
      shortcut: 'Middle click',
    ),
    if (index != 0) AppAction('Close pane', () => layout.closePane(index)),
    if (layout.count > 1) AppAction('Join all panes', layout.joinAll),
  ];

  Widget _paneHeader(BuildContext context, int index) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          Expanded(
            child: _stripTarget(
              index,
              layout.isEmpty(index)
                  ? const SizedBox(height: paneTabHeight)
                  : _strip(index),
            ),
          ),
          _paneMenu(index),
        ],
      ),
    );
  }

  /// A tab dropped on a pane's tab row, but not on one of its tabs, goes to
  /// the end of that row.
  Widget _stripTarget(int index, Widget strip) =>
      DragTarget<PaneTabDrag<WorkspaceTab>>(
        key: ValueKey('tab-row-$index'),
        onWillAcceptWithDetails: (details) {
          final source = layout.sourceOf(details.data.source);
          return source != null &&
              source != index &&
              layout.canPlace(details.data.id, index);
        },
        onAcceptWithDetails: (details) {
          final source = layout.sourceOf(details.data.source);
          _dragChanged(null);
          if (source != null) layout.move(source, index, details.data.id);
        },
        builder: (context, candidates, _) => DecoratedBox(
          decoration: BoxDecoration(
            color: candidates.isEmpty
                ? null
                : Theme.of(context).colorScheme.surfaceContainerHigh,
          ),
          child: strip,
        ),
      );

  Widget _strip(int index) => PaneTabStrip(
    tabs: layout.pane(index),
    connected: true,
    showAdd: false,
    closeButtons: false,
    onClose: (tab) => layout.closeTab(index, tab),
    onSelect: (tab) => layout.show(index, tab),
    onContextMenu: (tab, position) {
      final actions = _tabActions(index, tab);
      if (actions.isNotEmpty) {
        unawaited(showActionContextMenu(context, position, actions));
      }
    },
    onDragStarted: _dragChanged,
    onDragEnd: () => _dragChanged(null),
    onDrop: (drag, before) {
      final source = layout.sourceOf(drag.source);
      _dragChanged(null);
      if (source != null) {
        layout.move(source, index, drag.id, before: before);
      }
    },
  );

  /// The pane's `+`: every tab the mode has, opened as the layout opens a
  /// picked tab, then an empty pane and the ways to have fewer.
  Widget _paneMenu(int index) {
    final tabs = layout.pane(index);
    return MenuAnchor(
      menuChildren: [
        for (final tab in tabs.tabs)
          GestureDetector(
            onSecondaryTapUp: (details) => showActionContextMenu(
              context,
              details.globalPosition,
              layout.destinations(tab.id),
            ),
            child: MenuItemButton(
              onPressed: () => layout.open(index, tab.id),
              child: Text(tab.title),
            ),
          ),
        if (widget.actions?.call() case final actions?
            when actions.isNotEmpty) ...[
          const Divider(height: 1),
          for (final action in actions)
            MenuItemButton(
              onPressed: action.run,
              leadingIcon: action.icon == null
                  ? null
                  : Icon(action.icon, size: IconSize.menu),
              trailingIcon: action.shortcut == null
                  ? null
                  : Text(
                      action.shortcut!,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
              child: Text(action.label),
            ),
        ],
        const Divider(height: 1),
        MenuItemButton(
          onPressed: layout.canAddPane ? () => layout.addPane(index) : null,
          leadingIcon: const Icon(
            Icons.horizontal_split_outlined,
            size: IconSize.menu,
          ),
          child: const Text('New pane'),
        ),
        if (index != 0)
          MenuItemButton(
            onPressed: () => layout.closePane(index),
            child: const Text('Close pane'),
          ),
        if (layout.count > 1)
          MenuItemButton(
            onPressed: layout.joinAll,
            child: const Text('Join all panes'),
          ),
      ],
      builder: (context, menu, _) => IconButton(
        tooltip: 'Open tab',
        icon: const Icon(Icons.add, size: IconSize.menu),
        onPressed: () {
          layout.select(index);
          menu.isOpen ? menu.close() : menu.open();
        },
      ),
    );
  }

  Widget _docking(int index, PaneTabDrag<WorkspaceTab> drag) {
    final source = layout.sourceOf(drag.source)!;
    final canSplit = layout.canSplit(drag.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 3,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 3,
                child: _target(
                  index,
                  'Move here',
                  source != index && layout.canPlace(drag.id, index)
                      ? () => layout.move(source, index, drag.id)
                      : null,
                ),
              ),
              if (canSplit)
                Expanded(
                  flex: 2,
                  child: _target(
                    index,
                    'Split right',
                    () => layout.split(
                      index,
                      drag.id,
                      PaneSplitDirection.right,
                      from: source,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (canSplit)
          Expanded(
            flex: 1,
            child: _target(
              index,
              'Split below',
              () => layout.split(
                index,
                drag.id,
                PaneSplitDirection.below,
                from: source,
              ),
            ),
          ),
      ],
    );
  }

  Widget _target(int index, String label, VoidCallback? accept) {
    if (accept == null) return const SizedBox.expand();
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<PaneTabDrag<WorkspaceTab>>(
      key: ValueKey('dock-$index-$label'),
      onWillAcceptWithDetails: (details) =>
          identical(details.data, _drag) ||
          (details.data.source == _drag?.source &&
              details.data.id == _drag?.id),
      onAcceptWithDetails: (_) {
        _dragChanged(null);
        accept();
      },
      builder: (context, candidates, _) => Container(
        margin: const EdgeInsets.all(Space.xs),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh.withValues(
            alpha: candidates.isEmpty ? 0.86 : 0.98,
          ),
          border: Border.all(
            color: candidates.isEmpty
                ? scheme.outlineVariant
                : scheme.onSurface,
            width: candidates.isEmpty ? 1 : 2,
          ),
          borderRadius: BorderRadius.circular(paneTabRadius),
        ),
        alignment: Alignment.center,
        child: Text(label, style: Theme.of(context).textTheme.labelLarge),
      ),
    );
  }
}
