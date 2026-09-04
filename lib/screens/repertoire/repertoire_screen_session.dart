// Session wiring and command handlers for the repertoire screen: generation/
// audit/coverage/draft/build-by-playing listeners, finding selection, line
// CRUD, PGN import, clipboard paste, and undo. Split out of
// repertoire_screen.dart (pure code motion).
part of '../repertoire_screen.dart';

mixin _RepertoireSessionHandlers on _RepertoireScreenStateBase {
  /// Load a trap as an annotated, explorable line: the path to the trap as
  /// mainline, opponent replies (with play rates and our punish) as
  /// continuations, cursor at the trap position — or at [ply] when given.
  /// Always lands in the PGN tab so the line is clickable right away.
  void _showTrapLine(TrapLineInfo trap, {int? ply}) {
    final built = TrapLineBuilder.build(trap);
    if (built == null) {
      // Stale/corrupt trap file: fall back to the bare sequence.
      _controller.loadMoveSequence(trap.movesSan);
      _toolsTabController.animateTo(0);
      return;
    }
    _controller.loadAnnotatedTree(
      built.tree,
      cursor: built.cursor,
      label: _trapSession.titleFor(trap),
    );
    if (ply != null) _controller.jumpToMoveIndex(ply);
    _toolsTabController.animateTo(0);
  }

  /// While a build-by-playing session is active, ←/→ navigate the scratchpad
  /// (no-ops outside exploration) instead of the repertoire cursor — moving
  /// the cursor away from a decision point would pause the session.
  void _sessionAwareGoBack() {
    if (_isBuildSessionActive) {
      _buildSession.scratchGoBack();
      return;
    }
    _controller.goBack();
  }

  void _sessionAwareGoForward() {
    if (_isBuildSessionActive) {
      _buildSession.scratchGoForward();
      return;
    }
    _controller.goForward();
  }

  Future<void> _performUndo() async {
    if (_isBuildSessionActive) {
      final undone = await _buildSession.undoLastCommit();
      if (undone && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Undid last committed move'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    if (!_controller.writer.canUndo) return;
    try {
      final undone = await _controller.writer.undo();
      if (!mounted || !undone) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Undid last repertoire add'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      log.w('Undo failed', name: 'RepertoireScreen', error: e);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Undo failed: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _resumeInterruptedAudit() {
    final snap = _auditController.interruptedSnapshot;
    if (snap == null) return;
    final tree = _controller.openingTree;
    if (tree == null) return;
    _openBottomPane(BottomPaneTab.findings);
    unawaited(
      _auditController.launchResume(
        snapshot: snap,
        tree: tree,
        isWhiteRepertoire: _controller.isRepertoireWhite,
        jobManager: _jobManager,
        repertoireLabel: _controller.currentRepertoire?.name,
        repertoireFilePath: _repertoireFilePath,
      ),
    );
  }

  void _startFreshAudit() {
    _auditController.startFresh();
    _openAuditDialog(forceConfig: true);
  }

  void _onFindingSelected(AuditFinding finding) {
    _navigatingToFinding = true;
    _controller.navigateToLineMove(finding.movePath);
    _navigatingToFinding = false;

    final preview = EphemeralFindingPreview.forFinding(
      finding,
      _controller.fen,
    );
    if (preview == null && _ephemeralPreview == null) return;
    setState(() => _ephemeralPreview = preview);
  }

  void _createNewLineFromEphemeral() {
    final preview = _ephemeralPreview;
    if (preview == null) return;

    final lineMoves = preview.lineMoves;
    setState(() => _ephemeralPreview = null);
    _controller.navigateToLineMove(lineMoves);
  }

  void _onGenerationChanged() {
    if (!mounted) return;
    final ctrl = _generationController;

    if (ctrl.isGenerating && ctrl.currentJob == null) {
      final probe = ctrl.isExpectimaxProbe;
      ctrl.currentJob = _jobManager.createJob(
        type: JobType.generation,
        label: probe
            ? 'Expectimax · ${ctrl.expectimaxProbeLabel}'
            : _controller.currentRepertoire?.name ?? 'Generation',
        subtreeFen: _controller.fen,
      );
      ctrl.currentJob!.updateStatus(JobStatus.running);
      // A probe reports inside the expectimax pane that started it; the
      // Jobs pane is still there for anyone who wants the tile.
      if (!probe) _openBottomPane(BottomPaneTab.jobs);
    }

    context.read<AppState>().setRepertoireGenerating(ctrl.isGenerating);

    final actions = _generationRouter.onNotified(
      isGenerating: ctrl.isGenerating,
      generatedTree: ctrl.generatedTree,
    );

    if (actions.shouldRunCoherence) _runCoherence();

    if (actions.justFinished && ctrl.lastError != null) {
      showAppSnackBar(context, ctrl.lastError!, isError: true);
    } else if (actions.justFinished && ctrl.lastRunSummary.isNotEmpty) {
      showAppSnackBar(context, ctrl.lastRunSummary);
    }

    if (!ctrl.isGenerating) {
      // A finished build's own trap index is consistent with the tree it just
      // built, so it wins; a repertoire loaded from disk has no bundle in
      // memory and falls back to the sidecar file.
      unawaited(
        _trapSession.adoptFromBuild(
          ctrl.current?.traps,
          fallbackFilePath: _controller.currentRepertoire?.filePath,
        ),
      );
      if (actions.justFinished) _showLinesSurface();
    }

    if (actions.shouldCoalesceRebuild) {
      _genRebuildThrottle ??= Timer(_kGenRebuildInterval, () {
        _genRebuildThrottle = null;
        if (mounted) setState(() {});
      });
    } else {
      _genRebuildThrottle?.cancel();
      _genRebuildThrottle = null;
      setState(() {});
    }
  }

  void _onAuditChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onCoverageChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onBuildSessionChanged() {
    if (!mounted) return;
    setState(() {});
    if (_buildSession.isActive && !_wasBuildSessionActive) {
      _showLinesSurface();
    }
    _wasBuildSessionActive = _buildSession.isActive;
  }

  void _onDraftChanged() {
    if (!mounted) return;
    // A draft opening from any entry point should always be visible.
    if (_draftController.isActive) _showLinesSurface();
    setState(() {});
  }

  void _selectLine(RepertoireLine line) {
    _controller.loadPgnLine(line);
    // Bring the PGN editor into view; in the wide layout it is always
    // visible and the lines panel stays put so the user can keep clicking
    // between lines.
    if (_isCompactLayout) {
      _toolsTabController.animateTo(0);
    }
  }

  Future<void> _renameLine(RepertoireLine line, String newTitle) async {
    final filePath = _controller.currentRepertoire?.filePath;
    if (filePath == null) return;

    final service = RepertoireService();
    final success = await service.updateLineTitle(filePath, line.id, newTitle);

    if (success) {
      await _controller.loadRepertoire();
    } else {
      if (mounted) {
        showAppSnackBar(context, AppMessages.renameLineFailed, isError: true);
      }
    }
  }

  Future<void> _deleteLine(RepertoireLine line) async {
    final success = await _controller.deleteLine(line);
    if (!success && mounted) {
      showAppSnackBar(context, 'Failed to delete line', isError: true);
    }
  }

  /// Paste a FEN position from clipboard (Ctrl+Shift+V)
  Future<void> _pastePositionFromClipboard() async {
    try {
      final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
      if (clipboardData == null || clipboardData.text == null) {
        if (mounted) {
          showAppSnackBar(context, AppMessages.clipboardEmpty);
        }
        return;
      }

      final fen = clipboardData.text!.trim();
      if (fen.isEmpty) {
        if (mounted) {
          showAppSnackBar(context, AppMessages.clipboardEmpty);
        }
        return;
      }

      final success = _controller.setPositionFromFen(fen);
      if (!success && mounted) {
        showAppSnackBar(context, AppMessages.invalidFen);
      }
    } catch (e) {
      log.w('Clipboard read failed', name: 'RepertoireScreen', error: e);
      if (mounted) {
        showAppSnackBar(
          context,
          AppMessages.clipboardReadFailed,
          isError: true,
        );
      }
    }
  }

  Future<void> _showRepertoireSelection() async {
    final result = await Navigator.of(context).push<RepertoireMetadata>(
      MaterialPageRoute(
        builder: (context) => const RepertoireSelectionScreen(),
      ),
    );

    if (result != null && mounted) {
      await _controller.setRepertoire(result);
    }
    _reclaimFocus();
  }

  /// Re-reads the repertoire PGN and reports what changed.
  ///
  /// The bare reload is still available to callers that already know why they
  /// are reloading (the load-error retry button); this is the user-facing one,
  /// which exists to answer "has anything touched this file behind my back?"
  Future<void> _reloadRepertoire() async {
    await showRepertoireReloadDialog(
      context,
      reload: () async {
        final before = List<RepertoireLine>.of(_controller.repertoireLines);
        await _controller.loadRepertoire();
        final error = _controller.loadError;
        if (error != null) return RepertoireReloadSummary.failed(error);
        return RepertoireReloadSummary.between(
          before,
          _controller.repertoireLines,
        );
      },
    );
    _reclaimFocus();
  }

  /// Handle moves from the chessboard - board has already made the move and gives us rich info
  void _handleMove(CompletedMove move) {
    if (!mounted) return;
    if (_isBuildSessionActive) {
      // Session moves are scratchpad exploration (or ignored while the
      // opponent thinks) — never direct repertoire-tree edits.
      _buildSession.handleBoardMove(move.san);
      return;
    }
    _controller.playMove(move.san);
  }

  /// The position for [fen] — the controller's cached cursor position when
  /// that is what the board shows (the common case), a fresh parse only for
  /// a preview or session FEN.
  Position _positionFromFen(String fen) {
    if (fen == _controller.fen) return _controller.position;
    try {
      return Chess.fromSetup(Setup.parseFen(fen));
    } catch (e) {
      log.d('Invalid FEN "$fen": $e', name: 'RepertoireScreen');
      return _controller.position;
    }
  }

  /// Audit arrows for [fen], computed once per (audit result, FEN).  The
  /// board zone rebuilds on every cursor notification and the derivation
  /// scans every finding and parses the FEN, so it is not per-build work.
  ///
  /// Keyed on the controller's [AuditSessionController.resultVersion], not on
  /// the result's identity: dismissing a finding mutates it in place and
  /// re-emits the same object, and the arrows must follow.
  List<BoardAnnotation> _auditAnnotationsAt(String fen) {
    final result = _auditController.result;
    final version = _auditController.resultVersion;
    final cached = _auditAnnotations;
    if (cached != null && cached.version == version && cached.fen == fen) {
      return cached.annotations;
    }
    final annotations = buildAuditBoardAnnotations(
      result: result,
      currentFen: fen,
    );
    _auditAnnotations = (version: version, fen: fen, annotations: annotations);
    return annotations;
  }

  ({int version, String fen, List<BoardAnnotation> annotations})?
  _auditAnnotations;

  Future<void> _showCoverageCalculator() async {
    if (_coverageController.isRunning) {
      _openBottomPane(BottomPaneTab.jobs);
      return;
    }

    final config = await showCoverageConfigDialog(context);
    if (config == null || !mounted) return;

    final tree = _controller.openingTree;
    if (tree == null) {
      showAppSnackBar(context, 'No repertoire tree loaded');
      return;
    }

    _openBottomPane(BottomPaneTab.jobs);
    try {
      final result = await _coverageController.runAsJob(
        config: config,
        tree: tree,
        isWhiteRepertoire: _controller.isRepertoireWhite,
        jobManager: _jobManager,
        label:
            '${_controller.currentRepertoire?.name ?? 'Repertoire'} coverage',
      );
      if (result != null && mounted) {
        showAppSnackBar(
          context,
          'Coverage: ${CoverageController.summarize(result)}',
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Coverage analysis failed: $e');
      }
    }
  }

  void _runCoherence() {
    if (_controller.repertoireLines.length < 5) return;
    final cs = _generationController.coherenceService;
    unawaited(
      cs.compute(
        lines: _controller.repertoireLines,
        playAsWhite: _controller.isRepertoireWhite,
      ),
    );
    // Remove first: _runCoherence fires on every generation notify, and
    // duplicate registrations would stack up between coherence updates.
    cs.removeListener(_onCoherenceUpdated);
    cs.addListener(_onCoherenceUpdated);
  }

  void _onCoherenceUpdated() {
    if (mounted) setState(() {});
    _generationController.coherenceService.removeListener(_onCoherenceUpdated);
  }

  void _trainRepertoire() {
    if (_controller.currentRepertoire == null) return;
    context.read<AppState>().switchToTrainer(
      repertoirePath: _controller.currentRepertoire!.filePath,
    );
  }

  /// One entry point for every "add PGN" affordance: file and paste are the
  /// same act with two sources, so they belong in one window rather than as
  /// two menu items that make the user commit before they see either.
  Future<void> _importPgn() async {
    final result = await showPgnImportDialog(
      context,
      confirmLabel: 'Add to repertoire',
    );
    if (result == null || !mounted) return;

    final added = await _controller.importPgnContent(result.pgnContent);
    if (!mounted) return;

    showAppSnackBar(
      context,
      'Added $added line${added == 1 ? '' : 's'} to repertoire.',
    );
    _reclaimFocus();
  }

  /// Loads the sibling chapters of the active repertoire folder so the toolbar
  /// breadcrumb can offer one-click switching.
  Future<void> _loadChapters() async {
    final current = _controller.currentRepertoire;
    if (current == null) return;
    try {
      final chapters = await _chapterStore.listSiblings(current.filePath);
      if (!mounted) return;
      setState(() => _chapters = chapters);
    } catch (e) {
      log.w('Load chapters failed', name: 'RepertoireScreen', error: e);
    }
  }

  /// Confirm before throwing a paused build away — the partial tree is deleted
  /// and cannot be resumed afterward.
  Future<void> _confirmDiscardBuild() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this build?'),
        content: const Text(
          'The paused build and everything it has explored so far will be '
          'moved to Chess Auto Prep recovery trash and will no longer be '
          'resumable.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true) {
      _generationController.discardBuild();
    }
  }

  /// Opens the chapter list for the current repertoire folder so the user can
  /// switch chapters (and then generate / edit within that chapter). The active
  /// chapter's file path is `.../<repertoire>/<chapter>.pgn`; its parent
  /// directory is the repertoire folder.
  Future<void> _showChapterList() async {
    final current = _controller.currentRepertoire;
    if (current == null) return;
    final folder = _chapterStore.folderMetadata(current.filePath);

    final chapter = await Navigator.of(context).push<RepertoireMetadata>(
      MaterialPageRoute(
        builder: (_) => RepertoireChaptersScreen(repertoire: folder),
      ),
    );

    if (chapter != null && mounted && chapter.filePath != current.filePath) {
      await _controller.setRepertoire(chapter);
    }
    // Chapters may have been added/renamed/deleted without switching.
    await _loadChapters();
    _reclaimFocus();
  }

  /// Switches the active chapter from the breadcrumb dropdown.
  Future<void> _onChapterSelected(RepertoireMetadata chapter) async {
    if (chapter.filePath == _controller.currentRepertoire?.filePath) return;
    await _controller.setRepertoire(chapter);
    _reclaimFocus();
  }

  /// Creates a new chapter inline (from the breadcrumb dropdown) and switches
  /// to it, without the full-screen chapter manager. The chapter inherits the
  /// repertoire's color from the currently loaded chapter.
  Future<void> _addChapterInline() async {
    final current = _controller.currentRepertoire;
    if (current == null) return;

    final name = await showAddChapterDialog(
      context,
      existingNames: _chapters.map((c) => c.name),
    );
    if (name == null || !mounted) return;

    final result = await _chapterStore.create(
      folderPath: _chapterStore.folderOf(current.filePath),
      name: name,
      isWhite: _controller.isRepertoireWhite,
    );
    if (!mounted) return;
    if (!result.succeeded) {
      showAppSnackBar(context, result.error!, isError: true);
      return;
    }

    await _controller.setRepertoire(result.chapter!);
    await _loadChapters();
    _reclaimFocus();
  }
}
