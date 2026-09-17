import 'package:flutter/widgets.dart';
import '../../../design_system/layout/anchored_document_viewport.dart';
import '../models/move_text_layout.dart';

/// Adapts the move-tree layout to the shared document viewport. Chess selection
/// lookup stays here; scroll lifetime, bounded mounting and anchors are shared.
class MoveTextViewport extends StatelessWidget {
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
  Widget build(BuildContext context) => AnchoredDocumentViewport(
    rows: _MoveTextRows(layout),
    session: session,
    selection: selectedNodeId,
    selectedRow: selectedNodeId == null
        ? 0
        : layout.rowForNode(selectedNodeId!),
    selectionKey: selectionKey,
    rowBuilder: (index) => rowBuilder(layout.rows[index]),
  );
}

class _MoveTextRows implements DocumentRows {
  const _MoveTextRows(this.layout);
  final MoveTextLayout layout;
  @override
  Object get revision => layout;
  @override
  int get length => layout.rows.length;
  @override
  Object keyAt(int index) => layout.rows[index].key;
  @override
  int? indexOfKey(Object key) => layout.indexOfKey(key);
}
