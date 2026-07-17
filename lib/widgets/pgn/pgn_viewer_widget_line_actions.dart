// Whole-line actions for the PGN viewer: move / variation context menus,
// copy-line-PGN and add-line-to-study, and serialization of the annotated
// movetext back to PGN for persistence. Part of pgn_viewer_widget.dart;
// mixed into _PgnViewerWidgetState.
part of '../pgn_viewer_widget.dart';

String _normalizeMovetext(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

mixin _PgnViewerLineActions on _PgnViewerWidgetStateBase {
  /// The last movetext this widget emitted via [onCommentsChanged] (whitespace-
  /// normalized). Used so that when our own persisted edit flows back in as an
  /// updated `pgnText`, `didUpdateWidget` recognizes it and skips the reload
  /// that would otherwise reset the cursor to the start of the game.
  String? _lastEmittedMovetext;

  RelativeRect _menuPosition(Offset globalPosition) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    return RelativeRect.fromRect(
      Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 0, 0),
      Offset.zero & overlay.size,
    );
  }

  static PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    bool enabled = true,
    Color? color,
  }) {
    final effectiveColor = enabled ? color : AppColors.onSurfaceDisabled;
    return PopupMenuItem(
      value: value,
      enabled: enabled,
      child: Row(
        children: [
          Icon(icon, size: 18, color: effectiveColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: effectiveColor != null
                  ? TextStyle(color: effectiveColor)
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  void _showMoveContextMenu(int moveIndex, Offset globalPosition) {
    final line = _moveHistory.sublist(0, moveIndex + 1);

    showMenu<String>(
      context: context,
      position: _menuPosition(globalPosition),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        _menuItem('copy_line', Icons.copy_outlined, 'Copy line PGN'),
        _menuItem('add_to_study', Icons.menu_book_outlined, 'Add to study…'),
        // In amend mode the bottom panel handles comments/glyphs; the inline
        // editor stays for quick comments outside amend mode.
        if (!widget.editMode && widget.onCommentsChanged != null) ...[
          const PopupMenuDivider(),
          _menuItem('comment', Icons.comment_outlined, 'Comment'),
        ],
      ],
    ).then((action) {
      if (action == 'copy_line') {
        _copyLinePgn(line);
      } else if (action == 'add_to_study') {
        _addLineToStudy(line);
      } else if (action == 'comment') {
        _startEditingComment(moveIndex);
      }
    });
  }

  void _showVariationContextMenu(
    MoveNode node,
    int branchPly,
    Offset globalPosition,
  ) {
    final line = _lineToVariationNode(node, branchPly);
    if (line == null) return;

    showMenu<String>(
      context: context,
      position: _menuPosition(globalPosition),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        _menuItem('copy_line', Icons.copy_outlined, 'Copy line PGN'),
        _menuItem('add_to_study', Icons.menu_book_outlined, 'Add to study…'),
        if (node.isEphemeral) ...[
          const PopupMenuDivider(),
          _menuItem(
            'delete',
            Icons.delete_outline,
            'Delete variation',
            color: AppColors.danger,
          ),
          _menuItem('clear_all', Icons.clear_all, 'Clear all analysis'),
        ],
      ],
    ).then((action) {
      if (action == 'copy_line') {
        _copyLinePgn(line);
      } else if (action == 'add_to_study') {
        _addLineToStudy(line);
      } else if (action == 'delete') {
        _deleteAnalysisNode(node.id);
      } else if (action == 'clear_all') {
        _clearAnalysis();
      }
    });
  }

  // ── Copy line / add line to study ──

  /// Move data from the game start to [node]: the mainline up to the branch
  /// point, then the variation path. Null when the node can't be located.
  List<PgnNodeData>? _lineToVariationNode(MoveNode node, int branchPly) {
    final roots = _variationsByPly[branchPly];
    if (roots == null) return null;
    final path = _findPathToNode(node, roots);
    if (path == null) return null;
    return [
      for (int i = 0; i < branchPly && i < _moveHistory.length; i++)
        _moveHistory[i],
      for (final n in path)
        PgnNodeData(
          san: n.san,
          comments: (n.comment != null && n.comment!.trim().isNotEmpty)
              ? [n.comment!.trim()]
              : null,
          nags: (n.nags != null && n.nags!.isNotEmpty)
              ? List<int>.from(n.nags!)
              : null,
        ),
    ];
  }

  /// Serialize a single line to PGN: `[FEN]`/`[SetUp]` headers when the game
  /// starts from a custom position, then numbered movetext (comments and
  /// NAGs of the source moves included).
  String _buildLinePgn(List<PgnNodeData> line) {
    final headers = <String, String>{};
    final fen = _game?.headers['FEN'];
    if (fen != null && fen.isNotEmpty) {
      headers['FEN'] = fen;
      headers['SetUp'] = '1';
    }
    final root = PgnNode<PgnNodeData>();
    PgnNode<PgnNodeData> parent = root;
    for (final data in line) {
      final child = PgnChildNode<PgnNodeData>(data);
      parent.children.add(child);
      parent = child;
    }
    return PgnGame<PgnNodeData>(
      headers: headers,
      moves: root,
      comments: const [],
    ).makePgn().trim();
  }

  String _suggestChapterName(List<PgnNodeData> line) {
    final coords = coordsAtPly(
      ply: line.length - 1,
      startFullmoves: _startPosition.fullmoves,
      startWhiteToMove: _startPosition.turn == Side.white,
    );
    final moveLabel =
        '${coords.moveNumber}${coords.isWhite ? '.' : '...'}${line.last.san}';
    final white = _game?.headers['White'] ?? '';
    final black = _game?.headers['Black'] ?? '';
    if (!_isBlankHeader(white) && !_isBlankHeader(black)) {
      return '$white – $black: $moveLabel';
    }
    return 'Line to $moveLabel';
  }

  Future<void> _copyLinePgn(List<PgnNodeData> line) async {
    if (line.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _buildLinePgn(line)));
    if (!mounted) return;
    showAppSnackBar(context, 'Line copied to clipboard');
  }

  Future<void> _addLineToStudy(List<PgnNodeData> line) async {
    if (line.isEmpty) return;
    final pgn = _buildLinePgn(line);
    final result = await showDialog<AddToStudyResult>(
      context: context,
      builder: (_) =>
          AddToStudyDialog(initialChapterName: _suggestChapterName(line)),
    );
    if (result == null || !mounted) return;

    final study = context.read<StudyController>();
    final appState = context.read<AppState>();
    try {
      final path =
          result.existingPath ??
          await StorageFactory.instance.studyFilePath(result.newStudyName!);
      await study.addChapterToStudyFile(path, result.chapterName, pgn);
      if (!mounted) return;
      showAppSnackBar(
        context,
        'Added "${result.chapterName}" to ${result.studyName}',
        actionLabel: 'Open',
        onAction: () async {
          await study.openStudy(path);
          study.selectChapter(study.doc.chapters.length - 1);
          appState.setMode(AppMode.study);
        },
      );
    } catch (e) {
      debugPrint('Add line to study failed: $e');
      if (mounted) {
        showAppSnackBar(context, 'Failed to add line to study.', isError: true);
      }
    }
  }

  @override
  void _notifyCommentsChanged() {
    if (widget.onCommentsChanged == null || _moveHistory.isEmpty) return;
    final movetext = _buildAnnotatedMovetext();
    _lastEmittedMovetext = _normalizeMovetext(movetext);
    widget.onCommentsChanged!(movetext);
  }

  /// Serialize the current mainline *and* every saved sideline variation (with
  /// their comments and NAGs) back to PGN movetext. Uses dartchess'
  /// [PgnGame.makePgn] — which handles variations, NAGs, and move numbering for
  /// games that start from a custom FEN — then strips the header block so the
  /// caller can splice it back under the game's existing headers.
  ///
  /// Ephemeral (scratch) analysis nodes are excluded; only permanent edits are
  /// written.
  String _buildAnnotatedMovetext() {
    final headers = <String, String>{};
    final fen = _game?.headers['FEN'];
    if (fen != null && fen.isNotEmpty) headers['FEN'] = fen;
    final result = _game?.headers['Result'];
    if (result != null && result.isNotEmpty) headers['Result'] = result;

    final serializable = PgnGame<PgnNodeData>(
      headers: headers,
      moves: _buildPgnTree(),
      comments: _game?.comments ?? const [],
    );
    return _stripHeaders(serializable.makePgn()).trim();
  }

  /// Rebuild a dartchess move tree from the flat mainline [_moveHistory] plus
  /// the per-ply sidelines in [_variationsByPly]. Inverts [extractPgnVariations]:
  /// sidelines keyed at ply `p` are siblings of the mainline move at index `p`
  /// (i.e. `children[1..]` of the same parent). Ephemeral nodes are skipped.
  PgnNode<PgnNodeData> _buildPgnTree() {
    final root = PgnNode<PgnNodeData>();
    PgnNode<PgnNodeData> parent = root;

    void addSidelines(int ply) {
      final roots = _variationsByPly[ply];
      if (roots == null) return;
      for (final sideline in roots) {
        if (sideline.isEphemeral) continue;
        parent.children.add(_moveNodeToPgnChild(sideline));
      }
    }

    for (int i = 0; i < _moveHistory.length; i++) {
      final mainChild = PgnChildNode<PgnNodeData>(_moveHistory[i]);
      parent.children.add(mainChild); // index 0 = mainline continuation
      addSidelines(i); // alternatives to _moveHistory[i], sharing `parent`
      parent = mainChild;
    }
    // Sidelines branching after the final mainline move (user-added only).
    addSidelines(_moveHistory.length);
    return root;
  }

  PgnChildNode<PgnNodeData> _moveNodeToPgnChild(MoveNode node) {
    final hasComment = node.comment != null && node.comment!.trim().isNotEmpty;
    final hasNags = node.nags != null && node.nags!.isNotEmpty;
    final child = PgnChildNode<PgnNodeData>(
      PgnNodeData(
        san: node.san,
        comments: hasComment ? [node.comment!.trim()] : null,
        nags: hasNags ? List<int>.from(node.nags!) : null,
      ),
    );
    for (final c in node.children) {
      if (c.isEphemeral) continue;
      child.children.add(_moveNodeToPgnChild(c));
    }
    return child;
  }
}
