// Move annotation editing for the PGN viewer: inline comment editing, the
// amend-mode annotation panel, and NAG toggling on mainline and variation
// moves. Part of pgn_viewer_widget.dart; mixed into _PgnViewerWidgetState.
part of '../pgn_viewer_widget.dart';

mixin _PgnViewerAnnotations on _PgnViewerWidgetStateBase {
  // ── Move comment editing ──

  int? _editingCommentIndex;

  @override
  void _startEditingComment(int moveIndex) {
    setState(() => _editingCommentIndex = moveIndex);
  }

  // ── Amend-mode annotation panel ──

  /// The variation node the amend panel targets, or null when on the mainline.
  MoveNode? get _panelVariationTarget =>
      _analysisPath.isNotEmpty ? _analysisPath.last : null;

  /// The mainline move index the amend panel targets (the move the board
  /// currently sits on), or -1 when off-mainline or at the game start.
  int get _panelMainlineTarget =>
      (_analysisPath.isEmpty && !_inlineActive) ? _mainLineIndex - 1 : -1;

  String _moveLabelAt(int ply, String san) {
    final coords = coordsAtPly(
      ply: ply,
      startFullmoves: _startPosition.fullmoves,
      startWhiteToMove: _startPosition.turn == Side.white,
    );
    return '${coords.moveNumber}${coords.isWhite ? '.' : '...'}$san';
  }

  void _togglePanelNodeNag(MoveNode node, int nagId) {
    setState(() => _m.toggleNodeNag(node, nagId));
    _notifyCommentsChanged();
  }

  /// Set the comment on a variation [node]. Invoked by the annotation panel,
  /// possibly as a debounce flush after navigation moved off [node] (or during
  /// panel dispose) — hence the object binding and the `mounted` guard.
  void _setPanelNodeComment(MoveNode node, String text) {
    _m.setNodeComment(node, text);
    if (mounted) setState(() {});
    _notifyCommentsChanged();
  }

  /// Mainline counterpart of [_setPanelNodeComment], bound to the move's
  /// [PgnNodeData] so late flushes hit the move they were typed on.
  void _setPanelMainlineComment(PgnNodeData moveData, String text) {
    ViewerGameModel.writeWholeComment(moveData, text);
    if (mounted) setState(() {});
    _notifyCommentsChanged();
  }

  Widget _buildAnnotationPanel() {
    String? targetKey;
    var label = '';
    List<int> nags = const [];
    var comment = '';
    // Bound to the target at build time so a debounced comment flush that
    // lands after the user navigated elsewhere still edits the right move.
    ValueChanged<int> onToggleNag = (_) {};
    ValueChanged<String> onCommentChanged = (_) {};

    final node = _panelVariationTarget;
    final mainIndex = _panelMainlineTarget;
    if (node != null) {
      targetKey = 'v${node.id}';
      label = _moveLabelAt(
        _activeBranchPly + _analysisPath.length - 1,
        node.san,
      );
      nags = node.nags ?? const [];
      // The field carries prose only; the move's `[%eval]` / `[%pv]` / `[%clk]`
      // tokens are re-attached on save, so typing a comment cannot delete the
      // analysis the viewer draws from.
      final raw = node.comment ?? '';
      comment = commentProse(raw);
      onToggleNag = (nagId) => _togglePanelNodeNag(node, nagId);
      onCommentChanged = (text) =>
          _setPanelNodeComment(node, mergeCommentProse(raw, text));
    } else if (mainIndex >= 0 && mainIndex < _moveHistory.length) {
      targetKey = 'm$mainIndex';
      final moveData = _moveHistory[mainIndex];
      label = _moveLabelAt(mainIndex, moveData.san);
      nags = moveData.nags ?? const [];
      final raw = joinComments(moveData.comments);
      comment = commentProse(raw);
      onToggleNag = (nagId) => _toggleNag(mainIndex, nagId);
      onCommentChanged = (text) =>
          _setPanelMainlineComment(moveData, mergeCommentProse(raw, text));
    }

    return PgnAnnotationPanel(
      targetKey: targetKey,
      moveLabel: label,
      nags: nags,
      comment: comment,
      onToggleNag: onToggleNag,
      onCommentChanged: onCommentChanged,
    );
  }

  void _saveComment(int moveIndex, String newComment) {
    if (moveIndex < 0 || moveIndex >= _moveHistory.length) return;
    final moveData = _moveHistory[moveIndex];
    final merged = mergeCommentProse(
      joinComments(moveData.comments),
      newComment,
    );
    setState(() {
      ViewerGameModel.writeWholeComment(moveData, merged);
      _editingCommentIndex = null;
    });
    _notifyCommentsChanged();
  }

  void _cancelEditingComment() {
    setState(() => _editingCommentIndex = null);
  }

  /// Append guess notes to mainline move comments and persist once, keeping
  /// the game's own annotations (unlike replacing the whole movetext).
  void _addGuessAnnotations(Map<int, String> notes) {
    if (notes.isEmpty || _moveHistory.isEmpty) return;
    setState(() => _m.appendGuessNotes(notes));
    _notifyCommentsChanged();
  }

  /// Guess notes for sideline moves ([notes] keyed by node id).
  void _addGuessNodeAnnotations(Map<int, String> notes) {
    if (notes.isEmpty) return;
    var changed = false;
    setState(() => changed = _m.appendGuessNodeNotes(notes));
    if (changed) _notifyCommentsChanged();
  }

  void _toggleNag(int moveIndex, int nagId) {
    if (moveIndex < 0 || moveIndex >= _moveHistory.length) return;
    setState(() => _m.toggleMainlineNag(moveIndex, nagId));
    _notifyCommentsChanged();
  }
}
