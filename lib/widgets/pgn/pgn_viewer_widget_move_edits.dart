// Adding user moves to the PGN viewer — permanent edits in edit mode,
// ephemeral scratch analysis otherwise — plus clearing / deleting analysis
// nodes. Part of pgn_viewer_widget.dart; mixed into _PgnViewerWidgetState.
part of '../pgn_viewer_widget.dart';

mixin _PgnViewerMoveEdits on _PgnViewerWidgetStateBase {
  // ── Adding user moves ──

  void _addAnalysisMove(String san) {
    final parsedMove = _currentPosition.parseSan(san);
    if (parsedMove == null) return;

    Position newPos;
    try {
      newPos = _currentPosition.play(parsedMove);
    } catch (_) {
      return;
    }
    final fenAfter = newPos.fen;

    // In edit mode, moves become permanent edits saved to disk: extending the
    // mainline at its end, or adding a real (non-ephemeral) sideline elsewhere.
    // Outside edit mode, moves are ephemeral scratch analysis (never saved).
    final editing =
        widget.editMode &&
        widget.onCommentsChanged != null &&
        widget.revealedPly == null;

    // Edit mode at the end of the mainline: extend the mainline itself rather
    // than start a sideline. Excluded while an inline comment-preview is active:
    // there _currentPosition is the preview board (not the mainline tail), so
    // appending `san` here would splice a move that is illegal from the real
    // last position into the persisted mainline.
    if (editing &&
        _analysisPath.isEmpty &&
        !_inlineActive &&
        _mainLineIndex == _moveHistory.length) {
      setState(() {
        _clearInlineLine();
        _moveHistory.add(PgnNodeData(san: san));
        _mainLineIndex = _moveHistory.length;
        _currentPosition = newPos;
      });
      _notifyCommentsChanged();
      widget.onPositionChanged?.call(newPos);
      return;
    }

    setState(() {
      _clearInlineLine();
      if (_analysisPath.isEmpty) {
        // Starting new variation from mainline
        final ply = _mainLineIndex;
        final roots = _variationsByPly.putIfAbsent(ply, () => []);

        // Check if this move already exists
        MoveNode? existing;
        for (final root in roots) {
          if (root.san == san) {
            existing = root;
            break;
          }
        }

        if (existing != null) {
          _analysisPath = [existing];
        } else {
          final newNode = MoveNode(
            san: san,
            fen: fenAfter,
            isEphemeral: !editing,
          );
          roots.add(newNode);
          _analysisPath = [newNode];
        }
        _activeBranchPly = ply;
      } else {
        // Extending current variation
        final current = _analysisPath.last;
        final (node, _) = current.addChild(
          san,
          fenAfter,
          isEphemeral: !editing,
        );
        // A permanent move under ephemeral ancestors would be dropped by the
        // serializer — promote the whole line to saved.
        if (editing) _promoteNodeLineage(current);
        _analysisPath = [..._analysisPath, node];
      }
      _currentPosition = newPos;
    });
    if (editing) _notifyCommentsChanged();
    widget.onPositionChanged?.call(newPos);
  }

  /// Add [san] as an ephemeral variation root at the current mainline ply
  /// without navigating into it — the board stays on the pre-move position.
  /// Used by solitaire to show wrong attempts as live variations.
  void _recordVariationMove(String san) {
    if (_analysisPath.isNotEmpty || _inlineActive) return;
    final parsedMove = _currentPosition.parseSan(san);
    if (parsedMove == null) return;
    final Position newPos;
    try {
      newPos = _currentPosition.play(parsedMove);
    } catch (_) {
      return;
    }
    final ply = _mainLineIndex;
    final roots = _variationsByPly.putIfAbsent(ply, () => []);
    if (roots.any((r) => r.san == san)) return;
    setState(() {
      roots.add(MoveNode(san: san, fen: newPos.fen, isEphemeral: true));
    });
  }

  // ── Clear / delete ──

  @override
  void _clearAnalysis() {
    setState(() {
      // Remove only ephemeral nodes from all plies
      final keysToRemove = <int>[];
      for (final entry in _variationsByPly.entries) {
        entry.value.removeWhere((n) => n.isEphemeral);
        // Also remove ephemeral children from PGN nodes
        for (final root in entry.value) {
          _removeEphemeralChildren(root);
        }
        if (entry.value.isEmpty) keysToRemove.add(entry.key);
      }
      for (final k in keysToRemove) {
        _variationsByPly.remove(k);
      }
      _analysisPath = [];
      _activeBranchPly = -1;
      _clearInlineLine();
    });
  }

  void _removeEphemeralChildren(MoveNode node) {
    node.children.removeWhere((c) => c.isEphemeral);
    for (final child in node.children) {
      _removeEphemeralChildren(child);
    }
  }

  bool _subtreeHasEphemeral(MoveNode node) {
    if (node.isEphemeral) return true;
    for (final child in node.children) {
      if (_subtreeHasEphemeral(child)) return true;
    }
    return false;
  }

  @override
  void _deleteAnalysisNode(int nodeId) {
    setState(() {
      for (final entry in _variationsByPly.entries) {
        final ply = entry.key;
        final roots = entry.value;

        final lengthBefore = roots.length;
        roots.removeWhere((n) => n.id == nodeId);
        if (roots.length < lengthBefore) {
          // If current path includes the deleted node, exit variation
          if (_activeBranchPly == ply && _analysisPath.isNotEmpty) {
            _analysisPath = [];
            _activeBranchPly = -1;
          }
          return;
        }

        // Search deeper
        for (final root in roots) {
          if (_removeNodeRecursive(root.children, nodeId)) {
            final idx = _analysisPath.indexWhere((n) => n.id == nodeId);
            if (idx != -1) {
              if (idx == 0) {
                _analysisPath = [];
                _activeBranchPly = -1;
              } else {
                _analysisPath = _analysisPath.sublist(0, idx);
                _goToAnalysisNode(_analysisPath.last, _activeBranchPly);
              }
            }
            return;
          }
        }
      }
    });
  }

  bool _removeNodeRecursive(List<MoveNode> nodes, int targetId) {
    for (final node in nodes) {
      if (node.children.any((c) => c.id == targetId)) {
        node.children.removeWhere((c) => c.id == targetId);
        return true;
      }
      if (_removeNodeRecursive(node.children, targetId)) return true;
    }
    return false;
  }
}
