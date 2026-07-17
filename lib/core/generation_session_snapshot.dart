part of 'generation_session_controller.dart';

/// Snapshot export — writing the lines found so far to a **new** repertoire
/// file while the run continues.  Split out of [GenerationSessionController]
/// by pure code motion.  `on _GenerationProgress` gives it the observable
/// progress fields (phase/depth) it reads; the remaining run state is
/// supplied by the controller through abstract accessors.
mixin _SnapshotExport on _GenerationProgress {
  bool _snapshotExporting = false;

  /// Live status of an in-flight snapshot export, shown in the Jobs panel.
  /// Null when no snapshot is running.
  String? snapshotStatus;

  bool get isSnapshotExporting => _snapshotExporting;

  // Shared run state owned by the controller.
  bool get _cancelRequested;
  GenerationRequest? get _activeRequest;
  List<String> get _startMoveSequence;
  TreeBuildService get buildService;

  // ── Snapshot export (lines-so-far while the run continues) ──────────

  /// Suggested repertoire name for a snapshot export at the current depth.
  String snapshotNameSuggestion() {
    final path = _activeRequest?.repertoireFilePath;
    final base = (path == null || path.isEmpty)
        ? 'Generated'
        : p.basenameWithoutExtension(path);
    return '$base d$progressDepth snapshot';
  }

  /// Export the lines the build has found so far to a **new** repertoire
  /// file named [repertoireName], without ending the run.
  ///
  /// Unverified exports serialize the tree and run every phase in a
  /// background isolate — the build keeps exploring throughout.  When
  /// [verify] is set (and the config uses Stockfish), exploration pauses
  /// while the engine re-checks the snapshot's chosen moves (the pool is
  /// shared with the build), then resumes automatically.
  ///
  /// Returns (success, user-facing message).
  Future<(bool, String)> exportSnapshot({
    required String repertoireName,
    required bool verify,
  }) async {
    if (!_isGenerating ||
        _cancelRequested ||
        progressPhase != GenerationPhase.buildingTree) {
      return (false, 'No active build to export from.');
    }
    if (_snapshotExporting) {
      return (false, 'A snapshot export is already running.');
    }
    final request = _activeRequest;
    final config = activeConfig;
    final tree = buildService.currentTree;
    if (request == null || config == null || tree == null) {
      return (false, 'Build state unavailable — try again in a moment.');
    }

    final name = repertoireName.trim();
    if (name.isEmpty) return (false, 'Please enter a repertoire name.');
    final storage = StorageFactory.instance;
    final targetPath = await storage.repertoireFilePath(name);
    if (await storage.fileExists(targetPath)) {
      return (false, 'A repertoire named "$name" already exists.');
    }

    final depth = progressDepth;
    final doVerify = verify && config.needsStockfish;
    // Verification shares the engine pool with the build, so exploration
    // pauses for its duration.  Unverified exports never touch the run.
    final pausedForVerify = doVerify && !_isPaused;

    _snapshotExporting = true;
    _setSnapshotStatus('Snapshot: preparing (depth $depth)…');
    try {
      if (pausedForVerify) buildService.pauseBuild();

      // Synchronous, so atomic w.r.t. the async build loop — the copy is a
      // consistent point-in-time snapshot even while BFS continues.
      final exportRequest = SnapshotExportRequest(
        treeJson: serializeTree(tree),
        configJson: Map<String, dynamic>.from(config.toJson()),
        prefix: List<String>.from(_startMoveSequence),
        repertoireStartFen: request.repertoireStartFen,
        stopAfterSelection: doVerify,
      );

      _setSnapshotStatus('Snapshot: computing lines (depth $depth)…');
      final result = await Isolate.run(() => runSnapshotExport(exportRequest));

      var pgnEntries = result.pgnEntries;
      String verifyNote = 'unverified';
      if (doVerify) {
        final snapTree = deserializeTree(result.selectedTreeJson!);
        final fenMap = FenMap()..populate(snapTree.root);
        final ecaCalc = ExpectimaxCalculator(config: config, fenMap: fenMap);
        var verified = false;
        try {
          _setSnapshotStatus(
            'Snapshot: verifying (depth ${config.resolvedVerifyDepth})…',
          );
          if (StockfishPool.instance.workerCount == 0) {
            await StockfishPool.instance.prepareForTreeBuild(
              config.resolvedEngineThreads,
            );
          }
          final verifier = RepertoireVerifier(config: config);
          final report = await verifier.verify(
            snapTree,
            fenMap: fenMap,
            ecaCalc: ecaCalc,
            isCancelled: () => _cancelRequested,
            onStatus: (s) => _setSnapshotStatus('Snapshot: $s'),
          );
          verified = report.completed;
        } catch (e) {
          // Verification is best-effort; export the unverified selection.
          debugPrint('[Snapshot] verification failed: $e');
        }
        // Engine is free again — resume exploration before the extraction
        // walk, which only reads the snapshot copy.
        if (pausedForVerify && !_isPaused) buildService.resumeBuild();
        _setSnapshotStatus('Snapshot: extracting lines…');
        pgnEntries = extractSnapshotLines(
          tree: snapTree,
          config: config,
          fenMap: fenMap,
          prefix: List<String>.from(_startMoveSequence),
          repertoireStartFen: request.repertoireStartFen,
        );
        verifyNote = verified
            ? 'verified at depth ${config.resolvedVerifyDepth}'
            : 'verification incomplete';
      }

      if (pgnEntries.isEmpty) {
        return (
          false,
          'Snapshot produced no lines yet — let the build explore deeper.',
        );
      }

      final header =
          '// $name Repertoire\n'
          '// Color: ${config.playAsWhite ? 'White' : 'Black'}\n'
          '// Created on ${DateTime.now().toString().split('.')[0]}\n'
          '// Snapshot at depth $depth ($verifyNote) from an in-progress '
          'generation run.\n';
      final buffer = StringBuffer(header);
      for (final pgn in pgnEntries) {
        buffer.writeln();
        buffer.writeln(pgn);
      }
      await storage.writeFile(targetPath, buffer.toString());
      return (
        true,
        'Exported ${pgnEntries.length} lines to "$name" ($verifyNote).',
      );
    } catch (e) {
      debugPrint('[Snapshot] export failed: $e');
      return (false, 'Snapshot export failed: $e');
    } finally {
      if (pausedForVerify && !_isPaused) buildService.resumeBuild();
      _snapshotExporting = false;
      snapshotStatus = null;
      notifyListeners();
    }
  }

  void _setSnapshotStatus(String status) {
    snapshotStatus = status;
    notifyListeners();
  }
}
