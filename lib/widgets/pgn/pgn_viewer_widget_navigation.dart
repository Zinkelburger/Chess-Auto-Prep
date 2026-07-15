// Navigation for the PGN viewer: mainline / variation / inline-comment-line
// cursor movement, the branch-candidate fork bar, and back/forward guards.
// Part of pgn_viewer_widget.dart; mixed into _PgnViewerWidgetState.
part of '../pgn_viewer_widget.dart';

mixin _PgnViewerNavigation on _PgnViewerWidgetStateBase {
  // ── Navigation ──

  void _jumpToMove(int moveNumber, bool isWhiteToPlay) {
    if (_moveHistory.isEmpty) return;
    int targetPly = (moveNumber - 1) * 2;
    if (!isWhiteToPlay) targetPly += 1;
    targetPly = targetPly.clamp(0, _moveHistory.length);
    _goToMainLineMove(targetPly);
  }

  void _jumpToFen(String targetFen) {
    if (_moveHistory.isEmpty) return;
    final target = normalizeFen(targetFen);
    Position pos = _startPosition;
    for (int i = 0; i < _moveHistory.length; i++) {
      final san = _moveHistory[i].san;
      if (san == '--') continue;
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
      if (normalizeFen(pos.fen) == target) {
        _goToMainLineMove(i + 1);
        return;
      }
    }
  }

  void _goToMainLineMove(int moveIndex) {
    // Solitaire: never walk the board past the revealed frontier.
    if (widget.revealedPly != null && moveIndex > widget.revealedPly!) {
      moveIndex = widget.revealedPly!;
    }
    if (moveIndex < 0 || moveIndex > _moveHistory.length) return;
    Position pos = _startPosition;
    for (int i = 0; i < moveIndex; i++) {
      final san = _moveHistory[i].san;
      if (san == '--') continue;
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
    }
    setState(() {
      _mainLineIndex = moveIndex;
      _currentPosition = pos;
      _analysisPath = [];
      _activeBranchPly = -1;
      _clearInlineLine();
    });
    widget.onPositionChanged?.call(pos);
  }

  @override
  void _goToAnalysisNode(MoveNode targetNode, int branchPly) {
    final roots = _variationsByPly[branchPly];
    if (roots == null) return;

    final path = _findPathToNode(targetNode, roots);
    if (path == null) return;

    Position pos = _startPosition;
    for (int i = 0; i < branchPly; i++) {
      final san = _moveHistory[i].san;
      if (san == '--') continue;
      final move = pos.parseSan(san);
      if (move == null) break;
      pos = pos.play(move);
    }
    for (final node in path) {
      if (node.san == '--') continue;
      final move = pos.parseSan(node.san);
      if (move == null) break;
      pos = pos.play(move);
    }

    setState(() {
      _mainLineIndex = branchPly;
      _activeBranchPly = branchPly;
      _currentPosition = pos;
      _analysisPath = path;
      _clearInlineLine();
    });
    widget.onPositionChanged?.call(pos);
  }

  @override
  List<MoveNode>? _findPathToNode(MoveNode target, List<MoveNode> roots) {
    for (final root in roots) {
      final path = _findPathRecursive(root, target, []);
      if (path != null) return path;
    }
    return null;
  }

  List<MoveNode>? _findPathRecursive(
    MoveNode current,
    MoveNode target,
    List<MoveNode> pathSoFar,
  ) {
    final newPath = [...pathSoFar, current];
    if (current.id == target.id) return newPath;
    for (final child in current.children) {
      final result = _findPathRecursive(child, target, newPath);
      if (result != null) return result;
    }
    return null;
  }

  void _goToStart() {
    _goToMainLineMove(0);
  }

  /// True when navigation is currently off the mainline — inside a saved /
  /// analysis variation or an inline comment-line preview.
  bool get _isInVariation => _analysisPath.isNotEmpty || _inlineActive;

  /// Jump from the current variation (or inline preview) back to the mainline,
  /// landing on the move where the current line branched off.
  void _returnToMainline() {
    int target;
    if (_analysisPath.isNotEmpty) {
      target = _activeBranchPly >= 0 ? _activeBranchPly : _mainLineIndex;
    } else if (_inlineActive) {
      target = _inlineBaseIndex;
    } else {
      return;
    }
    _goToMainLineMove(target.clamp(0, _moveHistory.length));
  }

  /// The continuation candidates at the current position, in the order the
  /// fork bar shows them (mainline continuation first). Shared by the chip
  /// rendering and the 1–9 keyboard shortcuts so both always agree.
  List<({String san, Color color, VoidCallback onTap, bool emphasized})>
  _branchCandidates() {
    final candidates =
        <({String san, Color color, VoidCallback onTap, bool emphasized})>[];
    if (_analysisPath.isEmpty && !_inlineActive) {
      // On the mainline: the next mainline move + any sidelines branching here.
      // In solitaire the frontier ply is still being guessed: its mainline
      // move and the source game's alternatives stay hidden there.
      final ply = _mainLineIndex;
      final atSolitaireFrontier =
          widget.revealedPly != null && ply >= widget.revealedPly!;
      if (!atSolitaireFrontier &&
          ply < _moveHistory.length &&
          _moveHistory[ply].san != '--') {
        candidates.add((
          san: _moveHistory[ply].san,
          color: AppColors.pgnMainLine,
          onTap: () => _goToMainLineMove(ply + 1),
          emphasized: true,
        ));
      }
      for (final root in _variationsByPly[ply] ?? const <MoveNode>[]) {
        if (root.san == '--') continue;
        if (atSolitaireFrontier && !root.isEphemeral) continue;
        candidates.add((
          san: root.san,
          color: root.isEphemeral
              ? AppColors.pgnEphemeralMove
              : AppColors.pgnVariation,
          onTap: () => _goToAnalysisNode(root, ply),
          emphasized: false,
        ));
      }
    } else if (_analysisPath.isNotEmpty) {
      // Inside a variation: the children of the current node.
      for (final child in _analysisPath.last.children) {
        if (child.san == '--') continue;
        candidates.add((
          san: child.san,
          color: child.isEphemeral
              ? AppColors.pgnEphemeralMove
              : AppColors.pgnVariation,
          onTap: () => _goToAnalysisNode(child, _activeBranchPly),
          emphasized: false,
        ));
      }
    }
    return candidates;
  }

  /// The moves that continue from the current position, as tappable chips.
  /// Returns null unless there's a genuine branch (≥2 options) so the bar stays
  /// unobtrusive on linear lines. Mirrors Lichess' inline branch picker.
  /// Each chip carries a keycap badge; keys 1–9 play the matching candidate.
  Widget? _buildBranchChips() {
    final candidates = _branchCandidates();
    if (candidates.length < 2) return null;
    final chips = <Widget>[
      for (final (i, c) in candidates.indexed)
        _branchChip(
          c.san,
          c.color,
          c.onTap,
          emphasized: c.emphasized,
          shortcutNumber: i < 9 ? i + 1 : null,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(left: 8, right: 8, top: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Icon(Icons.call_split, size: 13, color: AppColors.onSurfaceDim),
          ...chips,
        ],
      ),
    );
  }

  Widget _branchChip(
    String san,
    Color color,
    VoidCallback onTap, {
    bool emphasized = false,
    int? shortcutNumber,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: emphasized ? 0.20 : 0.12),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (shortcutNumber != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 0.5,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  '$shortcutNumber',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10.5,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 5),
            ],
            Text(
              san,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                color: color,
                fontWeight: emphasized ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _goBack() {
    if (_inlineActive) {
      _setInlineCursor(_inlineCursor - 1);
      return;
    }
    if (_analysisPath.isNotEmpty) {
      if (_analysisPath.length > 1) {
        final parentPath = _analysisPath.sublist(0, _analysisPath.length - 1);
        _goToAnalysisNode(parentPath.last, _activeBranchPly);
      } else {
        _goToMainLineMove(_activeBranchPly);
      }
    } else if (_mainLineIndex > 0) {
      _goToMainLineMove(_mainLineIndex - 1);
    }
  }

  void _goForward() {
    if (_inlineActive) {
      if (_inlineCursor < _inlineSans.length) {
        _setInlineCursor(_inlineCursor + 1);
      }
      return;
    }
    if (_analysisPath.isNotEmpty) {
      final current = _analysisPath.last;
      if (current.children.isNotEmpty) {
        _goToAnalysisNode(current.children.first, _activeBranchPly);
      }
    } else if (_mainLineIndex < _moveHistory.length) {
      _goToMainLineMove(_mainLineIndex + 1);
    }
  }

  void _goToEnd() {
    if (_inlineActive) {
      _setInlineCursor(_inlineSans.length);
      return;
    }
    if (_analysisPath.isNotEmpty) {
      MoveNode current = _analysisPath.last;
      while (current.children.isNotEmpty) {
        current = current.children.first;
      }
      _goToAnalysisNode(current, _activeBranchPly);
    } else {
      _goToMainLineMove(_moveHistory.length);
    }
  }

  void _onMainLineMoveClicked(int moveIndex) {
    _goToMainLineMove(moveIndex + 1);
  }

  /// Begin previewing an inline analysis line embedded in a comment. [sans] is
  /// the run's full move list (first move is [moveNumber]/[isWhite]); the board
  /// steps to the move at [clickedIndex]. Unlike a variation, this does NOT add
  /// anything to the move tree — it just walks the board through the line, so
  /// the comment keeps its rendering and the arrows step along the line.
  void _playInlineLine(
    int moveNumber,
    bool isWhite,
    List<String> sans,
    int clickedIndex, {
    String? anchorFen,
  }) {
    // FEN-anchored lines start from the FEN, not a mainline position; keep the
    // mainline highlight where the user is so exiting returns there. Otherwise
    // locate the branch point by move number as before.
    final baseIndex = anchorFen != null
        ? _mainLineIndex
        : plyBeforeMove(
            moveNumber: moveNumber,
            isWhite: isWhite,
            startFullmoves: _startPosition.fullmoves,
            startWhiteToMove: _startPosition.turn == Side.white,
          ).clamp(0, _moveHistory.length);
    // Drop any ephemeral variation moves so we don't leave a stale sideline.
    _clearAnalysis();
    _inlineBaseIndex = baseIndex;
    _inlineAnchorFen = anchorFen;
    _inlineSans = sans;
    _inlineFirstMoveNumber = moveNumber;
    _inlineFirstIsWhite = isWhite;
    _setInlineCursor(clickedIndex + 1);
  }

  /// Move the inline-preview cursor to [cursor] moves played and update the
  /// board. A cursor of 0 (or below) exits preview back to the base position.
  void _setInlineCursor(int cursor) {
    cursor = cursor.clamp(0, _inlineSans.length);
    if (cursor <= 0) {
      _clearInlineLine();
      _goToMainLineMove(_inlineBaseIndex);
      return;
    }
    // Establish the base position: a comment FEN when anchored, otherwise the
    // mainline replayed up to the branch point. Then play the inline moves.
    Position pos;
    final anchorFen = _inlineAnchorFen;
    if (anchorFen != null) {
      try {
        pos = Chess.fromSetup(Setup.parseFen(anchorFen));
      } catch (_) {
        _clearInlineLine();
        _goToMainLineMove(_inlineBaseIndex);
        return;
      }
    } else {
      pos = _startPosition;
      for (int i = 0; i < _inlineBaseIndex; i++) {
        final san = _moveHistory[i].san;
        if (san == '--') continue;
        final m = pos.parseSan(san);
        if (m == null) break;
        pos = pos.play(m);
      }
    }
    int played = 0;
    for (int i = 0; i < cursor; i++) {
      final m = pos.parseSan(_inlineSans[i]);
      if (m == null) break;
      pos = pos.play(m);
      played++;
    }
    if (!mounted) return;
    setState(() {
      _mainLineIndex = _inlineBaseIndex;
      _analysisPath = [];
      _activeBranchPly = -1;
      _inlineCursor = played;
      _currentPosition = pos;
    });
    widget.onPositionChanged?.call(pos);
  }

  @override
  void _clearInlineLine() {
    _inlineSans = const [];
    _inlineCursor = 0;
    _inlineAnchorFen = null;
  }

  bool get _canGoBack {
    return _inlineActive || _analysisPath.isNotEmpty || _mainLineIndex > 0;
  }

  bool get _canGoForward {
    if (_inlineActive) return _inlineCursor < _inlineSans.length;
    if (_analysisPath.isNotEmpty && _analysisPath.last.children.isNotEmpty) {
      return true;
    }
    final mainLimit = widget.revealedPly != null
        ? widget.revealedPly!.clamp(0, _moveHistory.length)
        : _moveHistory.length;
    if (_analysisPath.isEmpty && _mainLineIndex < mainLimit) {
      return true;
    }
    return false;
  }
}
