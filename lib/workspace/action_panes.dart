import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/action_context_menu.dart';
import '../ui/app_action.dart';
import '../ui/menu_entry.dart';
import '../ui/pane_tabs.dart';
import '../ui/theme.dart';
import 'action_layout.dart';
import 'workspace_tabs.dart';
import '../ui/app_icons.dart';
import '../ui/tool_button.dart';

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

  void _dragChanged(PaneTabDrag<WorkspaceTab>? drag) {
    if (!mounted) return;
    setState(() => _drag = drag);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.layout,
    builder: (context, _) => _Grid(
      panes: _Panes(
        layout: widget.layout,
        drag: _drag,
        onDrag: _dragChanged,
        body: widget.body,
        actions: widget.actions,
      ),
      node: widget.layout.root,
    ),
  );
}

/// What every part of the panes draws from: the layout, the tab being
/// dragged and what the mode supplies.
class _Panes {
  const _Panes({
    required this.layout,
    required this.drag,
    required this.onDrag,
    required this.body,
    required this.actions,
  });

  final ActionLayout layout;
  final PaneTabDrag<WorkspaceTab>? drag;
  final ValueChanged<PaneTabDrag<WorkspaceTab>?> onDrag;
  final Widget Function(BuildContext, int, WorkspaceTab) body;
  final List<AppAction> Function()? actions;

  /// Moves alone on the card is the page of a book: no strip and no frame,
  /// the `+` in its corner.
  bool get page =>
      layout.count == 1 &&
      layout.openIn(0).length == 1 &&
      layout.openIn(0).single == WorkspaceTab.moves;
}

/// The width under which [tab] scrolls sideways: the moves wrap and
/// the Expectimax pane folds its bar, so both go narrower than the rest.
double _leastWidth(WorkspaceTab tab) => switch (tab) {
  WorkspaceTab.moves || WorkspaceTab.analysis => paneMinWidth,
  WorkspaceTab.search => searchPaneMinWidth,
  _ => actionPaneMinWidth,
};

class _Grid extends StatelessWidget {
  const _Grid({required this.panes, required this.node});

  final _Panes panes;
  final ActionPaneNode node;

  @override
  Widget build(BuildContext context) => switch (node) {
    final ActionPaneLeaf leaf => _Pane(panes: panes, index: leaf.index),
    final ActionPaneSplit split => _Split(panes: panes, node: split),
  };
}

/// Two panes at the split's share, with the gap between them as the
/// divider: dragged, it moves the share, which the layout keeps.
class _Split extends StatelessWidget {
  const _Split({required this.panes, required this.node});

  final _Panes panes;
  final ActionPaneSplit node;

  ActionLayout get layout => panes.layout;

