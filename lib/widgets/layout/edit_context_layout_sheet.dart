/// Bottom sheet to assign context views to columns and stacks.
library;

import 'package:flutter/material.dart';

import '../../models/edit_context_layout.dart';
import 'edit_context_tabs.dart';
import 'repertoire_mode.dart';

Future<void> showEditContextLayoutSheet({
  required BuildContext context,
  required EditContextLayout layout,
  required Set<EditContextView> visibleViews,
  required List<EditContextTabSpec> tabs,
  required ValueChanged<EditContextLayout> onLayoutChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      return _EditContextLayoutSheet(
        layout: layout,
        visibleViews: visibleViews,
        tabs: tabs,
        onLayoutChanged: onLayoutChanged,
      );
    },
  );
}

class _EditContextLayoutSheet extends StatefulWidget {
  final EditContextLayout layout;
  final Set<EditContextView> visibleViews;
  final List<EditContextTabSpec> tabs;
  final ValueChanged<EditContextLayout> onLayoutChanged;

  const _EditContextLayoutSheet({
    required this.layout,
    required this.visibleViews,
    required this.tabs,
    required this.onLayoutChanged,
  });

  @override
  State<_EditContextLayoutSheet> createState() => _EditContextLayoutSheetState();
}

class _EditContextLayoutSheetState extends State<_EditContextLayoutSheet> {
  late EditContextLayout _layout;

  @override
  void initState() {
    super.initState();
    _layout = widget.layout.syncVisible(widget.visibleViews);
  }

  String _label(EditContextView view) {
    for (final t in widget.tabs) {
      if (t.view == view) return t.label;
    }
    return view.name;
  }

  void _apply(EditContextLayout next) {
    setState(() => _layout = next.syncVisible(widget.visibleViews));
    widget.onLayoutChanged(_layout);
  }

  @override
  Widget build(BuildContext context) {
    final cols = _layout.columns;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          bottom: MediaQuery.paddingOf(context).bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Pane layout',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Columns are side-by-side; views within a column stack vertically. '
              'Drag dividers in the context zone to resize.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[500],
                  ),
            ),
            const SizedBox(height: 12),
            ...List.generate(cols.length, (ci) => _columnCard(ci, cols[ci])),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _apply(_layout.addColumn()),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add column'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _columnCard(int columnIndex, EditContextColumnLayout col) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Column ${columnIndex + 1}',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            if (col.views.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No views — assign from chips (long-press) or enable a panel.',
                  style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                ),
              ),
            ...List.generate(col.views.length, (si) {
              final view = col.views[si];
              if (!widget.visibleViews.contains(view)) {
                return const SizedBox.shrink();
              }
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(_label(view), style: const TextStyle(fontSize: 13)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_upward, size: 18),
                      tooltip: 'Move up in stack',
                      onPressed: si > 0
                          ? () => _moveInStack(columnIndex, si, si - 1)
                          : null,
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_downward, size: 18),
                      tooltip: 'Move down in stack',
                      onPressed: si < col.views.length - 1
                          ? () => _moveInStack(columnIndex, si, si + 1)
                          : null,
                    ),
                    PopupMenuButton<int>(
                      tooltip: 'Move to column',
                      icon: const Icon(Icons.view_column, size: 18),
                      itemBuilder: (context) => [
                        for (var i = 0; i < _layout.columns.length; i++)
                          if (i != columnIndex)
                            PopupMenuItem(
                              value: i,
                              child: Text('Column ${i + 1}'),
                            ),
                        PopupMenuItem(
                          value: _layout.columns.length,
                          child: Text('New column'),
                        ),
                      ],
                      onSelected: (targetCol) => _apply(
                        _layout.placeView(
                          view,
                          columnIndex: targetCol,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  void _moveInStack(int columnIndex, int from, int to) {
    final col = _layout.columns[columnIndex];
    final views = List<EditContextView>.from(col.views);
    final item = views.removeAt(from);
    views.insert(to, item);
    final cols = List<EditContextColumnLayout>.from(_layout.columns);
    cols[columnIndex] = col.copyWith(views: views);
    _apply(EditContextLayout(columns: cols));
  }
}
