part of 'generation_config_form.dart';

mixin _GenerationConfigIo
    on _GenerationConfigFormStateBase, _GenerationConfigDescriptions {
  void _applyInitialConfig(TreeBuildConfig config) {
    _seedConfig = config;
    _cutoffCtrl.text = (config.minProbability * 100).toString();
    _maxPlyCtrl.text = config.maxPly.toString();
    _engineDepthCtrl.text = config.evalDepth.toString();
    _engineThreadsCtrl.text = config.engineThreads > 0
        ? config.engineThreads.toString()
        : defaultEngineThreads().toString();
    _evalGuardCtrl.text = config.maxEvalLossCp.toString();
    _minEvalCtrl.text = config.minEvalCp.toString();
    _maxEvalCtrl.text = config.maxEvalCp.toString();
    _maiaEloCtrl.text = config.maiaElo.toString();
    _oppPolicyTempCtrl.text = config.oppPolicyTemperature.toString();
    _multipvCtrl.text = config.ourMultipv.toString();
    _oppMaxChildrenCtrl.text = config.oppMaxChildren.toString();
    _oppMassTargetCtrl.text = config.oppMassTarget.toString();
    _leafConfidenceCtrl.text = config.leafConfidence.toString();
    _ourAltDiscountCtrl.text = config.ourAltDiscount.toString();
    _fastAltGapCtrl.text = config.fastAltGapCp.toString();
    _maiaPriorGamesCtrl.text = config.maiaPriorGames.toString();
    _coverMinProbCtrl.text = config.coverMinProb.toString();
    _verifyDepthCtrl.text = config.verifyDepth.toString();
    _setupMovesCtrl.text = config.setupMoves;
    _setupToleranceCtrl.text = config.setupToleranceCp.toString();
    _memorabilityToleranceCtrl.text = config.memorabilityToleranceCp.toString();
    _searchAlgorithm = config.searchAlgorithm;
    _timeBudgetCtrl.text = config.timeBudgetMinutes.toString();
    _wideOpening = config.openingWidthPlies > 0;
    _verifyFinal = config.verifyFinal;
    _trapsOnly = config.trapsOnly;
    _dbMinGamesCtrl.text = config.dbMinGames.toString();
    _dbMinProbCtrl.text = config.dbMinProb.toString();
    _minEloCtrl.text = config.minElo.toString();
    // Old snapshots may carry trapFinder, which the Build-from dropdown no
    // longer offers; an unlisted value would crash the dropdown assert.
    _buildMode = config.buildMode == BuildMode.trapFinder
        ? BuildMode.stockfishExpectimax
        : config.buildMode;
    _selectionMode = config.selectionMode;
    _relativeEval = config.relativeEval;
    _preferNovelties = config.noveltyWeight > 0;
    _engineTailCtrl.text = config.engineTailPlies.toString();
    _lineCoverageCtrl.text = (config.lineCoverageTarget * 100)
        .round()
        .toString();
    _targetLinesCtrl.text = config.targetLineCount.toString();
    _rankLinesByImportance = config.rankLinesByImportance;
    _annotationDetail = config.annotationDetail;
    _organizeIntoChapters = config.organizeIntoChapters;
    _maxLinesPerChapterCtrl.text = config.maxLinesPerChapter.toString();
    _minLinesPerChapterCtrl.text = config.minLinesPerChapter.toString();
    _modelGameCountCtrl.text = config.modelGameCount.toString();
    _modelGameMinEloCtrl.text = config.modelGameMinElo.toString();
    _refutationLines = config.refutationLines;
    _alternativeLines = config.alternativeLines;
    _useMasterGames = config.useMasterGames;
    _downloadMasterGamesIfMissing = config.downloadMasterGamesIfMissing;
    _masterDepthBonusCtrl.text = config.masterDepthBonusPlies.toString();
    _masterPriorityWeightCtrl.text = config.masterPriorityWeight.toString();
    _offBookOppMaxChildrenCtrl.text = config.offBookOppMaxChildren.toString();
    _pgnFilePaths
      ..clear()
      ..addAll(config.pgnFilePaths);
    // The skeleton card and the eval-sources section are mounted (Offstage)
    // but their states may not exist yet on the first apply; seed them after
    // the frame. Auto-expand the skeleton when non-empty so a resumed/preset
    // plan is visible, not silently carried.
    final plan = config.skeletonPlan;
    _showSkeleton = !plan.isEmpty;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _skeletonKey.currentState?.loadPlan(plan);
      _evalSourcesKey.currentState?.applyConfig(config);
    });
  }

  /// Pre-configure DB Explorer mode with the given PGN file paths and
  /// minimum game count.
  void seedDbExplorer({required List<String> pgnPaths, int minGames = 1}) {
    setState(() {
      _buildMode = BuildMode.dbExplorer;
      _pgnFilePaths
        ..clear()
        ..addAll(pgnPaths);
      _dbMinGamesCtrl.text = minGames.toString();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final panelState = _pgnSourcesKey.currentState;
      if (panelState != null) {
        final sources = pgnPaths
            .map(
              (path) => PgnSource(
                id: PgnSource.generateId(),
                name: p.basenameWithoutExtension(path),
                filePath: path,
              ),
            )
            .toList();
        panelState.seedSources(sources);
      }
    });
  }

  void setMaxPly(int maxPly) {
    _maxPlyCtrl.text = maxPly.toString();
  }

  void resetChessDbApiUsageForBuild(int quota) {
    _evalSourcesKey.currentState?.resetChessDbApiUsageForBuild(quota);
  }

  void updateChessDbApiUsage(int usedToday, int quotaLimit) {
    _evalSourcesKey.currentState?.updateChessDbApiUsage(usedToday, quotaLimit);
  }

  /// Whether the current configuration is ready to start a build.
  bool get canStart => validateBeforeStart() == null;

  /// PGN file paths for DB Explorer mode: the synced list when populated,
  /// else whatever the sources panel currently holds (covers seeding races
  /// where the panel state lands a frame later).
  List<String> _effectivePgnPaths() {
    if (_pgnFilePaths.isNotEmpty) return List.unmodifiable(_pgnFilePaths);
    final sources = _pgnSourcesKey.currentState?.sources ?? const [];
    return [
      for (final s in sources)
        if (s.filePath != null) s.filePath!,
    ];
  }

  /// Returns an error message when the current settings cannot start a build.
  String? validateBeforeStart() {
    if (_buildMode == BuildMode.trapFinder) {
      return '${_buildModeLabel(_buildMode)} is not yet available in the app.';
    }
    if (_buildMode == BuildMode.dbExplorer && _effectivePgnPaths().isEmpty) {
      final sources = _pgnSourcesKey.currentState?.sources ?? const [];
      return sources.isEmpty
          ? 'Add at least one PGN file first. Use the picker above to '
                'attach .pgn files with your games.'
          : 'The added PGN sources have no local files. Re-add them as '
                '.pgn files from disk.';
    }
    final evalSources = _evalSourcesKey.currentState;
    if (_buildMode == BuildMode.maiaDbExplore &&
        !(evalSources?.enableLocalChessDb ?? false) &&
        !(evalSources?.enableChessDbApi ?? false) &&
        !EvalDatabaseSettings.instance.enableCdbDirect) {
      setState(() => _showEvalSources = true);
      return '"Database win rates" needs at least one evaluation database. '
          'Expand "Evaluation databases" at the bottom of the form and '
          'enable a local ChessDB file or the ChessDB API.';
    }
    return null;
  }

  /// The config the form's controls currently describe.
  ///
  /// Built on top of [_seedConfig] rather than from scratch: every field with
  /// a control below is passed explicitly and wins, and every field without
  /// one is carried from the seed. That inversion is the whole point — a
  /// knob added to [TreeBuildConfig] and wired into the build but never given
  /// a widget is now *preserved* through the form instead of being reset to
  /// its constructor default on the next build.
  TreeBuildConfig toConfig({
    required String startFen,
    required bool playAsWhite,
  }) {
    final evalDepth =
        int.tryParse(_engineDepthCtrl.text.trim()) ??
        kDefaultGenerationEvalDepth;
    final rawThreads = int.tryParse(_engineThreadsCtrl.text.trim());
    final engineThreads = rawThreads != null
        ? clampEngineThreads(rawThreads)
        : defaultEngineThreads();
    final eval = _evalSourcesKey.currentState;
    final minAcceptableRaw = eval?.minAcceptableEvalDepthRaw ?? '';
    final minAcceptableDepth = minAcceptableRaw.isEmpty
        ? 0
        : (int.tryParse(minAcceptableRaw) ?? evalDepth);

    final dbSettings = EvalDatabaseSettings.instance;

    final isTrappyMode = _selectionMode == SelectionMode.trappy;
    final userMaxEvalLoss = int.tryParse(_evalGuardCtrl.text.trim()) ?? 30;
    // Colour-independent: with relativeEval on (the default) this is an
    // offset from the root's own eval, and an offset has no colour.
    final userMinEval = int.tryParse(_minEvalCtrl.text.trim()) ?? -100;

    final seed =
        _seedConfig ??
        TreeBuildConfig(startFen: startFen, playAsWhite: playAsWhite);

    return seed.copyWith(
      startFen: startFen,
      playAsWhite: playAsWhite,
      // Not a form knob, and not carried from the seed either: PlanRunner
      // sets this per build point and NodeExpander only reads it at ply 0,
      // so it describes one specific build root. A hand-started build gets
      // its own root, and inheriting a plan point's exclusions would narrow
      // it silently.
      rootReplyExclude: const [],
      minProbability: _parsePercentToFraction(
        _cutoffCtrl.text,
        fallbackPercent: 0.01,
      ),
      maxPly: int.tryParse(_maxPlyCtrl.text.trim()) ?? 20,
      buildMode: _buildMode,
      // The sources panel stays mounted in every mode; only db-explorer
      // builds may consume its files.
      pgnFilePaths: _buildMode == BuildMode.dbExplorer
          ? _effectivePgnPaths()
          : const [],
      dbMinGames: int.tryParse(_dbMinGamesCtrl.text.trim()) ?? 5,
      dbMinProb: double.tryParse(_dbMinProbCtrl.text.trim()) ?? 0.05,
      minElo: int.tryParse(_minEloCtrl.text.trim()) ?? 0,
      evalDepth: evalDepth,
      engineThreads: engineThreads,
      maxEvalLossCp: isTrappyMode
          ? (userMaxEvalLoss < 100 ? 100 : userMaxEvalLoss)
          : userMaxEvalLoss,
      minEvalCp: isTrappyMode
          ? (playAsWhite
                ? (userMinEval > -100 ? -100 : userMinEval)
                : (userMinEval > -300 ? -300 : userMinEval))
          : userMinEval,
      maxEvalCp: int.tryParse(_maxEvalCtrl.text.trim()) ?? 200,
      maiaElo: int.tryParse(_maiaEloCtrl.text.trim()) ?? 2200,
      oppPolicyTemperature:
          (double.tryParse(_oppPolicyTempCtrl.text.trim()) ?? 1.0).clamp(
            0.1,
            10.0,
          ),
      engineTailPlies: (int.tryParse(_engineTailCtrl.text.trim()) ?? 6).clamp(
        0,
        40,
      ),
      lineCoverageTarget:
          ((double.tryParse(_lineCoverageCtrl.text.trim()) ?? 92) / 100).clamp(
            0.05,
            1.0,
          ),
      targetLineCount: (int.tryParse(_targetLinesCtrl.text.trim()) ?? 0).clamp(
        0,
        100000,
      ),
      trapsOnly: _trapsOnly,
      rankLinesByImportance: _rankLinesByImportance,
      annotationDetail: _annotationDetail,
      organizeIntoChapters: _organizeIntoChapters,
      maxLinesPerChapter:
          (int.tryParse(_maxLinesPerChapterCtrl.text.trim()) ?? 40).clamp(
            1,
            100000,
          ),
      minLinesPerChapter:
          (int.tryParse(_minLinesPerChapterCtrl.text.trim()) ?? 5).clamp(
            1,
            100000,
          ),
      modelGameCount: (int.tryParse(_modelGameCountCtrl.text.trim()) ?? 6)
          .clamp(0, 100),
      modelGameMinElo: (int.tryParse(_modelGameMinEloCtrl.text.trim()) ?? 2200)
          .clamp(0, 4000),
      refutationLines: _refutationLines,
      alternativeLines: _alternativeLines,
      useMasterGames: _useMasterGames,
      downloadMasterGamesIfMissing: _downloadMasterGamesIfMissing,
      masterDepthBonusPlies:
          (int.tryParse(_masterDepthBonusCtrl.text.trim()) ?? 10).clamp(0, 40),
      masterPriorityWeight:
          (double.tryParse(_masterPriorityWeightCtrl.text.trim()) ?? 0.35)
              .clamp(0.0, 3.0),
      offBookOppMaxChildren:
          (int.tryParse(_offBookOppMaxChildrenCtrl.text.trim()) ?? 2).clamp(
            0,
            20,
          ),
      ourMultipv: int.tryParse(_multipvCtrl.text.trim()) ?? 4,
      oppMaxChildren: int.tryParse(_oppMaxChildrenCtrl.text.trim()) ?? 4,
      oppMassTarget: double.tryParse(_oppMassTargetCtrl.text.trim()) ?? 0.80,
      searchAlgorithm: _searchAlgorithm,
      timeBudgetMinutes: (int.tryParse(_timeBudgetCtrl.text.trim()) ?? 0).clamp(
        0,
        24 * 60,
      ),
      ourAltDiscount: (double.tryParse(_ourAltDiscountCtrl.text.trim()) ?? 0.25)
          .clamp(0.0, 1.0),
      fastAltGapCp: (int.tryParse(_fastAltGapCtrl.text.trim()) ?? 30).clamp(
        0,
        500,
      ),
      // "Wide opening search" on → widen the first few plies (both colors'
      // first two of our moves); off → 0 (legacy: only the root ply is wide).
      openingWidthPlies: _wideOpening ? 3 : 0,
      maiaPriorGames: double.tryParse(_maiaPriorGamesCtrl.text.trim()) ?? 30.0,
      coverMinProb: (double.tryParse(_coverMinProbCtrl.text.trim()) ?? 0.05)
          .clamp(0.0, 1.0),
      verifyFinal: _verifyFinal,
      verifyDepth: (int.tryParse(_verifyDepthCtrl.text.trim()) ?? 0).clamp(
        0,
        40,
      ),
      setupMoves: _setupMovesCtrl.text.trim(),
      skeletonPlan:
          _skeletonKey.currentState?.currentPlan() ?? const SkeletonPlan(),
      setupToleranceCp: (int.tryParse(_setupToleranceCtrl.text.trim()) ?? 30)
          .clamp(0, 500),
      // Novelties and the natural-move bias pull in opposite directions;
      // the field keeps its value but is ignored while novelties are on.
      memorabilityToleranceCp: _preferNovelties
          ? 0
          : (int.tryParse(_memorabilityToleranceCtrl.text.trim()) ?? 0).clamp(
              0,
              500,
            ),
      relativeEval: _relativeEval,
      selectionMode: _selectionMode,
      noveltyWeight: _preferNovelties ? 60 : 0,
      leafConfidence: double.tryParse(_leafConfidenceCtrl.text.trim()) ?? 1.0,
      enableCdbDirect: _cdbDirectAvailable && dbSettings.enableCdbDirect,
      cdbDirectPath: _cdbDirectAvailable ? dbSettings.cdbDirectPath : '',
      cdbDirectReadAhead: _cdbDirectAvailable && dbSettings.cdbDirectReadAhead,
      batchEvalLookups:
          _cdbDirectAvailable && (eval?.batchEvalLookups ?? false),
      enableLocalChessDb: eval?.enableLocalChessDb ?? false,
      localChessDbPath: eval?.localChessDbPath ?? '',
      enableChessDbApi: eval?.enableChessDbApi ?? false,
      chessDbApiDailyQuota: eval?.chessDbApiDailyQuota ?? 5000,
      chessDbApiConcurrency: eval?.chessDbApiConcurrency ?? 2,
      enableExtEvalSubtreeSkip: eval?.enableExtEvalSubtreeSkip ?? true,
      minAcceptableEvalDepth: minAcceptableDepth,
    );
  }

  double _parsePercentToFraction(
    String raw, {
    required double fallbackPercent,
  }) {
    final parsed = double.tryParse(raw.replaceAll('%', '').trim());
    final safePercent = (parsed ?? fallbackPercent).clamp(0.0, 100.0);
    return safePercent / 100.0;
  }
}
