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
      _controller.composeMoves(trap.movesSan);
      _toolsTabController.animateTo(0);
      return;
    }
    _controller.inspectAnnotatedTree(
      built.tree,
      cursor: built.cursor,
      label: _trapSession.titleFor(trap),
    );
    if (ply != null) _controller.board.jumpToMoveIndex(ply);
    _toolsTabController.animateTo(0);
  }

  void _sessionAwareGoBack() => _controller.board.goBack();

  void _sessionAwareGoForward() => _controller.board.goForward();

  Future<void> _performUndo() async {
    if (!_controller.writer.canUndo) return;
    try {
      await _controller.writer.undo();
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
    final tree = _controller.document.openingGraph;
    if (tree == null) return;
    _openBottomPane(BottomPaneTab.findings);
    unawaited(
      _auditController.launchResume(
        snapshot: snap,
        tree: tree,
        isWhiteRepertoire: _controller.document.isRepertoireWhite,
        jobManager: _jobManager,
        repertoireLabel: _controller.document.currentRepertoire?.name,
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
    _controller.board.navigateToLineMove(finding.movePath);
    _navigatingToFinding = false;

    final preview = EphemeralFindingPreview.forFinding(
      finding,
      _controller.board.fen,
    );
    if (preview == null && _ephemeralPreview == null) return;
    setState(() => _ephemeralPreview = preview);
  }

  void _createNewLineFromEphemeral() {
    final preview = _ephemeralPreview;
    if (preview == null) return;

    final lineMoves = preview.lineMoves;
    setState(() => _ephemeralPreview = null);
    _controller.board.navigateToLineMove(lineMoves);
  }

  void _onGenerationChanged() {
    if (!mounted) return;
    final ctrl = _generationController;
    if (ctrl.isGenerating) {
      _lastRunWasPositionGeneration = ctrl.isExpectimaxProbe;
    }

    if (ctrl.isGenerating &&
        !_generationRouter.wasGenerating &&
        !ctrl.isExpectimaxProbe) {
      _openBottomPane(BottomPaneTab.jobs);
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
          fallbackFilePath: _controller.document.currentRepertoire?.filePath,
        ),
      );
      if (actions.justFinished && !_lastRunWasPositionGeneration) {
        _showLinesSurface();
      }
    }

    setState(() {});
  }

  void _onAuditChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _onCoverageChanged() {
    if (!mounted) return;
    setState(() {});
  }

  void _selectLine(RepertoireLine line) {
    _controller.selectLine(line);
    // Bring the PGN editor into view; in the wide layout it is always
    // visible and the lines panel stays put so the user can keep clicking
    // between lines.
    if (_isCompactLayout) {
      _toolsTabController.animateTo(0);
    }
  }

  Future<void> _renameLine(RepertoireLine line, String newTitle) async {
    final filePath = _controller.document.currentRepertoire?.filePath;
    if (filePath == null) return;

    final success = await _controller.document.renameLine(line, newTitle);

    if (!success) {
      if (mounted) {
        showAppSnackBar(context, AppMessages.renameLineFailed, isError: true);
      }
    }
  }

  Future<void> _deleteLine(RepertoireLine line) async {
    final success = await _controller.document.deleteLine(line);
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
          showAppSnackBar(
            context,
            AppMessages.clipboardEmpty,
            requiresAttention: true,
          );
        }
        return;
      }

      final fen = clipboardData.text!.trim();
      if (fen.isEmpty) {
        if (mounted) {
          showAppSnackBar(
            context,
            AppMessages.clipboardEmpty,
            requiresAttention: true,
          );
        }
        return;
      }

      final success = _controller.composePosition(fen);
      if (!success && mounted) {
        showAppSnackBar(
          context,
          AppMessages.invalidFen,
          requiresAttention: true,
        );
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

  Future<void> _inspectDraftCopy(BuilderCopyUncertainty copy) async {
    try {
      final observed = await _controller.inspectCopy(copy);
      if (!mounted) return;
      final current = _controller.uncertainCopies
          .where((item) => item.draftKey == copy.draftKey)
          .firstOrNull;
      if (current == null) return;
      if (observed is! PgnOpened) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context).builderCopyInspectionFailed,
          isError: true,
        );
        return;
      }
      final keep = await showDialog<bool>(
        context: context,
        builder: (context) => BuilderCopyInspectionDialog(
          destination: copy.destination,
          content: observed.snapshot.content,
        ),
      );
      if (keep == true) await _controller.acknowledgeInspectedCopy(current);
    } catch (error) {
      if (mounted) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context).builderCopyRetained,
          isError: true,
        );
      }
    }
  }

  Future<void> _saveCurrentDraft() async {
    final snapshot = _controller.captureWorkspace();
    final draft = snapshot.drafts
        .where((draft) => draft.key == snapshot.activeKey)
        .firstOrNull;
    if (draft == null) return;
    final pick = await _workspaceNavigation.push<ChapterPick>(
      MaterialPageRoute(
        builder: (context) => const RepertoireSelectionScreen(),
      ),
    );
    if (!mounted || pick == null) return;
    try {
      final chapter = await _resolveChapter(pick.chapter);
      if (!mounted || chapter == null) return;
      await _controller.saveDraftToChapter(draft, chapter);
    } catch (error) {
      if (mounted) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context).builderDraftRetained,
          isError: true,
        );
      }
    }
    _reclaimFocus();
  }

  Future<void> _showRepertoireSelection() async {
    final pick = await _workspaceNavigation.push<ChapterPick>(
      MaterialPageRoute(
        builder: (context) => const RepertoireSelectionScreen(),
      ),
    );

    // A course chapter picked inside a file opens that file: the outline
    // already shows the chapters.
    if (pick != null && mounted) {
      // A selection made now supersedes an older deferred source request.
      _appState?.takeHandoff<OpenBuilder>();
      await _openSelectedRepertoire(pick.chapter);
    }
    _reclaimFocus();
  }

  Future<RepertoireMetadata?> _resolveChapter(RepertoireMetadata picked) async {
    if (p.extension(picked.filePath).toLowerCase() == '.pgn') return picked;
    final chapters = await context
        .read<RepertoireCatalogRepository>()
        .listChapters(picked.filePath);
    return chapters.firstOrNull;
  }

  Future<void> _openSelectedRepertoire(RepertoireMetadata picked) async {
    try {
      final chapter = await _resolveChapter(picked);
      if (!mounted || chapter == null) return;
      await _controller.document.setRepertoire(chapter);
    } catch (error) {
      if (mounted) {
        showAppSnackBar(
          context,
          AppLocalizations.of(context).catalogLoadFailed,
          isError: true,
        );
      }
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
        final before = List<RepertoireLine>.of(
          _controller.document.repertoireLines,
        );
        await _controller.document.loadRepertoire();
        final error = _controller.document.loadError;
        if (error != null) return RepertoireReloadSummary.failed(error);
        return RepertoireReloadSummary.between(
          before,
          _controller.document.repertoireLines,
        );
      },
    );
    _reclaimFocus();
  }

  /// Handle moves from the chessboard - board has already made the move and gives us rich info
  void _handleMove(CompletedMove move) {
    if (!mounted) return;
    _controller.board.playMove(move.san);
  }

  /// The position for [fen] — the controller's cached cursor position when
  /// that is what the board shows (the common case), a fresh parse only for
  /// a preview or session FEN.
  Position _positionFromFen(String fen) {
    if (fen == _controller.board.fen) return _controller.board.position;
    try {
      return Chess.fromSetup(Setup.parseFen(fen));
    } catch (e) {
      log.d('Invalid FEN "$fen": $e', name: 'RepertoireScreen');
      return _controller.board.position;
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

    final tree = _controller.document.openingGraph;
    if (tree == null) {
      showAppSnackBar(
        context,
        'No repertoire tree loaded',
        requiresAttention: true,
      );
      return;
    }

    _openBottomPane(BottomPaneTab.jobs);
    try {
      final result = await _coverageController.runAsJob(
        config: config,
        tree: tree,
        isWhiteRepertoire: _controller.document.isRepertoireWhite,
        jobManager: _jobManager,
        label:
            '${_controller.document.currentRepertoire?.name ?? 'Repertoire'} coverage',
      );
      if (result != null && mounted) {
        showAppSnackBar(
          context,
          'Coverage: ${CoverageController.summarize(result)}',
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          'Coverage analysis failed: $e',
          requiresAttention: true,
        );
      }
    }
  }

  void _runCoherence() {
    if (_controller.document.repertoireLines.length < 5) return;
    final cs = _generationController.coherenceService;
    unawaited(
      cs.compute(
        lines: _controller.document.repertoireLines,
        playAsWhite: _controller.document.isRepertoireWhite,
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
    if (_controller.document.currentRepertoire == null) return;
    context.read<AppState>().switchToTrainer(
      repertoirePath: _controller.document.currentRepertoire!.filePath,
    );
  }

  /// One entry point for every "add PGN" affordance: file and paste are the
  /// same act with two sources, so they belong in one window rather than as
  /// two menu items that make the user commit before they see either.
  Future<void> _importPgn() async {
    final destination = _controller.document.currentRepertoire;
    var added = 0;
    final result = await showPgnImportDialog(
      context,
      confirmLabel: 'Add to repertoire',
      onConfirm: (result) async {
        if (!mounted ||
            !identical(_controller.document.currentRepertoire, destination)) {
          throw StateError('The selected chapter changed.');
        }
        added = await _controller.document.importPgnContent(result.pgnContent);
      },
    );
    if (result == null || !mounted) return;

    showAppSnackBar(
      context,
      'Added $added line${added == 1 ? '' : 's'} to repertoire.',
    );
    _reclaimFocus();
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
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: AppColors.onWarning,
            ),
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
    final current = _controller.document.currentRepertoire;
    if (current == null) return;
    final generation = _controller.document.loadGeneration;
    final folderPath = p.dirname(current.filePath);
    final folder = RepertoireMetadata(
      filePath: folderPath,
      name: p.basename(folderPath),
      lastModified: DateTime.now(),
    );

    final chapter = (await _workspaceNavigation.push<ChapterPick>(
      MaterialPageRoute(
        builder: (_) => RepertoireChaptersScreen(repertoire: folder),
      ),
    ))?.chapter;

    if (!mounted || !_controller.document.isCurrent(generation)) return;
    if (chapter != null) {
      _appState?.takeHandoff<OpenBuilder>();
      await _openChapterPath(chapter.filePath);
    }
    if (mounted) unawaited(_outline.refresh());
    _reclaimFocus();
  }

  /// Creates a new chapter inline (from the breadcrumb dropdown) and switches
  /// to it, without the full-screen chapter manager. The chapter inherits the
  /// repertoire's color from the currently loaded chapter.
  Future<void> _addChapterInline() async {
    final current = _controller.document.currentRepertoire;
    if (current == null) return;

    final generation = _controller.document.loadGeneration;
    final isWhite = _controller.document.isRepertoireWhite;
    final folderPath = p.dirname(current.filePath);
    final name = await showNameEntryDialog(
      context,
      title: 'New chapter',
      fieldLabel: 'Chapter name',
      confirmLabel: 'Create',
      prompt: 'Name this chapter (e.g. a variation or system):',
      allowUnchanged: true,
      validate: RepertoireOutlineService.validateName,
    );
    if (name == null ||
        !mounted ||
        !_controller.document.isCurrent(generation)) {
      return;
    }
    final result = await context
        .read<RepertoireCatalogRepository>()
        .createChapter(folderPath: folderPath, name: name, isWhite: isWhite);
    if (!mounted || !_controller.document.isCurrent(generation)) return;
    if (result case PgnSaved(:final after)) {
      await _openChapterPath(after.path);
    } else {
      showAppSnackBar(context, switch (result) {
        PgnNameCollision() => 'That chapter already exists.',
        PgnWriteUncertain(:final recoveryPath) =>
          'Chapter creation needs verification: ${p.join(folderPath, "$name.pgn")}.'
              '${recoveryPath == null ? "" : " Recovery: $recoveryPath."} Do not retry.',
        _ => 'Could not create chapter.',
      }, isError: true);
    }
    _reclaimFocus();
  }
}
