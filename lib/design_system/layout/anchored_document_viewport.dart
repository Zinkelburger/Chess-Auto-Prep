import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

/// Immutable row identity/index supplied by a document renderer. Implementations
/// expose no widgets or mutable document objects to the viewport. Keep revision
/// stable for selection-only updates so scrolling does not rebuild the index.
abstract interface class DocumentRows {
  Object get revision;
  int get length;
  Object keyAt(int index);
  int? indexOfKey(Object key);
}

/// Variable-height rows on both sides of an anchor. A distant cursor can become
/// the anchor without laying out every preceding comment or guessing heights.
class AnchoredDocumentViewport extends StatefulWidget {
  const AnchoredDocumentViewport({
    super.key,
    required this.rows,
    required this.session,
    required this.selection,
    required this.selectedRow,
    required this.rowBuilder,
    required this.selectionKey,
    this.controller,
    this.scrollViewKey,
    this.revealSelection = true,
    this.restoreAnchor,
    this.onAnchorChanged,
  });
  final ScrollController? controller;
  final Key? scrollViewKey;

  /// Hosts with a layout-time reading policy own exact-item reveal.
  final bool revealSelection;
  final Object? restoreAnchor;
  final ValueChanged<Object?>? onAnchorChanged;
  final DocumentRows rows;
  final GlobalKey selectionKey;
  final Object session;

  /// Identity of the selected item, which may change inside the same row.
  final Object? selection;
  final int? selectedRow;

  final Widget Function(int index) rowBuilder;

  @override
  State<AnchoredDocumentViewport> createState() =>
      _AnchoredDocumentViewportState();
}

class _AnchoredDocumentViewportState extends State<AnchoredDocumentViewport> {
  final _center = UniqueKey();
  final _mountedRows = <Object, BuildContext>{};
  int _anchor = 0;
  int _generation = 0;
  bool _revealScheduled = false;

  int get _selectedRow => (widget.selectedRow ?? 0).clamp(
    0,
    widget.rows.length == 0 ? 0 : widget.rows.length - 1,
  );

  @override
  void initState() {
    super.initState();
    _anchor =
        widget.rows.indexOfKey(widget.restoreAnchor ?? Object()) ??
        _selectedRow;
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(AnchoredDocumentViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.session != oldWidget.session) {
      _anchor = _selectedRow;
      _generation++;
    } else if (!identical(widget.rows.revision, oldWidget.rows.revision)) {
      final oldKey = oldWidget.rows.length == 0
          ? null
          : oldWidget.rows.keyAt(_anchor.clamp(0, oldWidget.rows.length - 1));
      _anchor = widget.rows.indexOfKey(oldKey ?? Object()) ?? _selectedRow;
    }
    if (widget.restoreAnchor != null &&
        widget.restoreAnchor != oldWidget.restoreAnchor) {
      _anchor = widget.rows.indexOfKey(widget.restoreAnchor!) ?? _selectedRow;
      _generation++;
    }
    if (widget.selection != oldWidget.selection ||
        widget.session != oldWidget.session) {
      // Mount a distant target in this build. Also move reverse-side targets
      // to the forward sliver: a host resolving the exact child origin during
      // layout must not read a reverse sliver child's height. Waiting until
      // after the first frame would paint at the previous page's offset.
      if (widget.restoreAnchor == null &&
          widget.rows.length > 0 &&
          (_selectedRow < _anchor ||
              !_mountedRows.containsKey(widget.rows.keyAt(_selectedRow)))) {
        _anchor = _selectedRow;
        _generation++;
      }
      _scheduleReveal();
    }
  }

  void _scheduleReveal() {
    if (!widget.revealSelection || _revealScheduled) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || widget.rows.length == 0) return;
      final index = _selectedRow;
      final rowContext =
          widget.selectionKey.currentContext ??
          _mountedRows[widget.rows.keyAt(index)];
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
    final key = widget.rows.keyAt(index);
    return _MountedDocumentRow(
      key: ValueKey((widget.session, key)),
      onMounted: (context) => _mountedRows[key] = context,
      onUnmounted: (context) {
        if (identical(_mountedRows[key], context)) {
          _mountedRows.remove(key);
        }
      },
      child: widget.rowBuilder(index),
    );
  }

  @override
  Widget build(BuildContext context) {
    widget.onAnchorChanged?.call(
      widget.rows.length == 0 ? null : widget.rows.keyAt(_anchor),
    );
    return KeyedSubtree(
      key: ValueKey((widget.session, _generation)),
      child: CustomScrollView(
        key: widget.scrollViewKey,
        controller: widget.controller,
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
              childCount: widget.rows.length - _anchor,
              addAutomaticKeepAlives: false,
              findChildIndexCallback: (key) => _indexForKey(key, before: false),
            ),
          ),
        ],
      ),
    );
  }

  int? _indexForKey(Key key, {required bool before}) {
    if (key is! ValueKey<(Object, Object)> || key.value.$1 != widget.session) {
      return null;
    }
    final index = widget.rows.indexOfKey(key.value.$2);
    if (index == null) return null;
    return before
        ? (index < _anchor ? _anchor - index - 1 : null)
        : (index >= _anchor ? index - _anchor : null);
  }
}

class _MountedDocumentRow extends StatefulWidget {
  const _MountedDocumentRow({
    super.key,
    required this.child,
    required this.onMounted,
    required this.onUnmounted,
  });
  final Widget child;
  final ValueChanged<BuildContext> onMounted;
  final ValueChanged<BuildContext> onUnmounted;
  @override
  State<_MountedDocumentRow> createState() => _MountedDocumentRowState();
}

class _MountedDocumentRowState extends State<_MountedDocumentRow> {
  @override
  void initState() {
    super.initState();
    widget.onMounted(context);
  }

  @override
  void didUpdateWidget(_MountedDocumentRow oldWidget) {
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
