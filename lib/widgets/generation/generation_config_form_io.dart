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
    _buildMode = config.buildMode;
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
    _chaptersByEco = config.chaptersByEco;
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
    _bookTailMaxPlyCtrl.text = config.bookTailMaxPly.toString();
    _bookTieBreakCtrl.text = config.bookTieBreakWindowCp.toString();
    _replyWindowCtrl.text = config.replyWindowCp.toString();
    _mistakeWeightCtrl.text = config.mistakeWeight.toString();
    // The three sub-editors keep their state in controllers this form owns,
    // so seeding them needs neither a mounted widget nor a post-frame hop.
    //
    // An empty path list is "this config says nothing about PGN files" —
    // every config built outside DB Explorer has one — rather than "drop the
    // files the user attached", so applying a preset does not empty the
    // panel.
    if (config.pgnFilePaths.isNotEmpty) {
      _pgnSources.seedFromPaths(config.pgnFilePaths);
    }
    _evalSources.applyConfig(config);
    _skeleton.loadPlan(config.skeletonPlan);
    // Auto-expand the skeleton when non-empty so a resumed/preset plan is
    // visible, not silently carried.
    _showSkeleton = !config.skeletonPlan.isEmpty;
  }

  /// Pre-configure DB Explorer mode with the given PGN file paths and
  /// minimum game count.
  void seedDbExplorer({required List<String> pgnPaths, int minGames = 1}) {
    setState(() {
      _buildMode = BuildMode.dbExplorer;
      _dbMinGamesCtrl.text = minGames.toString();
    });
    _pgnSources.seedFromPaths(pgnPaths);
  }

  void setMaxPly(int maxPly) {
    _maxPlyCtrl.text = maxPly.toString();
  }

  /// The Max line length field as typed; the unfinished-build card reads it
  /// to say what depth a resume will continue to.
  String get maxPlyText => _maxPlyCtrl.text;

  /// Fires as the Max line length field changes.
  Listenable get maxPlyListenable => _maxPlyCtrl;

  /// A build is starting: the ChessDB usage line counts this run, from zero.
  void resetChessDbApiUsageForBuild(int quota) {
    _evalSources.resetApiUsageForBuild(quota);
  }

  /// Returns an error message when the current settings cannot start a build.
  String? validateBeforeStart() {
    final numError = _firstNumFieldError();
    if (numError != null) return numError;
    if (_buildMode == BuildMode.dbExplorer && _pgnSources.filePaths.isEmpty) {
      return _pgnSources.isEmpty
          ? 'Add at least one PGN file first. Use the picker above to '
                'attach .pgn files with your games.'
          : 'The added PGN sources have no local files. Re-add them as '
                '.pgn files from disk.';
    }
    if (_buildMode == BuildMode.maiaDbExplore &&
        !_evalSources.enableLocalChessDb &&
        !_evalSources.enableChessDbApi &&
        !EvalDatabaseSettings.instance.enableCdbDirect) {
      setState(() => _showEvalSources = true);
      return '"Database win rates" needs at least one evaluation database. '
          'Expand "Evaluation databases" at the bottom of the form and '
          'enable a local ChessDB file or the ChessDB API.';
    }
    if (_buildMode == BuildMode.chessDbBook &&
        !_evalSources.enableChessDbApi &&
        !EvalDatabaseSettings.instance.enableCdbDirect) {
      setState(() => _showEvalSources = true);
      return 'The ChessDB mainline book needs ChessDB itself. Expand '
          '"Evaluation databases" at the bottom of the form and enable the '
          'local ChessDB dump (fastest, no quota) or the ChessDB API. The '
          'local eval database holds scores, not move lists, so it cannot '
          'drive this mode on its own.';
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
  ///
  /// The eval-source half is delegated to [EvalSourcesController.applyTo],
  /// which sits beside its own `applyConfig` so the two halves of that round
  /// trip cannot drift apart.
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

    final seed =
        _seedConfig ??
        TreeBuildConfig(startFen: startFen, playAsWhite: playAsWhite);

    final config = seed.copyWith(
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
      // The sources panel keeps its files across a trip through another
      // build source; only db-explorer builds may consume them.
      pgnFilePaths: _buildMode == BuildMode.dbExplorer
          ? _pgnSources.filePaths
          : const [],
      dbMinGames: int.tryParse(_dbMinGamesCtrl.text.trim()) ?? 5,
      dbMinProb: double.tryParse(_dbMinProbCtrl.text.trim()) ?? 0.05,
      minElo: int.tryParse(_minEloCtrl.text.trim()) ?? 0,
      evalDepth: evalDepth,
      engineThreads: engineThreads,
      maxEvalLossCp: int.tryParse(_evalGuardCtrl.text.trim()) ?? 30,
      // Colour-independent: with relativeEval on (the default) this is an
      // offset from the root's own eval, and an offset has no colour.
      minEvalCp: int.tryParse(_minEvalCtrl.text.trim()) ?? -100,
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
      chaptersByEco: _chaptersByEco,
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
      bookTailMaxPly: (int.tryParse(_bookTailMaxPlyCtrl.text.trim()) ?? 40)
          .clamp(0, 200),
      bookTieBreakWindowCp: (int.tryParse(_bookTieBreakCtrl.text.trim()) ?? 0)
          .clamp(0, 200),
      replyWindowCp: (int.tryParse(_replyWindowCtrl.text.trim()) ?? 0).clamp(
        0,
        200,
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
      // A seed that carried its own width keeps it: the checkbox says
      // whether to widen, not by how much.
      openingWidthPlies: _wideOpening
          ? (seed.openingWidthPlies > 0 ? seed.openingWidthPlies : 3)
          : 0,
      maiaPriorGames: double.tryParse(_maiaPriorGamesCtrl.text.trim()) ?? 30.0,
      coverMinProb: (double.tryParse(_coverMinProbCtrl.text.trim()) ?? 0.05)
          .clamp(0.0, 1.0),
      // Verification is not merely off in these modes, it is meaningless:
      // the move came from a database, and re-ranking it by a local search
      // would replace the answer with a different one.
      verifyFinal: _verifyFinal && !_noVerifyMode,
      verifyDepth: (int.tryParse(_verifyDepthCtrl.text.trim()) ?? 0).clamp(
        0,
        40,
      ),
      setupMoves: _setupMovesCtrl.text.trim(),
      skeletonPlan: _skeleton.currentPlan(playAsWhite: playAsWhite),
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
      // A ChessDB book has one child at each of our nodes, so every
      // selection mode picks the same move. Pin it so the form and the
      // summary say what actually runs.
      selectionMode: _buildMode == BuildMode.chessDbBook
          ? SelectionMode.engineOnly
          : _selectionMode,
      // Same as the opening width: on keeps a seed's own weight.
      noveltyWeight: _preferNovelties
          ? (seed.noveltyWeight > 0 ? seed.noveltyWeight : 60)
          : 0,
      mistakeWeight: (int.tryParse(_mistakeWeightCtrl.text.trim()) ?? 0).clamp(
        0,
        100,
      ),
      leafConfidence: double.tryParse(_leafConfidenceCtrl.text.trim()) ?? 1.0,
    );

    return _evalSources.applyTo(
      config,
      databases: EvalDatabaseSettings.instance,
      cdbDirectAvailable: _cdbDirectAvailable,
      engineEvalDepth: evalDepth,
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
