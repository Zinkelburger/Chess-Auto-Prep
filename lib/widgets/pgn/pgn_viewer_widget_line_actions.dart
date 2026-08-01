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
    String? hint,
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
          if (hint != null) ...[const SizedBox(width: 8), InfoHint(hint)],
        ],
      ),
    );
  }

  /// Shared hint for the two "Add line to study…" context-menu items, so the
  /// wording cannot drift between the move and variation menus.
  static const String _addLineToStudyHint =
      'Saves this line — the moves up to here — as a chapter of a study.\n'
      'Review or train it as-is, or flag a move in the study with\n'
      '"Puzzle starts here" to train just that part of the line.';

  void _showMoveContextMenu(int moveIndex, Offset globalPosition) {
    final line = _moveHistory.sublist(0, moveIndex + 1);

    showMenu<String>(
      context: context,
      position: _menuPosition(globalPosition),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      items: [
        _menuItem('copy_line', Icons.copy_outlined, 'Copy line PGN'),
        _menuItem(
          'add_to_study',
          Icons.menu_book_outlined,
          'Add line to study…',
          hint: _addLineToStudyHint,
        ),
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
        _menuItem(
          'add_to_study',
          Icons.menu_book_outlined,
          'Add line to study…',
          hint: _addLineToStudyHint,
        ),
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
  List<PgnNodeData>? _lineToVariationNode(MoveNode node, int branchPly) =>
      _m.lineToVariationNode(node, branchPly);

  /// Serialize a single line to PGN: `[FEN]`/`[SetUp]` headers when the game
  /// starts from a custom position, then numbered movetext (comments and
  /// NAGs of the source moves included).
  String _buildLinePgn(List<PgnNodeData> line) => _m.buildLinePgn(line);

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
    await runAddToStudyFlow(
      context,
      suggestedChapterName: _suggestChapterName(line),
      buildPgn: (_) => pgn,
      viewSanLine: [for (final data in line) data.san],
    );
  }

  @override
  void _notifyCommentsChanged() {
    if (widget.onCommentsChanged == null || _moveHistory.isEmpty) return;
    // The model serializes mainline + saved sidelines (comments and NAGs
    // intact, ephemeral nodes excluded), headers stripped for splicing back
    // under the game's own headers.
    final movetext = _m.buildAnnotatedMovetext();
    _lastEmittedMovetext = _normalizeMovetext(movetext);
    widget.onCommentsChanged!(movetext);
  }
}
