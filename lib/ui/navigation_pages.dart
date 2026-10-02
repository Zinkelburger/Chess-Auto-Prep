import 'package:flutter/material.dart';

import 'theme.dart';

/// Repertoire navigation shares one column when the workspace needs its room.
/// Both pages stay mounted, retaining searches, selections and scroll positions.
class NavigationPages extends StatefulWidget {
  const NavigationPages({
    super.key,
    required this.list,
    required this.outline,
    required this.trailing,
    this.listLabel = 'Repertoires',
    this.selected,
    this.onSelected,
  }) : assert(selected == null || selected == 0 || selected == 1);

  final Widget list;
  final Widget outline;
  final Widget trailing;
  final String listLabel;

  /// Zero selects the repertoire list; one selects its chapters. When omitted,
  /// this widget remembers the selection, starting with the open chapter.
  final int? selected;
  final ValueChanged<int>? onSelected;

  @override
  State<NavigationPages> createState() => _NavigationPagesState();
}

class _NavigationPagesState extends State<NavigationPages> {
  int _selected = 1;

  @override
  void initState() {
    super.initState();
    _selected = widget.selected ?? 1;
  }

  @override
  void didUpdateWidget(NavigationPages oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected case final selected?) _selected = selected;
  }

  void _select(int index) {
    if (widget.selected == null) setState(() => _selected = index);
    widget.onSelected?.call(index);
  }

  Widget _tab(BuildContext context, int index, String label) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selected == index;
    return Expanded(
      child: Semantics(
        selected: selected,
        child: Tooltip(
          message: label,
          excludeFromSemantics: true,
          child: TextButton(
            onPressed: () => _select(index),
            style: TextButton.styleFrom(
              foregroundColor: selected
                  ? scheme.onSurface
                  : scheme.onSurfaceVariant,
              backgroundColor: selected ? scheme.surfaceContainerHigh : null,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(paneTabRadius),
              ),
              padding: const EdgeInsets.symmetric(horizontal: Space.s),
            ),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Row(
        children: [
          _tab(context, 0, widget.listLabel),
          _tab(context, 1, 'Chapters'),
          widget.trailing,
        ],
      ),
      const Divider(height: 1),
      Expanded(
        child: IndexedStack(
          index: _selected,
          sizing: StackFit.expand,
          children: [
            ExcludeFocus(excluding: _selected != 0, child: widget.list),
            ExcludeFocus(excluding: _selected != 1, child: widget.outline),
          ],
        ),
      ),
    ],
  );
}
