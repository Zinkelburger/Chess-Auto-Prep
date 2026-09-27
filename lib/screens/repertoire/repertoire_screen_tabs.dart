// Tab-content builders for the repertoire screen: the PGN / Lines / Tree tab
// bodies and the bottom pane's jobs, findings, and lines content. Split out
// of repertoire_screen.dart (pure code motion).
part of '../repertoire_screen.dart';

mixin _RepertoireTabContent
    on _RepertoireScreenStateBase, _RepertoireSessionHandlers {
  Widget? _buildTrapNavigation() {
    final trapIndex = _trapSession.index;
    if (trapIndex == null) return null;
    return TrapNavigationButtons(
      trapIndex: trapIndex,
      controller: _controller,
      onStartTour: ({TrapLineInfo? startTrap}) =>
          _trapSession.openTour(startTrap: startTrap),
      tourActive: _trapSession.tourVisible,
    );
  }

  /// The chapters-and-lines surface (compact: second tools tab; wide: the
  /// outline column): the outline, or the metrics browser when asked for.
  Widget _buildSecondTabContent() {
    return _showLineMetrics ? _buildLineMetricsView() : _buildOutlinePanel();
  }

  /// The old lines browser (coverage, ease, coherence…) with a way back.
  Widget _buildLineMetricsView() {
    return Column(
      children: [
        SizedBox(
          height: 32,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 16),
                tooltip: 'Back to chapters',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                onPressed: () => setState(() => _showLineMetrics = false),
              ),
              const Text(
                'Line metrics',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              if (!_isCompactLayout)
                IconButton(
                  icon: const Icon(Icons.keyboard_double_arrow_left, size: 16),
                  tooltip: 'Hide chapters',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  onPressed: () => _layout.setOutlinePanelCollapsed(true),
                ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildLinesTabContent()),
      ],
    );
  }

  Widget _buildOutlinePanel() {
    final selected = _controller.document.selectedPgnLine;
    final chapterPath = _controller.document.currentRepertoire?.filePath;
    return Column(
      children: [
        Expanded(
          child: RepertoireOutlinePanel(
            controller: _outline,
            currentMoves: _controller.board.currentMoveSequence,
            selectedLine: selected == null || chapterPath == null
                ? null
                : (chapterPath: chapterPath, gameIndex: selected.gameIndex),
            onOpenChapter: (path) => unawaited(_openChapterPath(path)),
            onOpenLine: (path, line) => unawaited(_openOutlineLine(path, line)),
            onGenerateInto: (path) => unawaited(_generateIntoChapter(path)),
            onAuditChapter: (path) => unawaited(_auditChapter(path)),
            onTrainChapter: _trainChapter,
            onTrainLine: _trainOutlineLine,
            onShowMetrics: () => setState(() => _showLineMetrics = true),
            onPlanBuild: () => unawaited(_openPlanner()),
            chapterBadge: _planRunner.statusLabelFor,
            onCollapse: _isCompactLayout
                ? null
                : () => unawaited(_layout.setOutlinePanelCollapsed(true)),
          ),
        ),
      ],
    );
  }

  Widget _buildGenerateTabContent({
    Widget? sourceControl,
    bool? chessDbSource,
  }) {
    return GeneratePositionPane(
      sourceControl: sourceControl,
      chessDbSource: chessDbSource,
      onShowGenerated: () {
        if (mounted) unawaited(_layout.setDatabaseSource(3));
      },
      fen: _controller.board.fen,
      databaseName:
          '${p.basename(p.dirname(_controller.document.currentRepertoire!.filePath))} / ${_controller.document.currentRepertoire!.name}',
      generation: _generationController,
      onGenerate:
          ({
            String? moveSan,
            required int plies,
            required int cores,
            required int engineMoves,
            required double maiaCoverage,
          }) =>
              (moveSan == null
              ? _generationController.computeExpectimax
              : _generationController.computeMovePv)(
                ExpectimaxProbeTarget(
                  repertoireFilePath:
                      _controller.document.currentRepertoire!.filePath,
                  repertoireStartFen:
                      _controller.board.startingFen ?? kStandardStartFen,
                  movesFromStart: List.of(
                    _controller.board.currentMoveSequence,
                  ),
                  playAsWhite: _controller.document.isRepertoireWhite,
                  moveSan: moveSan,
                  plies: plies,
                  engineThreads: cores,
                  engineMoves: engineMoves,
                  maiaCoverage: maiaCoverage,
                ),
              ),
      onPlayMove: _controller.board.playMove,
      onHoverMove: _boardPreview.setHoverMove,
      onBuildChessDb: () => unawaited(
        _openLineBuildDialog(
          initialConfig: chessDbRepertoirePreset(
            playAsWhite: _controller.document.isRepertoireWhite,
          ),
        ),
      ),
      onPlanLines: () => unawaited(_openPlanner()),
      onCutLines: () => unawaited(_openLineBuildDialog(cutOnly: true)),
    );
  }

  /// Live engine analysis; saved/generated evaluations are a database source.
  Widget _buildEngineTabContent() => SingleChildScrollView(
    child: InlineEngineBar(
      fen: _controller.board.fen,
      isActive: true,
      previewFlipped: _boardFlipped,
      compactChrome: true,
    ),
  );

  /// Database tab of the analysis panel: the live opening explorer.
  Widget _buildDatabaseTabContent() {
    return RepertoireDatabasePane(
      source: _databaseSource,
      onSourceChanged: (source) {
        if (mounted) unawaited(_layout.setDatabaseSource(source));
      },
      evaluationsBuilder: (menu, chessDb) =>
          _buildGenerateTabContent(sourceControl: menu, chessDbSource: chessDb),
      tree: _controller.document.openingGraph,
      repertoireLines: _controller.document.repertoireLines,
      onHoverTreeMove: _onTreeMoveHover,
      onGoBack: _controller.board.goBack,
      onGoForward: _controller.board.goForward,
      fen: _controller.board.fen,
      currentMoveSequence: _controller.board.currentMoveSequence,
      repertoireMovesAtPosition: _repertoireMovesAtCurrentPosition,
      onPlayMove: _controller.board.playMove,
      onAddMove: _onExplorerAddMove,
      onHoverMove: _onExplorerMoveHover,
    );
  }

  Widget _buildJobsContent() {
    return JobsPanel(
      generationController: _generationController,
      auditController: _auditController,
      jobManager: _jobManager,
      onOpenGenerationDialog: () => unawaited(_openGenerateTab()),
      onOpenAuditDialog: () => _openAuditDialog(forceConfig: true),
      // Coverage is a fraction of master-game counts, so without the local
      // master book the run traverses the whole tree and reports "0.0%
      // covered" for a repertoire of any size. Null hides the button until
      // there are games to measure against.
      onOpenCoverageDialog: CoverageController.isAvailable
          ? _showCoverageCalculator
          : null,
    );
  }

  Widget _buildFindingsContent() {
    final ac = _auditController;

    return AuditFindingsPanel(
      key: _findingsPanelKey,
      result: ac.result,
      liveFindings: ac.liveFindings,
      isAuditing: ac.isAuditing,
      auditNodesChecked: ac.nodesChecked,
      auditTotalNodes: ac.totalNodes,
      errorText: ac.error,
      chapterName: _controller.document.currentRepertoire?.name,
      config: ac.lastConfig,
      onFindingSelected: _onFindingSelected,
      onResultChanged: (updatedResult) {
        ac.onResultChanged(updatedResult, _repertoireFilePath);
      },
      onRerunAudit: () => _openAuditDialog(forceConfig: true),
      interruptedSnapshot: ac.interruptedSnapshot,
      onResumeAudit: ac.interruptedSnapshot != null
          ? _resumeInterruptedAudit
          : null,
      onStartFreshAudit: ac.interruptedSnapshot != null
          ? _startFreshAudit
          : null,
      onStartAudit: () => _openAuditDialog(forceConfig: true),
    );
  }

  Widget _buildLinesContent() {
    return RepertoireLinesBrowser(
      lines: _controller.document.repertoireLines,
      currentMoveSequence: _controller.board.currentMoveSequence,
      isWhiteRepertoire: _controller.document.isRepertoireWhite,
      coverageResult: _coverageController.result,
      isCoverageRunning: _coverageController.isRunning,
      coverageProgress: _coverageController.progress,
      coverageProgressMessage: _coverageController.progressMessage,
      tree: _generationController.generatedTree,
      fenMap: _generationController.generatedTreeFenMap,
      traps: _trapSession.traps,
      coherenceResult: _generationController.coherenceService.result,
      navigationStack: _navigationStack,
      boardPreview: _boardPreview,
      onLineSelected: _selectLine,
      onLineRenamed: _renameLine,
      onLineDeleted: _deleteLine,
      // Same switch as the jobs-panel button above.
      onCoveragePressed: CoverageController.isAvailable
          ? _showCoverageCalculator
          : null,
      onNavigateToPosition: (moves) {
        _controller.composeMoves(moves);
      },
    );
  }

  Widget _buildBottomPane() {
    // Job progress ticks (generation, audit) only change the jobs tab and
    // its badge; the findings panel is rebuilt by the audit controller's own
    // notifications, not by every progress tick of an unrelated job.
    return ListenableBuilder(
      listenable: _jobManager,
      child: _buildFindingsContent(),
      builder: (context, findings) => BottomPane(
        controller: _bottomPane,
        findingsContent: findings!,
        jobsContent: _buildJobsContent(),
        findingsBadge: _auditController.activeFindingCount,
        jobsBadge: _jobManager.activeJobs.length,
      ),
    );
  }

  Widget _buildPgnTab() => InteractivePgnEditor(
    tree: _controller.board.tree,
    currentPath: _controller.board.path,
    lineTitle: _controller.title,
    onJump: _controller.board.jump,
    onCommentChanged: _controller.board.setCommentAtPath,
    onToggleNag: _controller.board.toggleNagAtPath,
    onDelete: _controller.deleteDraftBranch,
    onPromote: _controller.board.promoteVariation,
    onMakeMainLine: _controller.board.makeMainLine,
    isEditingExistingLine: _controller.document.selectedPgnLine != null,
    onTitleChanged: _controller.setTitle,
    onCopyToClipboard: (text, message) =>
        copyToClipboard(context, text, successMessage: message),
    onViewInLines: _showLinesSurface,
    ephemeralTitle: _controller.annotatedLineLabel,
  );

  Widget _buildLinesTabContent() {
    return Stack(
      key: _linesPreviewStackKey,
      children: [
        Column(
          children: [
            if (_trapSession.hasTraps)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<bool>(
                        segments: [
                          ButtonSegment<bool>(
                            value: false,
                            label: Text(
                              'Lines (${_controller.document.repertoireLines.length})',
                              style: const TextStyle(fontSize: 12),
                            ),
                            icon: const Icon(Icons.list, size: 14),
                          ),
                          ButtonSegment<bool>(
                            value: true,
                            label: Text(
                              'Traps (${_trapSession.traps.length})',
                              style: const TextStyle(fontSize: 12),
                            ),
                            icon: Icon(
                              Icons.warning_amber_rounded,
                              size: 14,
                              color: _showTrapsInLinesTab
                                  ? null
                                  : AppColors.onSurfaceMuted,
                            ),
                          ),
                        ],
                        selected: {_showTrapsInLinesTab},
                        onSelectionChanged: (v) =>
                            setState(() => _showTrapsInLinesTab = v.first),
                        showSelectedIcon: false,
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _showTrapsInLinesTab && _trapSession.hasTraps
                  ? _buildTrapsContent()
                  : _buildLinesContent(),
            ),
          ],
        ),
        FloatingBoardPreview(
          stackKey: _linesPreviewStackKey,
          controller: _boardPreview,
          flipped: _boardFlipped,
        ),
      ],
    );
  }

  Widget _buildTrapsContent() {
    return TrapsBrowser(
      traps: _trapSession.traps,
      metrics: _trapSession.index?.metrics,
      currentMoveSequence: _controller.board.currentMoveSequence,
      repertoireLineMoves: _controller.document.repertoireLines
          .map((l) => l.moves)
          .toList(),
      boardPreview: _boardPreview,
      onTrapSelected: _showTrapLine,
      onTrapMoveSelected: (trap, ply) => _showTrapLine(trap, ply: ply),
      onStartTour: ({TrapLineInfo? startTrap}) =>
          _trapSession.openTour(startTrap: startTrap),
    );
  }

  /// SANs already present in the repertoire tree at the current cursor.
  Set<String> _repertoireMovesAtCurrentPosition() {
    final tree = _controller.board.tree;
    final path = _controller.board.path;
    final children = path.isEmpty ? tree.roots : tree.nodeAt(path)?.children;
    final saved = _controller.document.openingGraph;
    return {
      if (children != null)
        for (final child in children) child.san,
      if (saved != null)
        for (final group in saved.continuationsAt(_controller.board.fen))
          if (!group.viaTransposition) group.move,
    };
  }

  /// Tint the hovered explorer row's from/to squares on the board. The
  /// API's UCI is standard (`e1g1` castling).
  void _onExplorerMoveHover(ExplorerMove? move) {
    _boardPreview.setHoverMove(move?.uci);
  }

  /// Same for the repertoire tree, whose rows only know their SAN: resolve
  /// it against the board position (a tree row that is not legal there —
  /// the tree can sit one transposition off — simply tints nothing).
  void _onTreeMoveHover(String? san) {
    _boardPreview.setHoverMove(
      san == null ? null : sanToUci(_controller.board.fen, san),
    );
  }

  Future<void> _onExplorerAddMove(ExplorerMove move) async {
    try {
      await _controller.writer.addMoveAtPosition(
        fen: _controller.board.fen,
        san: move.san,
        pathFromRoot: _controller.board.currentMoveSequence,
      );
      _controller.board.playMove(move.san);
      if (mounted) showAppSnackBar(context, 'Added ${move.san} to repertoire');
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          'Failed to add ${move.san}: $e',
          isError: true,
        );
      }
    }
  }
}