  @override
  Widget build(BuildContext context) {
    final across = node.direction == PaneSplitDirection.right;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return LayoutBuilder(
      builder: (context, room) {
        final total = across ? room.maxWidth : room.maxHeight;
        final (minimum, maximum) = _bounds(node, total, across, scale);
        final first = (total * node.share).clamp(minimum, maximum);
        return Stack(
          children: [
            Flex(
              direction: across ? Axis.horizontal : Axis.vertical,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: across ? first : null,
                  height: across ? null : first,
                  child: _Grid(panes: panes, node: node.first),
                ),
                Expanded(
                  child: _Grid(panes: panes, node: node.second),
                ),
              ],
            ),
            Positioned(
              key: ValueKey(
                'pane-divider-${node.first.indices.first}-'
                '${node.second.indices.first}',
              ),
              left: across ? first - paneDividerGrab : 0,
              top: across ? 0 : first - paneDividerGrab,
              width: across ? 2 * paneDividerGrab : room.maxWidth,
              height: across ? room.maxHeight : 2 * paneDividerGrab,
              child: MouseRegion(
                cursor: across
                    ? SystemMouseCursors.resizeColumn
                    : SystemMouseCursors.resizeRow,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: across
                      ? (drag) => _resize(drag.delta.dx, total, across, scale)
                      : null,
                  onVerticalDragUpdate: across
                      ? null
                      : (drag) => _resize(drag.delta.dy, total, across, scale),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Moves [node]'s divider by [by] pixels of [total], keeping each side
  /// at least a narrow pane's width.
  // Render constraints do not change the saved proportions. Widening the
  // window restores the user's allocation, including nested splits.
  (double, double) _bounds(
    ActionPaneSplit node,
    double total,
    bool across,
    double scale,
  ) {
    final first = _minimum(node.first, across, scale);
    final second = _minimum(node.second, across, scale);
    if (total < first + second) {
      final fit = total * first / (first + second);
      return (fit, fit);
    }
    return (first, total - second);
  }

  double _minimum(ActionPaneNode node, bool across, double scale) {
    if (node is ActionPaneSplit) {
      final first = _minimum(node.first, across, scale);
      final second = _minimum(node.second, across, scale);
      return (node.direction == PaneSplitDirection.right) == across
          ? first + second
          : math.max(first, second);
    }
    if (!across) return paneMinWidth;
    final tab = layout.pane((node as ActionPaneLeaf).index).selected;
    final width = tab == WorkspaceTab.moves
        ? movesPaneComfortWidth
        : _leastWidth(tab);
    return width * scale + 2 * Space.xs;
  }

  void _resize(double by, double total, bool across, double scale) {
    if (total <= 0) return;
    final now = _current();
    final (minimum, maximum) = _bounds(now, total, across, scale);
    if (minimum == maximum) return;
    final first = (total * now.share).clamp(minimum, maximum);
    layout.resize(now, (first + by).clamp(minimum, maximum) / total);
  }

  /// The split now in the layout that [node] was drawn from: a drag's
  /// updates each rebuild the tree.
  ActionPaneSplit _current() {
    ActionPaneSplit? find(ActionPaneNode at) => switch (at) {
      ActionPaneLeaf() => null,
      ActionPaneSplit()
          when at.direction == node.direction &&
              at.first.indices.first == node.first.indices.first &&
              at.second.indices.first == node.second.indices.first =>
        at,
      ActionPaneSplit() => find(at.first) ?? find(at.second),
    };
    return find(layout.root) ?? node;
  }
}

class _Pane extends StatelessWidget {
  const _Pane({required this.panes, required this.index});

  final _Panes panes;
  final int index;

  @override
  Widget build(BuildContext context) {
    final layout = panes.layout;
    final tabs = layout.pane(index);
    final scheme = Theme.of(context).colorScheme;
    final drag = panes.drag;
    if (panes.page) {
      return Stack(
        key: ValueKey('action-pane-$index'),
        fit: StackFit.expand,
        children: [
          _PaneBody(panes: panes, index: index, tab: tabs.selected),
          Positioned(
            top: Space.xs,
            right: Space.xs,
            child: _PaneMenu(panes: panes, index: index, labeled: true),
          ),
        ],
      );
    }
    return Listener(
      onPointerDown: (_) => layout.select(index),
      child: Focus(
        onFocusChange: (focused) {
          if (context.mounted && focused) layout.select(index);
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
                    ? activePaneBorder
                    : scheme.outlineVariant,
              ),
              borderRadius: BorderRadius.circular(paneTabRadius),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                _PaneHeader(panes: panes, index: index),
                const Divider(height: 1),
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (!layout.isEmpty(index))
                        _PaneBody(
                          panes: panes,
                          index: index,
                          tab: tabs.selected,
                        ),
                      if (drag != null && layout.sourceOf(drag.source) != null)
                        _Docking(panes: panes, index: index, drag: drag),
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
}

class _PaneBody extends StatelessWidget {
  const _PaneBody({
    required this.panes,
    required this.index,
    required this.tab,
  });

  final _Panes panes;
  final int index;
  final WorkspaceTab tab;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) => SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: math.max(_leastWidth(tab), size.maxWidth),
        height: size.maxHeight,
        child: panes.body(context, index, tab),
      ),
    ),
  );
}

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.panes, required this.index});

  final _Panes panes;
  final int index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainerLow,
      child: Row(
        children: [
          Expanded(
            child: _StripTarget(
              panes: panes,
              index: index,
              strip: panes.layout.isEmpty(index)
                  ? const SizedBox(height: paneTabHeight)
                  : _Strip(panes: panes, index: index),
            ),
          ),
          _PaneMenu(panes: panes, index: index),
        ],
      ),
    );
  }
}

/// A tab dropped on a pane's tab row, but not on one of its tabs, goes to
/// the end of that row.
class _StripTarget extends StatelessWidget {
  const _StripTarget({
    required this.panes,
    required this.index,
    required this.strip,
  });

  final _Panes panes;
  final int index;
  final Widget strip;

