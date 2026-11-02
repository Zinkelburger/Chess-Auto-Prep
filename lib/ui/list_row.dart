import 'package:flutter/material.dart';

import 'app_keys.dart';
import 'row_actions.dart';
import 'theme.dart';

/// One row of a list: a fixed height, the whole row a click target, the
/// selected row filled in Selection Grey and lines picked among several
/// tinted. With a [menu], the row ends in its `⋯` button, and a right click
/// or Shift+F10 opens the same menu.
///
/// Every list in the app is built from these, so a selected row, a hovered
/// one and a row's actions look and behave the same everywhere.
class ListRow extends StatefulWidget {
  const ListRow({
    super.key,
    required this.child,
    this.selected = false,
    this.picked = false,
    this.onTap,
    this.menu,
    this.menuTooltip = 'Actions',
    this.height = listRowHeight,
    this.padding,
  });

  /// What the row says, usually a [Row]; it takes the width the menu
  /// button leaves.
  final Widget child;

  /// This is the thing open, on the board or in the pane beside the list.
  final bool selected;

  /// Picked with Ctrl or Shift among several, to be moved together.
  final bool picked;

  final VoidCallback? onTap;

  /// The row's actions, usually from `rowAction`; null for a row without
  /// any.
  final List<Widget>? menu;

  /// What the `⋯` button says it opens.
  final String menuTooltip;

  /// The row's fixed height; null only for a row inside a list that sets
  /// the extent itself.
  final double? height;

  /// The room around the words; by default a small inset on the left and,
  /// with a menu, a smaller one on the right.
  final EdgeInsetsGeometry? padding;

  @override
  State<ListRow> createState() => _ListRowState();
}

class _ListRowState extends State<ListRow> {
  final _menu = MenuController();
  final _button = GlobalKey();

  /// The menu, opened where the pointer is when it has one.
  void _open([Offset? global]) {
    if (widget.menu == null) return;
    final box = _button.currentContext?.findRenderObject();
    if (global == null || box is! RenderBox) {
      _menu.open();
      return;
    }
    _menu.open(position: box.globalToLocal(global));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final menu = widget.menu;
    final padding =
        widget.padding ??
        EdgeInsets.only(
          left: Space.m,
          right: menu == null ? Space.m : Space.xs,
        );
    Widget content = Padding(
      padding: padding,
      child: menu == null
          ? widget.child
          : Row(
              children: [
                Expanded(child: widget.child),
                RowActions(
                  key: _button,
                  controller: _menu,
                  tooltip: widget.menuTooltip,
                  children: menu,
                ),
              ],
            ),
    );
    if (widget.height case final height?) {
      content = SizedBox(height: height, child: content);
    }
    Widget row = Material(
      color: widget.selected
          ? scheme.secondaryContainer
          : widget.picked
          ? selectedTint
          : Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onSecondaryTapUp: menu == null
            ? null
            : (details) => _open(details.globalPosition),
        child: content,
      ),
    );
    if (menu != null) {
      row = CallbackShortcuts(
        bindings: AppKey.focusMenu.bind<VoidCallback>(_open),
        child: row,
      );
    }
    return Semantics(selected: widget.selected, child: row);
  }
}
