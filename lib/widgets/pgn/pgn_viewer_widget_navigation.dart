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

  /// Park the mainline cursor on the position matching [targetFen]. Returns
  /// false when the game never reaches it — callers that navigate by position
  /// (a tactic's own ply inside its source game) need to know, because acting
  /// on a miss would drive the cursor against the wrong game entirely.
  bool _jumpToFen(String targetFen) {
    final index = _m.mainlineIndexOfFen(targetFen);
    if (index == null) return false;
    _goToMainLineMove(index);
    return true;
  }

  void _goToMainLineMove(int moveIndex) {
    // Solitaire: the model clamps to the revealed frontier.
    _m.revealedPly = widget.revealedPly;
    if (!_m.goToMainLineMove(moveIndex)) return;
    setState(_clearInlineLine);
    widget.onPositionChanged?.call(_currentPosition);
  }

  void _goToAnalysisNode(MoveNode targetNode, int branchPly) {
    if (!_m.goToAnalysisNode(targetNode, branchPly)) return;
    setState(_clearInlineLine);
    widget.onPositionChanged?.call(_currentPosition);
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
      var nextPly = ply;
      while (nextPly < _moveHistory.length &&
          isNullMoveSan(_moveHistory[nextPly].san)) {
        nextPly++;
      }
      if (!atSolitaireFrontier && nextPly < _moveHistory.length) {
        candidates.add((
          san: _moveHistory[nextPly].san,
          color: AppColors.pgnMove,
          onTap: () => _goToMainLineMove(nextPly + 1),
          emphasized: true,
        ));
      }
      for (final root in _playableNodes(
        _variationsByPly[ply] ?? const <MoveNode>[],
      )) {
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
      for (final child in _playableNodes(_analysisPath.last.children)) {
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

  /// Null-move nodes aren't playable chips; walk through them to the first
  /// real SAN so a ChessBase `Z0` pass still offers `Nf3`.
  Iterable<MoveNode> _playableNodes(Iterable<MoveNode> nodes) sync* {
    for (final n in nodes) {
      if (isNullMoveSan(n.san)) {
        yield* _playableNodes(n.children);
      } else {
        yield n;
      }
    }
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
      padding: const EdgeInsets.only(left: 8, right: 8, top: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Icon(
            Icons.call_split,
            size: 18,
            color: AppColors.onSurfaceMuted,
          ),
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
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: emphasized ? 0.22 : 0.12),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.55), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (shortcutNumber != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  // 0.20 keeps the keycap text ≥4.5:1 over the blended fill.
                  color: color.withValues(alpha: 0.20),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '$shortcutNumber',
                  style: PgnTextStyles.branchChipBadge.copyWith(color: color),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Text(
              san,
              style: PgnTextStyles.branchChip.copyWith(
                color: color,
                fontWeight: emphasized ? FontWeight.w600 : FontWeight.w500,
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
        final next = playSanOrNullMove(pos, _moveHistory[i].san);
        if (next == null) break;
        pos = next;
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
      _m.setInlinePreviewPosition(_inlineBaseIndex, pos);
      _inlineCursor = played;
    });
    widget.onPositionChanged?.call(pos);
  }

  @override
  void _clearInlineLine() {
    _inlineSans = const [];
    _inlineCursor = 0;
    _inlineAnchorFen = null;
  }

  /// From/to squares of the last two half-moves leading to the current
  /// position — mainline, variation, or inline comment-line preview. Hosts
  /// pass this to [ChessBoardWidget.recentMoveSquares] for the subtle
  /// Chessable-style recent-move trail.
  Set<String> _recentMoveSquares() {
    List<String> mainlineSans(int upTo) => [
      for (int i = 0; i < upTo && i < _moveHistory.length; i++)
        _moveHistory[i].san,
    ];

    try {
      if (_inlineActive) {
        final anchorFen = _inlineAnchorFen;
        if (anchorFen != null) {
          return recentMoveTrailSquares(
            Chess.fromSetup(Setup.parseFen(anchorFen)),
            _inlineSans.sublist(0, _inlineCursor),
          );
        }
        return recentMoveTrailSquares(_startPosition, [
          ...mainlineSans(_inlineBaseIndex),
          ..._inlineSans.sublist(0, _inlineCursor),
        ]);
      }
      if (_analysisPath.isNotEmpty) {
        return recentMoveTrailSquares(_startPosition, [
          ...mainlineSans(_activeBranchPly),
          for (final node in _analysisPath) node.san,
        ]);
      }
      return recentMoveTrailSquares(
        _startPosition,
        mainlineSans(_mainLineIndex),
      );
    } catch (_) {
      return const {};
    }
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
