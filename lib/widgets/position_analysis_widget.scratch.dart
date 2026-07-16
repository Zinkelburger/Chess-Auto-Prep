part of 'position_analysis_widget.dart';

// =====================================================================
// Analysis tab (scratch tree)
// =====================================================================

/// Scratch-tree behaviour behind the Analysis tab: off-book board moves,
/// engine-line clicks and manual exploration accumulate in [_scratchTree].
mixin _ScratchAnalysisMixin on _PositionAnalysisWidgetStateBase {
  Widget _buildScratchTab() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          alignment: Alignment.centerLeft,
          child: Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.menu_book_outlined, size: 16),
                label: const Text(
                  'Save Analysis to Study',
                  style: TextStyle(fontSize: 12),
                ),
                onPressed: _scratchTree.isEmpty ? null : _addScratchToStudy,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                tooltip: 'Clear Analysis',
                visualDensity: VisualDensity.compact,
                onPressed: _scratchTree.isEmpty ? null : _confirmClearScratch,
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: _scratchTree.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Your analysis workspace.\n\n'
                      'Play moves on the board (moves outside the '
                      'player\'s games land here) or click an engine '
                      'line to build variations, then save them to a study.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(4),
                  child: InteractivePgnEditor(
                    tree: _scratchTree,
                    currentPath: _scratchCursor,
                    onJump: _jumpScratch,
                    onCommentChanged: (path, comment) =>
                        setState(() => _scratchTree.setComment(path, comment)),
                    onDelete: _deleteScratchAt,
                    onPromote: _promoteScratchAt,
                    onMakeMainLine: _makeScratchMainLine,
                    onCopyToClipboard: (text, message) async {
                      await Clipboard.setData(ClipboardData(text: text));
                      if (mounted) showAppSnackBar(context, message);
                    },
                  ),
                ),
        ),
      ],
    );
  }

  /// Jump the scratch cursor and sync the board (and, best-effort, the
  /// opening tree) to that position.
  void _jumpScratch(TreePath path) {
    setState(() => _scratchCursor = path);
    final fen = _scratchTree.fenAt(path);
    widget.openingTree?.navigateToFen(fen);
    _navigateTo(fen);
  }

  void _deleteScratchAt(TreePath path) {
    setState(() {
      // Deleting a sibling shifts variation indices, so re-locate the cursor
      // by SAN afterwards; if the cursor's line was itself deleted, this
      // lands on its deepest surviving ancestor.
      final sanLine = _scratchTree.sanSequenceAt(_scratchCursor);
      _scratchTree.deleteAt(path);
      _reanchorScratchCursor(sanLine);
    });
  }

  void _promoteScratchAt(TreePath path) {
    final sanLine = _scratchTree.sanSequenceAt(_scratchCursor);
    setState(() {
      _scratchTree.promoteVariation(path);
      _reanchorScratchCursor(sanLine);
    });
  }

  /// Recursively promote so [target] lies on the mainline (same algorithm as
  /// StudyController.makeMainLine).
  void _makeScratchMainLine(TreePath target) {
    if (target.isEmpty) return;
    final sanLine = _scratchTree.sanSequenceAt(_scratchCursor);
    setState(() {
      final indices = target.toList();
      for (int depth = 0; depth < indices.length; depth++) {
        if (indices[depth] != 0) {
          _scratchTree.promoteVariation(
            TreePath(indices.sublist(0, depth + 1)),
          );
          indices[depth] = 0;
        }
      }
      _reanchorScratchCursor(sanLine);
    });
  }

  /// After a structural change, re-locate the cursor by replaying its SAN
  /// sequence (paths shift when siblings reorder).
  void _reanchorScratchCursor(List<String> sanLine) {
    var path = TreePath.empty;
    var siblings = _scratchTree.roots;
    for (final san in sanLine) {
      final idx = siblings.indexWhere((n) => n.san == san);
      if (idx == -1) break;
      path = path.child(idx);
      siblings = siblings[idx].children;
    }
    _scratchCursor = path;
  }

  void _confirmClearScratch() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Analysis'),
        content: const Text(
          'Discard all moves in the Analysis tab? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              setState(() {
                _scratchTree = MoveTree();
                _scratchCursor = TreePath.empty;
              });
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  // ── Scratch tree bookkeeping ────────────────────────────────────────

  /// Path of a scratch node matching [fen], preferring the cursor when it
  /// already sits on that position (avoids jumping to a transposition).
  @override
  TreePath? _scratchAnchorFor(String fen) {
    final target = normalizeFen(fen);
    if (normalizeFen(_scratchTree.fenAt(_scratchCursor)) == target) {
      return _scratchCursor;
    }
    if (normalizeFen(_scratchTree.startingFen) == target) {
      return TreePath.empty;
    }
    TreePath? found;
    void walk(List<MoveNode> siblings, TreePath parent) {
      for (var i = 0; i < siblings.length && found == null; i++) {
        final path = parent.child(i);
        if (normalizeFen(siblings[i].fen) == target) {
          found = path;
          return;
        }
        walk(siblings[i].children, path);
      }
    }

    walk(_scratchTree.roots, TreePath.empty);
    return found;
  }

  /// SAN path from the game start to [fen], derived from the opening tree.
  @override
  List<String>? _openingTreePathFor(String fen) {
    final tree = widget.openingTree;
    if (tree == null) return null;
    final target = normalizeFen(fen);
    if (normalizeFen(tree.currentNode.fen) == target) {
      return tree.currentNode.getMovePath();
    }
    if (normalizeFen(tree.root.fen) == target) return const [];
    final nodes = tree.fenToNodes[target];
    if (nodes != null && nodes.isNotEmpty) return nodes.first.getMovePath();
    return null;
  }

  /// Ensure [fen] is reachable in the scratch tree and return its path:
  /// reuses an existing node, else seeds the book line leading to the
  /// position (tagging the leaf with the player's stats), else — for an
  /// empty tree — re-roots at the position itself.  Returns null when the
  /// position can't be attached without discarding existing analysis.
  TreePath? _ensureScratchPathForFen(String fen) {
    final anchor = _scratchAnchorFor(fen);
    if (anchor != null) return anchor;

    final sans = _openingTreePathFor(fen);
    if (sans != null) {
      final startFen = widget.openingTree!.root.fen;
      if (_scratchTree.isEmpty &&
          normalizeFen(_scratchTree.startingFen) != normalizeFen(startFen)) {
        _scratchTree = MoveTree(startingFen: startFen);
      }
      // Only replay the book SANs when the roots actually match — grafting a
      // from-the-start line onto a re-rooted (mid-game) tree could splice in
      // moves that happen to be legal but mean something entirely different.
      var ok = normalizeFen(_scratchTree.startingFen) == normalizeFen(startFen);
      var path = TreePath.empty;
      if (ok) {
        for (final san in sans) {
          final next = _scratchTree.addMove(path, san);
          if (next == null) {
            ok = false;
            break;
          }
          path = next;
        }
      }
      if (ok) {
        final node = path.isEmpty ? null : _scratchTree.nodeAt(path);
        final comment = _statsCommentFor(fen);
        if (node != null &&
            comment != null &&
            (node.comment == null || node.comment!.isEmpty)) {
          node.comment = comment;
        }
        return path;
      }
    }

    if (_scratchTree.isEmpty) {
      _scratchTree = MoveTree(startingFen: expandFen(fen));
      return TreePath.empty;
    }
    return null;
  }

  /// Record a board move into the scratch tree (creates the book prefix on
  /// demand).  No-op when the pre-move position can't be attached.
  @override
  void _recordScratchMove(String preFen, String san) {
    final parent = _ensureScratchPathForFen(preFen);
    if (parent == null) return;
    final path = _scratchTree.addMove(parent, san);
    if (path == null) return;
    setState(() => _scratchCursor = path);
  }

  /// Engine bar: clicking a PV move plays the line into the Analysis tab.
  void _onEngineLineTapped(List<String> sanMoves, int clickedIndex) {
    final fen = _currentFen ?? _startingPosition.fen;
    final seeded = _ensureScratchPathForFen(fen);
    if (seeded == null) {
      showAppSnackBar(
        context,
        'Could not add the engine line: the position is not in the '
        'Analysis tab.',
      );
      return;
    }
    TreePath path = seeded;
    for (var i = 0; i <= clickedIndex && i < sanMoves.length; i++) {
      final next = _scratchTree.addMove(path, sanMoves[i]);
      if (next == null) break;
      path = next;
    }
    setState(() => _scratchCursor = path);
    final newFen = _scratchTree.fenAt(path);
    widget.openingTree?.navigateToFen(newFen);
    _navigateTo(newFen);
    _tabController.animateTo(_kAnalysisTabIndex);
  }
}
