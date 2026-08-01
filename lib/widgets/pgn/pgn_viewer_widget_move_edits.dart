// Adding user moves to the PGN viewer — permanent edits in edit mode,
// ephemeral scratch analysis otherwise — plus clearing / deleting analysis
// nodes. Part of pgn_viewer_widget.dart; mixed into _PgnViewerWidgetState.
// Thin setState/notify wrappers around [ViewerGameModel], which owns the
// actual mutations.
part of '../pgn_viewer_widget.dart';

mixin _PgnViewerMoveEdits on _PgnViewerWidgetStateBase {
  // ── Adding user moves ──

  void _addAnalysisMove(String san) {
    // In edit mode, moves become permanent edits saved to disk: extending the
    // mainline at its end, or adding a real (non-ephemeral) sideline elsewhere.
    // Outside edit mode, moves are ephemeral scratch analysis (never saved).
    final editing =
        widget.editMode &&
        widget.onCommentsChanged != null &&
        widget.revealedPly == null;

    // While an inline comment-preview is active, _currentPosition is the
    // preview board (not the mainline tail), so the mainline fast paths are
    // off the table: appending `san` there would splice a move that is
    // illegal from the real last position into the persisted mainline.
    final kind = _m.addMove(
      san,
      editing: editing,
      allowMainline: !_inlineActive,
    );
    if (kind == ViewerMoveKind.illegal) return;

    setState(_clearInlineLine);
    if (kind == ViewerMoveKind.extendedMainline ||
        (kind == ViewerMoveKind.variation && editing)) {
      _notifyCommentsChanged();
    }
    widget.onPositionChanged?.call(_currentPosition);
  }

  /// Add [san] as an ephemeral variation root at the current mainline ply
  /// without navigating into it — the board stays on the pre-move position.
  /// Used by solitaire to show wrong attempts as live variations.
  void _recordVariationMove(String san) {
    if (_inlineActive) return;
    if (_m.recordVariationMove(san)) setState(() {});
  }

  /// Persist the user's wrong solitaire guesses as real (non-ephemeral) sideline
  /// variations at each guessed ply, so the saved / exported game shows what the
  /// solver tried beside the actual move. [wrongByPly] maps a 0-based mainline
  /// ply to the SANs tried there. Any matching live ephemeral node (added by
  /// [_recordVariationMove] during play) is promoted rather than duplicated.
  void _addGuessVariations(Map<int, List<String>> wrongByPly) {
    if (!_m.addGuessVariations(wrongByPly)) return;
    setState(() {});
    _notifyCommentsChanged();
  }

  // ── Clear / delete ──

  @override
  void _clearAnalysis() {
    setState(() {
      _m.clearAnalysis();
      _clearInlineLine();
    });
  }

  @override
  void _deleteAnalysisNode(int nodeId) {
    // The model may retreat the cursor out of the deleted subtree, which
    // moves the board — mirror the old behavior of notifying only then.
    final fenBefore = _currentPosition.fen;
    setState(() => _m.deleteAnalysisNode(nodeId));
    if (_currentPosition.fen != fenBefore) {
      widget.onPositionChanged?.call(_currentPosition);
    }
  }
}
