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

  /// Mark [node] and every ancestor up to its variation root as saved
  /// (non-ephemeral): the serializer drops ephemeral nodes wholesale, so an
  /// annotation or permanent move under an ephemeral ancestor would silently
  /// never reach the file.
  @override
  void _promoteNodeLineage(MoveNode node) {
    for (final roots in _variationsByPly.values) {
      final path = _findPathToNode(node, roots);
      if (path == null) continue;
      for (final n in path) {
        n.isEphemeral = false;
      }
      return;
    }
  }

  void _togglePanelNodeNag(MoveNode node, int nagId) {
    _promoteNodeLineage(node);
    setState(() {
      final next = toggleQualityNag(node.nags, nagId);
      node.nags = next.isEmpty ? null : next;
    });
    _notifyCommentsChanged();
  }

  /// Set the comment on a variation [node]. Invoked by the annotation panel,
  /// possibly as a debounce flush after navigation moved off [node] (or during
  /// panel dispose) — hence the object binding and the `mounted` guard.
  void _setPanelNodeComment(MoveNode node, String text) {
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) _promoteNodeLineage(node);
    node.comment = trimmed.isEmpty ? null : trimmed;
    if (mounted) setState(() {});
    _notifyCommentsChanged();
  }

  /// Mainline counterpart of [_setPanelNodeComment], bound to the move's
  /// [PgnNodeData] so late flushes hit the move they were typed on.
  void _setPanelMainlineComment(PgnNodeData moveData, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      moveData.comments?.clear();
    } else if (moveData.comments == null || moveData.comments!.isEmpty) {
      moveData.comments = [trimmed];
    } else {
      moveData.comments![0] = trimmed;
    }
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
      comment = node.comment ?? '';
      onToggleNag = (nagId) => _togglePanelNodeNag(node, nagId);
      onCommentChanged = (text) => _setPanelNodeComment(node, text);
    } else if (mainIndex >= 0 && mainIndex < _moveHistory.length) {
      targetKey = 'm$mainIndex';
      final moveData = _moveHistory[mainIndex];
      label = _moveLabelAt(mainIndex, moveData.san);
      nags = moveData.nags ?? const [];
      comment = (moveData.comments == null || moveData.comments!.isEmpty)
          ? ''
          : moveData.comments!.first;
      onToggleNag = (nagId) => _toggleNag(mainIndex, nagId);
      onCommentChanged = (text) => _setPanelMainlineComment(moveData, text);
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
    final trimmed = newComment.trim();
    setState(() {
      if (trimmed.isEmpty) {
        moveData.comments?.clear();
      } else {
        if (moveData.comments == null || moveData.comments!.isEmpty) {
          moveData.comments = [trimmed];
        } else {
          moveData.comments![0] = trimmed;
        }
      }
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
    setState(() {
      notes.forEach((index, note) {
        if (index < 0 || index >= _moveHistory.length) return;
        final moveData = _moveHistory[index];
        final existing =
            (moveData.comments == null || moveData.comments!.isEmpty)
            ? ''
            : moveData.comments!.first;
        if (existing.contains(note)) return;
        final merged = existing.isEmpty ? note : '$existing $note';
        if (moveData.comments == null || moveData.comments!.isEmpty) {
          moveData.comments = [merged];
        } else {
          moveData.comments![0] = merged;
        }
      });
    });
    _notifyCommentsChanged();
  }

  void _toggleNag(int moveIndex, int nagId) {
    if (moveIndex < 0 || moveIndex >= _moveHistory.length) return;
    final moveData = _moveHistory[moveIndex];
    setState(() {
      final next = toggleQualityNag(moveData.nags, nagId);
      moveData.nags = next.isEmpty ? null : next;
    });
    _notifyCommentsChanged();
  }
}
