// Session wiring and command handlers for the repertoire screen: generation/
// audit/coverage/draft/build-by-playing listeners, finding selection, line
// CRUD, PGN import, clipboard paste, and undo. Split out of
// repertoire_screen.dart (pure code motion).
part of '../repertoire_screen.dart';

mixin _RepertoireSessionHandlers
    on _RepertoireScreenStateBase, _RepertoireTrapHandlers {
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
    _auditController.launchResume(
      snapshot: snap,
      tree: tree,
      isWhiteRepertoire: _controller.isRepertoireWhite,
      jobManager: _jobManager,
      repertoireLabel: _controller.currentRepertoire?.name,
      repertoireFilePath: _repertoireFilePath,
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

    if ((finding.type == AuditFindingType.missingResponse ||
            finding.type == AuditFindingType.uncoveredStrongMove) &&
        finding.missingMove != null) {
      try {
        final parentFen = _controller.fen;
        final pos = Chess.fromSetup(Setup.parseFen(parentFen));
        final move = pos.parseSan(finding.missingMove!);
        if (move != null) {
          final after = pos.play(move);
          setState(() {
            _ephemeralFinding = finding;
            _ephemeralFen = after.fen;
          });
          return;
        }
      } catch (e) {
        log.d(
          'Failed to preview missing move "${finding.missingMove}": $e',
          name: 'RepertoireScreen',
        );
      }
    }

    if (_ephemeralFinding != null) {
      setState(() {
        _ephemeralFinding = null;
        _ephemeralFen = null;
      });
    }
  }

  void _createNewLineFromEphemeral() {
    final finding = _ephemeralFinding;
    if (finding == null || finding.missingMove == null) return;

    final lineMoves = [...finding.movePath, finding.missingMove!];

    setState(() {
      _ephemeralFinding = null;
      _ephemeralFen = null;
    });

    _controller.navigateToLineMove(lineMoves);
  }

  void _onGenerationChanged() {
    if (!mounted) return;
    final ctrl = _generationController;

    if (ctrl.isGenerating && ctrl.currentJob == null) {
      ctrl.currentJob = _jobManager.createJob(
        type: JobType.generation,
        label: _controller.currentRepertoire?.name ?? 'Generation',
        subtreeFen: _controller.fen,
      );
      ctrl.currentJob!.updateStatus(JobStatus.running);
      _openBottomPane(BottomPaneTab.jobs);
    }

    context.read<AppState>().setRepertoireGenerating(ctrl.isGenerating);

    final justFinished = !ctrl.isGenerating && _wasGenerating;
    _wasGenerating = ctrl.isGenerating;

    // Re-cluster only when a new generated tree appears or the run completes.
    // This used to fire on every progress notify, re-extracting itemsets over
    // all repertoire lines several times per second for the whole build.
    if (ctrl.generatedTree != null &&
        (justFinished || !identical(ctrl.generatedTree, _lastCoherenceTree))) {
      _lastCoherenceTree = ctrl.generatedTree;
      _runCoherence();
    }

    if (justFinished && ctrl.lastError != null) {
      showAppSnackBar(context, ctrl.lastError!, isError: true);
    }

    if (!ctrl.isGenerating) {
      // Prefer the in-memory bundle's trap index (consistent with the tree we
      // just built); fall back to disk for previously-saved repertoires.
      final bundle = ctrl.current;
      if (bundle != null) {
        _traps = bundle.traps.allTraps;
        _trapIndex = _traps.isEmpty ? null : bundle.traps;
      } else {
        final fp = _controller.currentRepertoire?.filePath;
        if (fp != null) _loadTraps(fp);
      }
      if (justFinished) {
        _showLinesSurface();
      }
    }

    if (ctrl.isGenerating) {
      // Progress ticks arrive many times per second; coalesce the
      // whole-screen rebuild instead of repainting on every one — this also
      // runs while the screen sits hidden in the IndexedStack.
      _genRebuildThrottle ??= Timer(const Duration(milliseconds: 250), () {
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

  void _generateFromHere() {
    _openGenerationDialog();
  }

  Future<void> _buildFromGames() async {
    final appState = context.read<AppState>();
    // Real games always start from the initial position, so the from-current
    // option only makes sense for standard-start repertoires.
    final standardStart = _controller.startingFen == null;
    final config = await showGamesSourceForm(
      context,
      initialIsWhite: _controller.isRepertoireWhite,
      initialChesscomUsername: appState.chesscomUsername,
      initialLichessUsername: appState.lichessUsername,
      atRoot: !standardStart || _controller.currentMoveSequence.isEmpty,
      rootFen: kStandardStartFen,
      currentFen: standardStart ? _controller.fen : null,
      currentMoveSans: standardStart
          ? _controller.currentMoveSequence
          : const [],
    );
    if (config == null || !mounted) return;

    // Remember the username app-wide so tactics / weakness finder reuse it.
    if (config.platform == GamesPlatform.chesscom) {
      appState.setChesscomUsername(config.username);
    } else {
      appState.setLichessUsername(config.username);
    }

    // Bring the Lines/Draft surface into view and show progress inline.
    _showLinesSurface();
    final error = await _draftController.build(
      config: config,
      repertoire: _controller.tree,
    );
    if (error != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  void _onBuildSessionChanged() {
    if (!mounted) return;
    setState(() {});
    if (_buildSession.isActive && !_wasBuildSessionActive) {
      _showLinesSurface();
    }
    _wasBuildSessionActive = _buildSession.isActive;
  }

  Future<void> _startBuildByPlaying() async {
    if (_controller.currentRepertoire == null) return;
    if (_isBuildSessionActive) {
      _showLinesSurface();
      return;
    }
    final config = await showBuildByPlayingForm(
      context,
      initial: BuildByPlayingSettings.instance.config,
      atRoot: _controller.isAtRootPosition,
      rootFen: _controller.rootFen,
      rootMoveSans: _controller.rootMoveSans,
      currentFen: _controller.fen,
      currentMoveSans: _controller.currentMoveSequence,
      boardFlipped: !_controller.isRepertoireWhite,
    );
    if (config == null || !mounted) return;
    BuildByPlayingSettings.instance.applyFrom(config);
    _showLinesSurface();
    await _buildSession.start(
      config,
      generatedTree: _generationController.generatedTree,
      fenMap: _generationController.generatedTreeFenMap,
    );
  }

  /// Mid-session knob changes from the session pane's gear icon.
  Future<void> _openBuildSessionSettings() async {
    final config = await showBuildByPlayingForm(
      context,
      initial: _buildSession.config,
      atRoot: true, // start-from choice is meaningless mid-session
    );
    if (config == null || !mounted) return;
    BuildByPlayingSettings.instance.applyFrom(config);
    _buildSession.updateConfig(config);
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

  Future<void> _reloadRepertoire() async {
    await _controller.loadRepertoire();
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

  Position _positionFromFen(String fen) {
    try {
      return Chess.fromSetup(Setup.parseFen(fen));
    } catch (e) {
      log.d('Invalid FEN "$fen": $e', name: 'RepertoireScreen');
      return _controller.position;
    }
  }

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

    // Coverage runs as a first-class job so the run is visible in the
    // Jobs pane alongside generation and audit.
    final job = _jobManager.createJob(
      type: JobType.coverage,
      label: '${_controller.currentRepertoire?.name ?? 'Repertoire'} coverage',
    );
    job.updateStatus(JobStatus.running);
    _openBottomPane(BottomPaneTab.jobs);

    try {
      final result = await _coverageController.calculate(
        config: config,
        tree: tree,
        isWhiteRepertoire: _controller.isRepertoireWhite,
        onProgress: (message, progress) {
          job.updateProgress(
            JobProgress(fraction: progress ?? 0, message: message),
          );
        },
      );
      if (result != null) {
        job.updateProgress(
          JobProgress(
            fraction: 1,
            message:
                '${result.coveragePercent.toStringAsFixed(1)}% covered, '
                '${result.tooShallowLeaves.length} shallow, '
                '${result.tooDeepLeaves.length} deep, '
                '${result.unaccountedMoves.length} unaccounted',
          ),
        );
      }
      job.updateStatus(JobStatus.completed);
      if (result != null && mounted) {
        showAppSnackBar(
          context,
          'Coverage: ${result.coveragePercent.toStringAsFixed(1)}% covered, '
          '${result.tooShallowLeaves.length} shallow, '
          '${result.tooDeepLeaves.length} deep, '
          '${result.unaccountedMoves.length} unaccounted moves',
        );
      }
    } catch (e) {
      job.fail('$e');
      if (mounted) {
        showAppSnackBar(context, 'Coverage analysis failed: $e');
      }
    }
  }

  void _runCoherence() {
    if (_controller.repertoireLines.length < 5) return;
    final cs = _generationController.coherenceService;
    cs.compute(
      lines: _controller.repertoireLines,
      playAsWhite: _controller.isRepertoireWhite,
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

  Future<void> _importPgnFromFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pgn', 'txt'],
        withData: false,
        withReadStream: false,
      );
      if (result == null || result.files.isEmpty || !mounted) return;

      final path = result.files.single.path;
      if (path == null) return;

      final content = await StorageFactory.instance.readFile(path);
      if (content == null || !mounted) return;

      final added = await _controller.importPgnContent(content);
      if (!mounted) return;

      showAppSnackBar(
        context,
        'Added $added line${added == 1 ? '' : 's'} to repertoire.',
      );
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, 'Could not read file: $e', isError: true);
      }
    }
  }

  Future<void> _importPgnFromPaste() async {
    final result = await showPgnImportDialog(
      context,
      title: 'Paste PGN',
      confirmLabel: 'Add to Repertoire',
    );
    if (result == null || !mounted) return;

    final added = await _controller.importPgnContent(result.pgnContent);
    if (!mounted) return;

    showAppSnackBar(
      context,
      'Added $added line${added == 1 ? '' : 's'} to repertoire.',
    );
  }

  /// Loads the sibling chapters of the active repertoire folder so the toolbar
  /// breadcrumb can offer one-click switching.
  Future<void> _loadChapters() async {
    final current = _controller.currentRepertoire;
    if (current == null) return;
    final folder = StorageFactory.instance.parentPath(current.filePath);
    try {
      final chapters = await StorageFactory.instance.listChapters(folder);
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
          'deleted. This cannot be undone.',
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
    final folderPath = StorageFactory.instance.parentPath(current.filePath);
    final folder = RepertoireMetadata(
      filePath: folderPath,
      name: p.basename(folderPath),
      lastModified: DateTime.now(),
    );

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
    final folder = StorageFactory.instance.parentPath(current.filePath);
    final existingNames = _chapters.map((c) => c.name.toLowerCase()).toSet();

    final controller = TextEditingController();
    String? nameError;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Add Chapter'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Name this chapter (e.g. a variation or system):'),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Chapter Name',
                  hintText: "King's Gambit",
                  errorText: nameError,
                ),
                onChanged: (_) {
                  if (nameError != null) setLocal(() => nameError = null);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) {
                  setLocal(() => nameError = 'Please enter a name');
                  return;
                }
                if (existingNames.contains(value.toLowerCase())) {
                  setLocal(() => nameError = 'A chapter named "$value" exists');
                  return;
                }
                Navigator.of(context).pop(value);
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    controller.dispose();
    if (name == null || !mounted) return;

    try {
      final storage = StorageFactory.instance;
      final color = _controller.isRepertoireWhite ? 'White' : 'Black';
      final path = storage.chapterFilePath(folder, name);
      if (await storage.fileExists(path)) {
        if (mounted) showAppSnackBar(context, 'That chapter already exists.');
        return;
      }
      final header =
          '// $name\n'
          '// Color: $color\n'
          '// Created on ${DateTime.now().toString().split('.')[0]}\n\n';
      await storage.writeFile(path, header);

      await _controller.setRepertoire(
        RepertoireMetadata(
          filePath: path,
          name: name,
          gameCount: 0,
          lastModified: DateTime.now(),
        ),
      );
      await _loadChapters();
      _reclaimFocus();
    } catch (e) {
      log.w('Create chapter failed', name: 'RepertoireScreen', error: e);
      if (mounted) {
        showAppSnackBar(context, 'Could not create chapter.', isError: true);
      }
    }
  }
}
