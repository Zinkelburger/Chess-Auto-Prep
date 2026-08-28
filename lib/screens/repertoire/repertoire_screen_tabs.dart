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
  /// outline column): normally the outline, the metrics browser when asked
  /// for, and the Draft / Session surface while one of those runs.
  Widget _buildSecondTabContent() {
    if (_isBuildSessionActive) {
      return BuildSessionPane(
        session: _buildSession,
        boardPreview: _boardPreview,
        onOpenSettings: () => _buildLauncher.openSessionSettings(context),
      );
    }
    if (_draftController.isBuilding) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _draftController.progress,
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }
    final draft = _draftController.draft;
    if (draft != null) {
      return DraftReviewPane(
        draft: draft,
        isWhite: _draftController.isWhite,
        controller: _controller,
        sourceLabel: _draftController.sourceLabel,
        onClose: _draftController.close,
        onSelectLine: (sans) => _controller.loadMoveSequence(sans),
      );
    }
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
                  tooltip: 'Hide chapters (L)',
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
    final selected = _controller.selectedPgnLine;
    final chapterPath = _controller.currentRepertoire?.filePath;
    return Column(
      children: [
        Expanded(
          child: RepertoireOutlinePanel(
            controller: _outline,
            currentMoves: _controller.currentMoveSequence,
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

  Widget _buildTreeTabContent() {
    return RepertoireTreePane(
      tree: _controller.openingTree,
      repertoireLines: _controller.repertoireLines,
      currentMoveSequence: _controller.currentMoveSequence,
      fen: _controller.fen,
      onMoveSelected: _controller.userSelectedTreeMove,
      onGoBack: _controller.goBack,
      onGoForward: _controller.goForward,
      repertoireMovesAtPosition: _repertoireMovesAtCurrentPosition,
      onPlayMove: _controller.playMove,
      onAddMove: _onExplorerAddMove,
    );
  }

  /// Engine tab of the analysis panel: Stockfish lines with the expectimax
  /// bar under them. Stacked, because the panel is a column and the two bars
  /// were built as headers that read left to right.
  Widget _buildEngineTabContent() {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InlineEngineBar(
            // Follow the scratchpad while a session explores.
            fen: _isBuildSessionActive
                ? _buildSession.boardFen
                : _controller.fen,
            isActive: true,
          ),
          const Divider(height: 1),
          InlineExpectimaxBar(
            controller: _controller,
            tree: _generationController.generatedTree,
            treeConfig: _generationController.generatedTreeConfig,
            fenMap: _generationController.generatedTreeFenMap,
            boardPreview: _boardPreview,
            coherenceResult: _generationController.coherenceService.result,
            fenOverride: _isBuildSessionActive ? _buildSession.boardFen : null,
          ),
        ],
      ),
    );
  }

  /// Database tab of the analysis panel: the live opening explorer.
  Widget _buildDatabaseTabContent() {
    return RepertoireDatabasePane(
      fen: _controller.fen,
      repertoireMovesAtPosition: _repertoireMovesAtCurrentPosition,
      onPlayMove: _controller.playMove,
      onAddMove: _onExplorerAddMove,
    );
  }

  Widget _buildPgnTabWithEngines() {
    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: InlineEngineBar(
                  // Follow the scratchpad while a session explores.
                  fen: _isBuildSessionActive
                      ? _buildSession.boardFen
                      : _controller.fen,
                  isActive: true,
                ),
              ),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: Theme.of(context).dividerColor,
              ),
              Expanded(
                child: InlineExpectimaxBar(
                  controller: _controller,
                  tree: _generationController.generatedTree,
                  treeConfig: _generationController.generatedTreeConfig,
                  fenMap: _generationController.generatedTreeFenMap,
                  boardPreview: _boardPreview,
                  coherenceResult:
                      _generationController.coherenceService.result,
                  // Follow the scratchpad while a session explores.
                  fenOverride: _isBuildSessionActive
                      ? _buildSession.boardFen
                      : null,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(4.0),
            child: _buildPgnTab(),
          ),
        ),
      ],
    );
  }

  Widget _buildJobsContent() {
    return JobsTabContent(
      controller: _controller,
      generationController: _generationController,
      auditController: _auditController,
      jobManager: _jobManager,
      onOpenGenerationDialog: () => unawaited(_openGenerationDialog()),
      onOpenAuditConfig: () => _openAuditDialog(forceConfig: true),
      onOpenCoverageDialog: _showCoverageCalculator,
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
      lines: _controller.repertoireLines,
      currentMoveSequence: _controller.currentMoveSequence,
      isWhiteRepertoire: _controller.isRepertoireWhite,
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
      onCoveragePressed: _showCoverageCalculator,
      onNavigateToPosition: (moves) {
        _controller.loadMoveSequence(moves);
      },
    );
  }

  Widget _buildBottomPane() {
    return ListenableBuilder(
      listenable: _jobManager,
      builder: (context, _) => BottomPane(
        controller: _bottomPane,
        findingsContent: _buildFindingsContent(),
        jobsContent: _buildJobsContent(),
        findingsBadge: _auditController.activeFindingCount,
        jobsBadge: _jobManager.activeJobs.length,
      ),
    );
  }

  Widget _buildPgnTab() {
    return PgnWithAnalysisPane(
      controller: _controller,
      tree: _controller.tree,
      currentPath: _controller.path,
      onJump: (path) => _controller.jump(path),
      onCommentChanged: (path, comment) =>
          _controller.setCommentAtPath(path, comment),
      onDelete: (path) => _controller.deleteAtPath(path),
      onPromote: (path) => _controller.promoteVariation(path),
      onMakeMainLine: (path) => _controller.makeMainLine(path),
      repertoireColor: _controller.isRepertoireWhite ? 'White' : 'Black',
      isEditingExistingLine: _controller.selectedPgnLine != null,
      onLineEdited: (updatedPgn) {
        unawaited(_controller.updateSelectedLineContent(updatedPgn));
      },
      onImportPgn: _importPgn,
      onViewInLines: _showLinesSurface,
      onReload: _reloadRepertoire,
      generatedTree: _generationController.generatedTree,
      treeConfig: _generationController.generatedTreeConfig,
      fenMap: _generationController.generatedTreeFenMap,
      boardPreview: _boardPreview,
      coherenceResult: _generationController.coherenceService.result,
      isAnalysisActive: true,
      embedAnalysisDock: false,
      ephemeralTitle: _controller.annotatedLineLabel,
    );
  }

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
                              'Lines (${_controller.repertoireLines.length})',
                              style: const TextStyle(fontSize: 11),
                            ),
                            icon: const Icon(Icons.list, size: 14),
                          ),
                          ButtonSegment<bool>(
                            value: true,
                            label: Text(
                              'Traps (${_trapSession.traps.length})',
                              style: const TextStyle(fontSize: 11),
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
    return TrapsTabContent(
      traps: _trapSession.traps,
      trapIndex: _trapSession.index,
      currentMoveSequence: _controller.currentMoveSequence,
      repertoireLineMoves: _controller.repertoireLines
          .map((l) => l.moves)
          .toList(),
      boardPreview: _boardPreview,
      hasRepertoire: _repertoireFilePath != null,
      onTrapSelected: _showTrapLine,
      onTrapMoveSelected: (trap, ply) => _showTrapLine(trap, ply: ply),
      onStartTour: ({TrapLineInfo? startTrap}) =>
          _trapSession.openTour(startTrap: startTrap),
      onDiscoverTraps: _discoverTrapsFromRepertoire,
      onOpenGeneration: _openGenerationDialog,
    );
  }

  /// SANs already present in the repertoire tree at the current cursor.
  Set<String> _repertoireMovesAtCurrentPosition() {
    final tree = _controller.tree;
    final path = _controller.path;
    final children = path.isEmpty ? tree.roots : tree.nodeAt(path)?.children;
    return {for (final c in (children ?? const [])) c.san};
  }

  Future<void> _onExplorerAddMove(ExplorerMove move) async {
    try {
      await _controller.writer.addMoveAtPosition(
        fen: _controller.fen,
        san: move.san,
        pathFromRoot: _controller.currentMoveSequence,
      );
      _controller.playMove(move.san);
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
