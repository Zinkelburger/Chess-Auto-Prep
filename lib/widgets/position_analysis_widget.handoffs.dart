part of 'position_analysis_widget.dart';

// =====================================================================
// Handoffs: study / puzzle / PGN viewer
// =====================================================================

/// Save-to-study, make-puzzle and open-in-PGN-viewer handoffs, plus the
/// line/tree builders and stats comments they rely on.
mixin _StudyHandoffMixin on _PositionAnalysisWidgetStateBase {
  /// Player stats at [fen] as a human-readable PGN comment, or null.
  @override
  String? _statsCommentFor(String fen) {
    final stats = widget.analysis?.positionStats[normalizeFen(fen)];
    if (stats == null || stats.games == 0) return null;
    final who = widget.playerName ?? 'Player';
    return '$who scored ${stats.winRatePercent.toStringAsFixed(1)}% here '
        '(${stats.wins}-${stats.losses}-${stats.draws} '
        'in ${stats.games} game${stats.games == 1 ? '' : 's'}).';
  }

  String _suggestChapterName(String? fen) {
    final who = widget.playerName ?? 'Analysis';
    final color = widget.playerIsWhite == null
        ? ''
        : (widget.playerIsWhite! ? ' as White' : ' as Black');
    final stats = fen == null
        ? null
        : widget.analysis?.positionStats[normalizeFen(fen)];
    final statsPart = (stats != null && stats.games > 0)
        ? ' — ${stats.winRatePercent.toStringAsFixed(0)}% in '
              '${stats.games} game${stats.games == 1 ? '' : 's'}'
        : '';
    return '$who$color$statsPart';
  }

  /// Single line (root → cursor-line leaf) through [path], comments intact.
  MoveTree _scratchLineTree(TreePath path) {
    final end = _scratchTree.mainlineEndFrom(path);
    final chain = _scratchTree.nodeListAt(end);
    final clone = MoveTree(startingFen: _scratchTree.startingFen);
    var siblings = clone.roots;
    for (final n in chain) {
      final copy = MoveNode(
        san: n.san,
        fen: n.fen,
        comment: n.comment,
        nags: n.nags == null ? null : List.of(n.nags!),
      );
      siblings.add(copy);
      siblings = copy.children;
    }
    return clone;
  }

  /// The line of the player's games leading to [fen], with a stats comment
  /// on the final move.  Null when the position isn't in the opening tree.
  MoveTree? _bookLineTree(String fen) {
    final sans = _openingTreePathFor(fen);
    if (sans == null) return null;
    final tree = MoveTree(startingFen: widget.openingTree!.root.fen);
    var path = TreePath.empty;
    for (final san in sans) {
      final next = tree.addMove(path, san);
      if (next == null) return null;
      path = next;
    }
    final comment = _statsCommentFor(fen);
    if (comment != null && path.isNotEmpty) tree.setComment(path, comment);
    return tree;
  }

  /// "Add Line to Study" (board action bar): saves the line to the current
  /// position — from the Analysis workspace when the position lives there
  /// (keeps the user's own moves and comments), else from the game tree.
  Future<void> _addCurrentLineToStudy() async {
    final fen = _currentFen;
    if (fen == null) return;

    MoveTree? line;
    final anchor = _scratchAnchorFor(fen);
    if (anchor != null && _scratchTree.isNotEmpty) {
      line = _scratchLineTree(anchor);
    }
    if (line == null || line.isEmpty) {
      line = _bookLineTree(fen);
    }
    if (line == null || line.isEmpty) {
      showAppSnackBar(
        context,
        'Could not build a line to this position from the games.',
      );
      return;
    }
    await _saveTreeToStudy(line, _suggestChapterName(fen));
  }

  /// "Save Analysis to Study" (Analysis tab): saves the whole scratch tree —
  /// all variations and comments — as one chapter.
  @override
  Future<void> _addScratchToStudy() async {
    if (_scratchTree.isEmpty) return;
    await _saveTreeToStudy(_scratchTree, _suggestChapterName(_currentFen));
  }

  Future<void> _saveTreeToStudy(
    MoveTree lineTree,
    String suggestedChapter,
  ) async {
    final result = await showDialog<AddToStudyResult>(
      context: context,
      builder: (_) => AddToStudyDialog(initialChapterName: suggestedChapter),
    );
    if (result == null || !mounted) return;

    final study = context.read<StudyController>();
    final appState = context.read<AppState>();
    try {
      final path =
          result.existingPath ??
          await StorageFactory.instance.studyFilePath(result.newStudyName!);
      final pgn = lineTree.toPgn(event: result.chapterName, result: '*');
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

  void _makePuzzleFromPosition() {
    final fen = _currentFen;
    if (fen == null) return;
    context.read<AppState>().switchToPuzzleCreator(seedFen: expandFen(fen));
  }

  void _openGamesInPgnViewer() {
    final path = widget.analysisPgnPath;
    if (path == null) return;
    final fen = _currentFen;
    context.read<AppState>().switchToPgnViewer(
      path: path,
      sliceFen: fen == null ? null : normalizeFen(fen),
    );
  }
}
