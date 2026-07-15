// Tab-content builders for the repertoire screen: the PGN / Lines / Tree tab
// bodies and the bottom pane's jobs, findings, and lines content. Split out
// of repertoire_screen.dart (pure code motion).
part of '../repertoire_screen.dart';

mixin _RepertoireTabContent
    on
        _RepertoireScreenStateBase,
        _RepertoireTrapHandlers,
        _RepertoireSessionHandlers {
  /// Second tools tab: normally the Lines list, but it becomes the Draft
  /// review surface while a build-from-games session is active.
  Widget _buildSecondTabContent() {
    if (_isBuildSessionActive) {
      return BuildSessionPane(
        session: _buildSession,
        boardPreview: _boardPreview,
        onOpenSettings: _openBuildSessionSettings,
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
    return _buildLinesTabContent();
  }

  Widget _buildTreeTabContent() {
    final tree = _controller.openingTree;
    if (tree == null) {
      return const Center(
        child: Text(
          'No opening tree available.\nLoad a repertoire to build the tree.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return OpeningTreeWidget(
      tree: tree,
      repertoireLines: _controller.repertoireLines,
      currentMoveSequence: _controller.currentMoveSequence,
      onMoveSelected: _controller.userSelectedTreeMove,
      onGoBack: _controller.goBack,
      onGoForward: _controller.goForward,
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
                  isGenerating: _generationController.isGenerating,
                  isGenerationPaused: _generationController.isPaused,
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
    // The inline generation config auto-hides once a generation starts.
    if (_generationController.isGenerating && _showInlineGenConfig) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _showInlineGenConfig = false);
      });
    }

    return JobsTabContent(
      showInlineGenConfig: _showInlineGenConfig,
      showInlineAuditConfig: _showInlineAuditConfig,
      controller: _controller,
      generationController: _generationController,
      auditController: _auditController,
      jobManager: _jobManager,
      generationTabKey: _generationTabKey,
      onCloseInlineGenConfig: () =>
          setState(() => _showInlineGenConfig = false),
      onCloseInlineAuditConfig: () =>
          setState(() => _showInlineAuditConfig = false),
      onOpenGenerationDialog: _openGenerationDialog,
      onOpenAuditConfig: () => _openAuditDialog(forceConfig: true),
      onOpenCoverageDialog: _showCoverageCalculator,
      onAuditingChanged: (auditing) {
        if (!mounted) return;
        _auditController.onAuditingChanged(
          auditing,
          _jobManager,
          _controller.currentRepertoire?.name ?? 'Audit',
        );
        if (auditing) {
          setState(() => _showInlineAuditConfig = false);
          _openBottomPane(BottomPaneTab.findings);
        }
      },
      onAuditResultReady: (result) {
        if (!mounted) return;
        _auditController.onResultReady(result, _repertoireFilePath);
      },
      onAuditLiveFinding: (finding) {
        if (!mounted) return;
        _auditController.onLiveFinding(finding);
      },
      onAuditProgress: (checked, total) {
        if (!mounted) return;
        _auditController.onProgress(checked, total);
      },
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
      traps: _traps,
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
        key: _bottomPaneKey,
        findingsContent: _buildFindingsContent(),
        jobsContent: _buildJobsContent(),
        linesContent: Stack(
          key: _bottomLinesPreviewStackKey,
          children: [
            _buildLinesContent(),
            FloatingBoardPreview(
              stackKey: _bottomLinesPreviewStackKey,
              controller: _boardPreview,
              flipped: _boardFlipped,
            ),
          ],
        ),
        findingsBadge: _auditController.activeFindingCount,
        jobsBadge: _jobManager.activeJobs.length,
        linesBadge: _controller.repertoireLines.length,
        onClose: _clearInlineConfigFlags,
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
      repertoireName: _controller.currentRepertoire?.name,
      repertoireColor: _controller.isRepertoireWhite ? 'White' : 'Black',
      isEditingExistingLine: _controller.selectedPgnLine != null,
      onLineEdited: (updatedPgn) {
        _controller.updateSelectedLineContent(updatedPgn);
      },
      onImportPgnFile: _importPgnFromFile,
      onImportPgnPaste: _importPgnFromPaste,
      onViewInLines: _showLinesSurface,
      onReload: _reloadRepertoire,
      generatedTree: _generationController.generatedTree,
      treeConfig: _generationController.generatedTreeConfig,
      fenMap: _generationController.generatedTreeFenMap,
      boardPreview: _boardPreview,
      coherenceResult: _generationController.coherenceService.result,
      isAnalysisActive: true,
      isGenerating: _generationController.isGenerating,
      isGenerationPaused: _generationController.isPaused,
      embedAnalysisDock: false,
      trapIndex: _trapIndex,
      ephemeralTitle: _controller.annotatedLineLabel,
    );
  }

  Widget _buildLinesTabContent() {
    return Stack(
      key: _linesPreviewStackKey,
      children: [
        Column(
          children: [
            if (_traps.isNotEmpty)
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
                              'Traps (${_traps.length})',
                              style: const TextStyle(fontSize: 11),
                            ),
                            icon: Icon(
                              Icons.warning_amber_rounded,
                              size: 14,
                              color: _showTrapsInLinesTab ? null : Colors.grey,
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
              child: _showTrapsInLinesTab && _traps.isNotEmpty
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
      traps: _traps,
      trapIndex: _trapIndex,
      currentMoveSequence: _controller.currentMoveSequence,
      repertoireLineMoves: _controller.repertoireLines
          .map((l) => l.moves)
          .toList(),
      boardPreview: _boardPreview,
      hasRepertoire: _repertoireFilePath != null,
      onTrapSelected: _showTrapLine,
      onTrapMoveSelected: (trap, ply) => _showTrapLine(trap, ply: ply),
      onStartTour: _openTrapTour,
      onDiscoverTraps: _discoverTrapsFromRepertoire,
      onOpenGeneration: _openGenerationDialog,
    );
  }
}
