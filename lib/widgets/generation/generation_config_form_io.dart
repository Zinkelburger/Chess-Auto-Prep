part of 'generation_config_form.dart';

mixin _GenerationConfigIo
    on _GenerationConfigFormStateBase, _GenerationConfigDescriptions {
  void _applyInitialConfig(TreeBuildConfig config) {
    _seedConfig = config;
    _searchAlgorithm = config.isRollingSearch
        ? SearchAlgorithm.rolling
        : SearchAlgorithm.pure;
    _maxPlyCtrl.text = config.maxPly.toString();

    _evalGuardCtrl.text = config.maxEvalLossCp.toString();
    _maiaEloCtrl.text = config.maiaElo.toString();
    _oppMaxChildrenCtrl.text = config.oppMaxChildren.toString();
    _oppMassTargetCtrl.text = config.oppMassTarget.toString();
    _timeBudgetCtrl.text = config.timeBudgetMinutes.toString();
    _verifyFinal = config.verifyFinal;
    _trapsOnly = config.trapsOnly;
    _dbMinGamesCtrl.text = config.dbMinGames.toString();
    _dbMinProbCtrl.text = config.dbMinProb.toString();
    _minEloCtrl.text = config.minElo.toString();
    _buildMode = config.buildMode;
    _selectionMode = config.selectionMode;
    _engineTailCtrl.text = config.engineTailPlies.toString();
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
    _bookTailMaxPlyCtrl.text = config.bookTailMaxPly.toString();
    _bookTieBreakCtrl.text = config.bookTieBreakWindowCp.toString();
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
    final databases = context.read<EvalDatabaseSettings>();
    if (databases.state.committed == null) {
      return 'Load saved evaluation database preferences before starting. Retry above if loading failed.';
    }
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
        !databases.committed.enableCdbDirect) {
      setState(() => _showEvalSources = true);
      return '"Database win rates" needs at least one evaluation database. '
          'Expand "Evaluation databases" at the bottom of the form and '
          'enable a local ChessDB file or the ChessDB API.';
    }
    if (_buildMode == BuildMode.chessDbBook &&
        !_evalSources.enableChessDbApi &&
        !databases.committed.enableCdbDirect) {
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
    final evalDepth = context.read<BulkAnalysisSettings>().depth;
    final engineThreads = context.read<EngineSettings>().cores;

    final seed = _configSeed;

    final config = seed.copyWith(
      startFen: startFen,
      playAsWhite: playAsWhite,
      // Not a form knob, and not carried from the seed either: PlanRunner
      // sets this per build point and NodeExpander only reads it at ply 0,
      // so it describes one specific build root. A hand-started build gets
      // its own root, and inheriting a plan point's exclusions would narrow
      // it silently.
      rootReplyExclude: const [],
      minProbability: (seed.minProbability * 100).clamp(0.0, 100.0) / 100,
      maxPly: int.tryParse(_maxPlyCtrl.text.trim()) ?? 4,
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
      maiaElo: int.tryParse(_maiaEloCtrl.text.trim()) ?? 2200,
      oppPolicyTemperature: seed.oppPolicyTemperature.clamp(0.1, 10.0),
      engineTailPlies: (int.tryParse(_engineTailCtrl.text.trim()) ?? 6).clamp(
        0,
        40,
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
      useMasterGames:
          _buildMode != BuildMode.stockfishExpectimax && _useMasterGames,
      downloadMasterGamesIfMissing:
          _buildMode != BuildMode.stockfishExpectimax &&
          _downloadMasterGamesIfMissing,
      masterDepthBonusPlies: seed.masterDepthBonusPlies.clamp(0, 40),
      masterPriorityWeight: seed.masterPriorityWeight.clamp(0.0, 3.0),
      offBookOppMaxChildren: seed.offBookOppMaxChildren.clamp(0, 20),
      bookTailMaxPly: (int.tryParse(_bookTailMaxPlyCtrl.text.trim()) ?? 40)
          .clamp(0, 200),
      bookTieBreakWindowCp: (int.tryParse(_bookTieBreakCtrl.text.trim()) ?? 0)
          .clamp(0, 200),
      replyWindowCp: seed.replyWindowCp.clamp(0, 200),
      oppMaxChildren: int.tryParse(_oppMaxChildrenCtrl.text.trim()) ?? 4,
      oppMassTarget: double.tryParse(_oppMassTargetCtrl.text.trim()) ?? 0.80,
      searchAlgorithm: _searchAlgorithm,
      timeBudgetMinutes: (int.tryParse(_timeBudgetCtrl.text.trim()) ?? 0).clamp(
        0,
        24 * 60,
      ),
      ourAltDiscount: seed.ourAltDiscount.clamp(0.0, 1.0),
      fastAltGapCp: seed.fastAltGapCp.clamp(0, 500),
      openingWidthPlies: seed.openingWidthPlies > 0
          ? seed.openingWidthPlies
          : 0,
      coverMinProb: seed.coverMinProb.clamp(0.0, 1.0),
      // Verification is not merely off in these modes, it is meaningless:
      // the move came from a database, and re-ranking it by a local search
      // would replace the answer with a different one.
      verifyFinal: _verifyFinal && !_noVerifyMode,
      verifyDepth: seed.verifyDepth.clamp(0, 40),
      setupMoves: seed.setupMoves.trim(),
      skeletonPlan: _skeleton.currentPlan(playAsWhite: playAsWhite),
      setupToleranceCp: seed.setupToleranceCp.clamp(0, 500),
      // Preserve the preset policy: novelty disables natural-move bias.
      memorabilityToleranceCp: seed.noveltyWeight > 0
          ? 0
          : seed.memorabilityToleranceCp.clamp(0, 500),
      // A ChessDB book has one child at each of our nodes, so every
      // selection mode picks the same move. Pin it so the form and the
      // summary say what actually runs.
      selectionMode: _buildMode == BuildMode.chessDbBook
          ? SelectionMode.engineOnly
          : _selectionMode,
      noveltyWeight: seed.noveltyWeight > 0 ? seed.noveltyWeight : 0,
    );

    return _evalSources.applyTo(
      _buildMode != BuildMode.stockfishExpectimax
          ? config
          : config.copyWith(
              noveltyWeight: 0,
              leafConfidence: 1,
              memorabilityToleranceCp: 0,
              setupMoves: '',
              skeletonPlan: const SkeletonPlan(),
              replyWindowCp: 0,
              oppPolicyTemperature: 1,
              masterPriorityWeight: 0,
              masterDepthBonusPlies: 0,
              selectionMode: SelectionMode.expectimax,
              engineTailPlies: 0,
            ),
      databases: context.read<EvalDatabaseSettings>().committed,
      cdbDirectAvailable: _cdbDirectAvailable,
      engineEvalDepth: evalDepth,
    );
  }
}
