import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/pane_tabs.dart';
import '../ui/theme.dart';
import 'action_layout.dart';
import 'workspace_tabs.dart';

/// Preset slots, in reading order. No drag targets or hidden docking rules.
class ActionPanes extends StatelessWidget {
  const ActionPanes({super.key, required this.layout, required this.body});
  final ActionLayout layout;
  final Widget Function(BuildContext, int, WorkspaceTab) body;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: layout,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(Space.s),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Space.s,
            runSpacing: Space.s,
            children: [
              Text(
                'Action Tabs',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [
                  for (var count = 1; count <= 4; count++)
                    ButtonSegment(
                      value: count,
                      label: Text('$count'),
                      icon: Icon(switch (count) {
                        1 => Icons.crop_square,
                        2 => Icons.view_column_outlined,
                        3 => Icons.space_dashboard_outlined,
                        _ => Icons.grid_view,
                      }, size: IconSize.menu),
                      tooltip: switch (count) {
                        1 => '1 pane',
                        2 => '2 panes: side by side',
                        3 => '3 panes: left and two on the right',
                        _ => '4 panes: quadrants',
                      },
                    ),
                ],
                selected: {layout.count},
                onSelectionChanged: (values) => layout.arrange(values.single),
              ),
            ],
          ),
        ),
        Expanded(child: _grid(context)),
      ],
    ),
  );

  Widget _grid(BuildContext context) {
    Widget column(List<int> slots) => Column(
      children: [
        for (final index in slots) Expanded(child: _pane(context, index)),
      ],
    );
    return switch (layout.count) {
      1 => _pane(context, 0),
      2 => Row(
        children: [
          Expanded(child: _pane(context, 0)),
          Expanded(child: _pane(context, 1)),
        ],
      ),
      3 => Row(
        children: [
          Expanded(child: _pane(context, 0)),
          Expanded(child: column([1, 2])),
        ],
      ),
      _ => Row(
        children: [
          Expanded(child: column([0, 2])),
          Expanded(child: column([1, 3])),
        ],
      ),
    };
  }

  Widget _pane(BuildContext context, int index) {
    final tabs = layout.pane(index);
    final scheme = Theme.of(context).colorScheme;
    return Listener(
      onPointerDown: (_) => layout.select(index),
      child: Focus(
        onFocusChange: (focused) {
          if (focused) layout.select(index);
        },
        child: Container(
          key: ValueKey('action-pane-$index'),
          margin: const EdgeInsets.all(Space.xs),
          decoration: BoxDecoration(
            border: Border.all(
              color: layout.active == index
                  ? scheme.primary
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
                child: LayoutBuilder(
                  builder: (context, size) => SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      width: math.max(actionPaneMinWidth, size.maxWidth),
                      height: size.maxHeight,
                      child: body(context, index, tabs.selected),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _paneHeader(BuildContext context, int index) {
    final tabs = layout.pane(index);
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.surfaceContainer,
      child: Row(
        children: [
          if (layout.count > 1)
            SizedBox(
              width: paneTabCloseSize,
              child: Center(
                child: Text(
                  '${index + 1}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            ),
          Expanded(
            child: PaneTabStrip(
              tabs: tabs,
              connected: true,
              showAdd: false,
              onSelect: (tab) {
                layout.select(index);
                tabs.show(tab);
              },
            ),
          ),
          MenuAnchor(
            menuChildren: [
              for (final tab in tabs.tabs)
                MenuItemButton(
                  onPressed: () {
                    layout.select(index);
                    tabs.show(tab.id);
                  },
                  child: Text(tab.title),
                ),
            ],
            builder: (context, menu, _) => IconButton(
              tooltip: layout.count == 1
                  ? 'Open tab'
                  : 'Choose Action Tab for pane ${index + 1}',
              icon: const Icon(Icons.add, size: IconSize.menu),
              onPressed: menu.isOpen ? menu.close : menu.open,
            ),
          ),
        ],
      ),
    );
  }
}
