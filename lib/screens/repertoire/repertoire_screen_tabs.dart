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

  /// Second tools tab: normally the Lines list, but it becomes the Draft
  /// review surface while a build-from-games session is active.
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
    return _buildLinesTabContent();
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
    if (_generationController.isGenerating && _inlineConfig.showGeneration) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_inlineConfig.onGenerationStarted()) setState(() {});
      });
    }

    return JobsTabContent(
      showInlineGenConfig: _inlineConfig.showGeneration,
      showInlineAuditConfig: _inlineConfig.showAudit,
      controller: _controller,
      generationController: _generationController,
      auditController: _auditController,
      jobManager: _jobManager,
      generationTabKey: _generationTabKey,
      onCloseInlineGenConfig: () {
        if (_inlineConfig.onGenerationStarted()) setState(() {});
      },
      onCloseInlineAuditConfig: () {
        if (_inlineConfig.onAuditStarted()) setState(() {});
      },
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
          _inlineConfig.onAuditStarted();
          setState(() {});
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
        unawaited(_controller.updateSelectedLineContent(updatedPgn));
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
      trapIndex: _trapSession.index,
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
