import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../models/move_text_layout.dart';

/// Variable-height rows on both sides of an anchor. A distant cursor can become
/// the anchor without laying out every preceding comment or guessing heights.
class MoveTextViewport extends StatefulWidget {
  const MoveTextViewport({
    super.key,
    required this.layout,
    required this.session,
    required this.selectedNodeId,
    required this.rowBuilder,
    required this.selectionKey,
  });
  final MoveTextLayout layout;
  final GlobalKey selectionKey;
  final Object session;
  final int? selectedNodeId;
  final Widget Function(MoveTextRow row) rowBuilder;

  @override
  State<MoveTextViewport> createState() => _MoveTextViewportState();
}

class _MoveTextViewportState extends State<MoveTextViewport> {
  final _center = GlobalKey();
  final _mountedRows = <Object, BuildContext>{};
  int _anchor = 0;
  int _generation = 0;
  bool _revealScheduled = false;

  int get _selectedRow => widget.selectedNodeId == null
      ? 0
      : widget.layout.rowForNode(widget.selectedNodeId!) ?? 0;

  @override
  void initState() {
    super.initState();
    _anchor = _selectedRow;
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(MoveTextViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.session != oldWidget.session) {
      _anchor = _selectedRow;
      _generation++;
    } else if (!identical(widget.layout, oldWidget.layout)) {
      final oldKey = oldWidget.layout.rows.isEmpty
          ? null
          : oldWidget
                .layout
                .rows[_anchor.clamp(0, oldWidget.layout.rows.length - 1)]
                .key;
      _anchor = widget.layout.indexOfKey(oldKey ?? Object()) ?? _selectedRow;
    }
    if (widget.selectedNodeId != oldWidget.selectedNodeId) _scheduleReveal();
  }

  void _scheduleReveal() {
    if (_revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || widget.layout.rows.isEmpty) return;
      final index = _selectedRow;
      final rowContext =
          widget.selectionKey.currentContext ??
          _mountedRows[widget.layout.rows[index].key];
      if (rowContext != null && rowContext.mounted) {
        final row = rowContext.findRenderObject();
        final viewport = context.findRenderObject();
        if (row is RenderBox &&
            viewport is RenderBox &&
            row.hasSize &&
            viewport.hasSize) {
          final top = row.localToGlobal(Offset.zero, ancestor: viewport).dy;
          if (top >= 0 && top + row.size.height <= viewport.size.height) return;
          Scrollable.ensureVisible(rowContext, alignment: .25);
          return;
        }
      }
      setState(() {
        _anchor = index;
        _generation++;
      });
      _scheduleReveal();
    });
  }

  Widget _row(BuildContext context, int index) {
    final row = widget.layout.rows[index];
    return _MountedMoveTextRow(
      key: ValueKey((widget.session, row.key)),
      onMounted: (context) => _mountedRows[row.key] = context,
      onUnmounted: (context) {
        if (identical(_mountedRows[row.key], context)) {
          _mountedRows.remove(row.key);
        }
      },
      child: widget.rowBuilder(row),
    );
  }

  @override
  Widget build(BuildContext context) => CustomScrollView(
    key: ValueKey((widget.session, _generation)),
    primary: false,
    center: _center,
    scrollCacheExtent: const ScrollCacheExtent.pixels(240),
    slivers: [
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) => _row(context, _anchor - index - 1),
          childCount: _anchor,
          addAutomaticKeepAlives: false,
          findChildIndexCallback: (key) => _indexForKey(key, before: true),
        ),
      ),
      SliverList(
        key: _center,
        delegate: SliverChildBuilderDelegate(
          (context, index) => _row(context, _anchor + index),
          childCount: widget.layout.rows.length - _anchor,
          addAutomaticKeepAlives: false,
          findChildIndexCallback: (key) => _indexForKey(key, before: false),
        ),
      ),
    ],
  );

  int? _indexForKey(Key key, {required bool before}) {
    if (key is! ValueKey<(Object, Object)> || key.value.$1 != widget.session) {
      return null;
    }
    final index = widget.layout.indexOfKey(key.value.$2);
    if (index == null) return null;
    return before
        ? (index < _anchor ? _anchor - index - 1 : null)
        : (index >= _anchor ? index - _anchor : null);
  }
}

class _MountedMoveTextRow extends StatefulWidget {
  const _MountedMoveTextRow({
    super.key,
    required this.child,
    required this.onMounted,
    required this.onUnmounted,
  });
  final Widget child;
  final ValueChanged<BuildContext> onMounted;
  final ValueChanged<BuildContext> onUnmounted;
  @override
  State<_MountedMoveTextRow> createState() => _MountedMoveTextRowState();
}

class _MountedMoveTextRowState extends State<_MountedMoveTextRow> {
  @override
  void initState() {
    super.initState();
    widget.onMounted(context);
  }

  @override
  void didUpdateWidget(_MountedMoveTextRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    oldWidget.onUnmounted(context);
    widget.onMounted(context);
  }

  @override
  void dispose() {
    widget.onUnmounted(context);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