  @override
  Widget build(BuildContext context) {
    final layout = panes.layout;
    return DragTarget<PaneTabDrag<WorkspaceTab>>(
      key: ValueKey('tab-row-$index'),
      onWillAcceptWithDetails: (details) {
        final source = layout.sourceOf(details.data.source);
        return source != null &&
            source != index &&
            layout.canPlace(details.data.id, index);
      },
      onAcceptWithDetails: (details) {
        final source = layout.sourceOf(details.data.source);
        panes.onDrag(null);
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
  }
}

class _Strip extends StatelessWidget {
  const _Strip({required this.panes, required this.index});

  final _Panes panes;
  final int index;

  List<AppAction> _tabActions(WorkspaceTab tab) {
    final layout = panes.layout;
    return [
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
  }

  @override
  Widget build(BuildContext context) {
    final layout = panes.layout;
    return PaneTabStrip(
      tabs: layout.pane(index),
      connected: true,
      showAdd: false,
      closeButtons: false,
      onClose: (tab) => layout.closeTab(index, tab),
      onSelect: (tab) => layout.show(index, tab),
      onContextMenu: (tab, position) {
        final actions = _tabActions(tab);
        if (actions.isNotEmpty) {
          unawaited(showActionContextMenu(context, position, actions));
        }
      },
      onDragStarted: panes.onDrag,
      onDragEnd: () => panes.onDrag(null),
      onDrop: (drag, before) {
        final source = layout.sourceOf(drag.source);
        panes.onDrag(null);
        if (source != null) {
          layout.move(source, index, drag.id, before: before);
        }
      },
    );
  }
}

/// The pane's `+`: every tab the mode has, opened as the layout opens a
/// picked tab, then an empty pane and the ways to have fewer.
class _PaneMenu extends StatelessWidget {
  const _PaneMenu({
    required this.panes,
    required this.index,
    this.labeled = false,
  });

  final _Panes panes;
  final int index;
  final bool labeled;

  @override
  Widget build(BuildContext context) {
    final layout = panes.layout;
    final tabs = layout.pane(index);
    return MenuAnchor(
      menuChildren: alignMenu([
        for (final tab in tabs.tabs)
          MenuEntry(
            tab.title,
            () => layout.open(index, tab.id),
            alternatives: layout.destinations(tab.id),
          ),
        if (panes.actions?.call() case final actions?
            when actions.isNotEmpty) ...[
          const Divider(height: 1),
          for (final action in actions) MenuEntry.action(action),
        ],
        const Divider(height: 1),
        if (layout.count > 1) ...[
          MenuEntry('More room', () => layout.resizeActive(0.05)),
          MenuEntry('Less room', () => layout.resizeActive(-0.05)),
        ],
        MenuEntry(
          'New pane',
          layout.canAddPane ? () => layout.addPane(index) : null,
          icon: AppIcons.newPane,
        ),
        if (index != 0) MenuEntry('Close pane', () => layout.closePane(index)),
        if (layout.count > 1) MenuEntry('Join all panes', layout.joinAll),
      ]),
      builder: (context, menu, _) => _MenuButton(
        layout: layout,
        menu: menu,
        index: index,
        labeled: labeled,
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({
    required this.layout,
    required this.menu,
    required this.index,
    required this.labeled,
  });

  final ActionLayout layout;
  final MenuController menu;
  final int index;
  final bool labeled;

  @override
  Widget build(BuildContext context) {
    void toggle() {
      layout.select(index);
      menu.isOpen ? menu.close() : menu.open();
    }

    const tip = 'Open tools and arrange panes';
    return labeled
        ? Tooltip(
            message: tip,
            child: TextButton.icon(
              icon: const Icon(AppIcons.add, size: IconSize.menu),
              label: const Text('Tools'),
              onPressed: toggle,
            ),
          )
        : ToolButton(
            icon: AppIcons.add,
            tooltip: tip,
            size: IconSize.menu,
            onPressed: toggle,
          );
  }
}

class _Docking extends StatelessWidget {
  const _Docking({
    required this.panes,
    required this.index,
    required this.drag,
  });

  final _Panes panes;
  final int index;
  final PaneTabDrag<WorkspaceTab> drag;

  @override
  Widget build(BuildContext context) {
    final layout = panes.layout;
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
                child: _DockTarget(
                  panes: panes,
                  index: index,
                  label: 'Move here',
                  accept: source != index && layout.canPlace(drag.id, index)
                      ? () => layout.move(source, index, drag.id)
                      : null,
                ),
              ),
              if (canSplit)
                Expanded(
                  flex: 2,
                  child: _DockTarget(
                    panes: panes,
                    index: index,
                    label: 'Split right',
                    accept: () => layout.split(
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
            child: _DockTarget(
              panes: panes,
              index: index,
              label: 'Split below',
              accept: () => layout.split(
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
}

class _DockTarget extends StatelessWidget {
  const _DockTarget({
    required this.panes,
    required this.index,
    required this.label,
    required this.accept,
  });

  final _Panes panes;
  final int index;
  final String label;
  final VoidCallback? accept;

  @override
  Widget build(BuildContext context) {
    final accept = this.accept;
    if (accept == null) return const SizedBox.expand();
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<PaneTabDrag<WorkspaceTab>>(
      key: ValueKey('dock-$index-$label'),
      onWillAcceptWithDetails: (details) =>
          identical(details.data, panes.drag) ||
          (details.data.source == panes.drag?.source &&
              details.data.id == panes.drag?.id),
      onAcceptWithDetails: (_) {
        panes.onDrag(null);
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
