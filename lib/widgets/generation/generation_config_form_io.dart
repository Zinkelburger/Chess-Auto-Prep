part of 'generation_config_form.dart';

mixin _GenerationConfigIo
    on _GenerationConfigFormStateBase, _GenerationConfigDescriptions {
  void _applyInitialConfig(TreeBuildConfig config) {
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
    _searchAlgorithm = config.searchAlgorithm;
    _verifyFinal = config.verifyFinal;
    _dbMinGamesCtrl.text = config.dbMinGames.toString();
    _dbMinProbCtrl.text = config.dbMinProb.toString();
    _minEloCtrl.text = config.minElo.toString();
    _lichessMinGamesCtrl.text = config.minGames.toString();
    _buildMode = config.buildMode;
    _selectionMode = config.selectionMode;
    _relativeEval = config.relativeEval;
    _preferNovelties = config.noveltyWeight > 0;
    _rankLinesByImportance = config.rankLinesByImportance;
    _annotateMoveProbabilities = config.annotateMoveProbabilities;
    _annotateMaiaOnly = config.annotateMaiaOnly;
    _pgnFilePaths
      ..clear()
      ..addAll(config.pgnFilePaths);
    if (config.useLichessDb) {
      _lichessDbOverride = config.useMasters
          ? LichessDatabase.masters
          : LichessDatabase.lichess;
    } else {
      _lichessDbOverride = null;
    }
    _lichessSpeeds
      ..clear()
      ..addAll(config.speeds.split(',').where((s) => s.isNotEmpty));
    _lichessRatings
      ..clear()
      ..addAll(config.ratingRange.split(',').where((s) => s.isNotEmpty));
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
      return 'DB Win Rate mode needs at least one eval source enabled '
          '(local ChessDB, cdbdirect, or ChessDB API).';
    }
    return null;
  }

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
    final userMinEval =
        int.tryParse(_minEvalCtrl.text.trim()) ?? (playAsWhite ? 0 : -100);

    return TreeBuildConfig(
      startFen: startFen,
      playAsWhite: playAsWhite,
      minProbability: _parsePercentToFraction(
        _cutoffCtrl.text,
        fallbackPercent: 0.01,
      ),
      maxPly: int.tryParse(_maxPlyCtrl.text.trim()) ?? 20,
      buildMode: _buildMode,
      pgnFilePaths: _effectivePgnPaths(),
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
      maxEvalCp:
          int.tryParse(_maxEvalCtrl.text.trim()) ?? (playAsWhite ? 200 : 100),
      maiaElo: int.tryParse(_maiaEloCtrl.text.trim()) ?? 2200,
      maiaOnly: _lichessDbOverride == null,
      rankLinesByImportance: _rankLinesByImportance,
      annotateMoveProbabilities: _annotateMoveProbabilities,
      annotateMaiaOnly: _annotateMaiaOnly,
      ourMultipv: int.tryParse(_multipvCtrl.text.trim()) ?? 4,
      oppMaxChildren: int.tryParse(_oppMaxChildrenCtrl.text.trim()) ?? 4,
      oppMassTarget: double.tryParse(_oppMassTargetCtrl.text.trim()) ?? 0.80,
      searchAlgorithm: _searchAlgorithm,
      ourAltDiscount: (double.tryParse(_ourAltDiscountCtrl.text.trim()) ?? 0.25)
          .clamp(0.0, 1.0),
      fastAltGapCp: (int.tryParse(_fastAltGapCtrl.text.trim()) ?? 30).clamp(
        0,
        500,
      ),
      maiaPriorGames: double.tryParse(_maiaPriorGamesCtrl.text.trim()) ?? 30.0,
      coverMinProb: (double.tryParse(_coverMinProbCtrl.text.trim()) ?? 0.05)
          .clamp(0.0, 1.0),
      verifyFinal: _verifyFinal,
      verifyDepth: (int.tryParse(_verifyDepthCtrl.text.trim()) ?? 0).clamp(
        0,
        40,
      ),
      setupMoves: _setupMovesCtrl.text.trim(),
      setupToleranceCp: (int.tryParse(_setupToleranceCtrl.text.trim()) ?? 30)
          .clamp(0, 500),
      useLichessDb: _lichessDbOverride != null,
      useMasters: _lichessDbOverride == LichessDatabase.masters,
      speeds: _lichessSpeeds.join(','),
      ratingRange: (_lichessRatings.toList()..sort()).join(','),
      minGames: int.tryParse(_lichessMinGamesCtrl.text.trim()) ?? 10,
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
