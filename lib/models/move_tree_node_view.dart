/// Read-only view of a move-tree node.
///
/// The app historically grew structurally-identical move-tree node types
/// (`MoveNode`, `BuildTreeNode`) plus the distinct stats tree
/// `OpeningTreeNode`. This interface lets a single cursor / navigation /
/// serializer / display routine work across all of them without coupling to a
/// concrete type. (`MoveNode` now also serves the analysis viewer, which
/// previously had its own identical `AnalysisNode`.) See
/// `docs/MAINTAINABILITY_PLAN.md` WS-B.
///
/// It is intentionally read-only — mutation stays on the concrete classes.
library;

abstract interface class MoveTreeNodeView {
  /// SAN of the move that produced this node's position.
  String get san;

  /// FEN of the position *after* this move.
  String get fenAfter;

  /// Children in display order; `[0]` is the mainline continuation.
  List<MoveTreeNodeView> get orderedChildren;
}
