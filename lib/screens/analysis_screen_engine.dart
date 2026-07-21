part of 'analysis_screen.dart';

/// Engine-weakness analysis for [AnalysisScreen] — running Stockfish over the
/// player's opening trees and merging/persisting the resulting evals.
mixin _EngineWeaknessMixin on _AnalysisScreenStateBase {
  // ── Engine weakness analysis ─────────────────────────────────────

  Future<void> _showWeaknessConfig() async {
    if (_whiteTree == null && _blackTree == null) return;
    if (!EngineGate.ensureAvailable(context)) return;

    final config = await showDialog<EngineWeaknessConfig>(
      context: context,
      builder: (_) => EngineWeaknessConfigDialog(
        whiteTree: _whiteTree,
        blackTree: _blackTree,
        playerInfo: _currentPlayer,
      ),
    );

    if (config == null || !mounted) return;

    if (config.redownload) {
      final ok = await _redownloadGames(config.monthsBack);
      if (!ok) return;
      await _analyzeBothColors();
      if (!mounted) return;
    }

    _runWeaknessAnalysis(config);
  }

  Future<void> _runWeaknessAnalysis(EngineWeaknessConfig config) async {
    // Guard token: if the user switches players mid-run, results from this
    // run must not be merged or persisted under the new player.
    final player = _currentPlayer;

    _evalService?.dispose();
    final service = EngineWeaknessService();
    _evalService = service;

    setState(() {
      _evalRunning = true;
      _evalCompleted = 0;
      _evalTotal = 0;
      // Fresh run: results stream into this list as positions finish. Stale
      // evals already merged into the stats stay visible until overwritten.
      _engineEvals = [];
    });

    try {
      final results = await service.analyze(
        whiteTree: _whiteTree,
        blackTree: _blackTree,
        minOccurrences: config.minGames,
        depth: config.depth,
        onResult: (r) {
          if (!mounted || _currentPlayer != player) return;
          _engineEvals.add(r);
          // No setState: the onProgress tick right after repaints.
          _applyEvalToAnalysis(r);
        },
        onProgress: (c, t) {
          if (mounted) {
            setState(() {
              _evalCompleted = c;
              _evalTotal = t;
            });
          }
        },
      );

      if (!mounted || _currentPlayer != player) return;

      setState(() {
        _engineEvals = results;
        _evalRunning = false;
      });

      _mergeEvalsIntoAnalysis();
      _saveEngineEvals();
    } catch (e) {
      if (mounted && _currentPlayer == player) {
        setState(() => _evalRunning = false);
        _showError('Engine analysis failed: $e');
      }
    } finally {
      // Dispose only our own service: a newer run may have replaced
      // _evalService while this one was finishing.
      service.dispose();
      if (identical(_evalService, service)) _evalService = null;
    }
  }

  void _cancelEvalAnalysis() {
    _evalService?.dispose();
    _evalService = null;
    if (mounted) setState(() => _evalRunning = false);
  }

  /// Merge stored engine eval results into the current [_positionAnalysis].
  void _mergeEvalsIntoAnalysis() {
    if (_positionAnalysis == null || _engineEvals.isEmpty) return;

    int applied = 0;
    for (final r in _engineEvals) {
      if (_applyEvalToAnalysis(r)) applied++;
    }

    if (kDebugMode) {
      final forColor = _playerIsWhite ? 'white' : 'black';
      debugPrint(
        '[EvalMerge] $forColor: $applied applied '
        'of ${_engineEvals.length} total evals',
      );
    }

    setState(() {});
  }

  /// Write one eval result into the displayed colour's position stats,
  /// creating the entry if the position wasn't in the analysis. Returns
  /// false when the result belongs to the other colour (or no analysis is
  /// loaded). Does not repaint — callers batch or piggyback their setState.
  bool _applyEvalToAnalysis(EngineWeaknessResult r) {
    final analysis = _positionAnalysis;
    if (analysis == null || r.playerIsWhite != _playerIsWhite) return false;

    final key = normalizeFen(r.fen);
    var stats = analysis.positionStats[key];
    if (stats == null) {
      stats = PositionStats(
        fen: key,
        games: r.gamesPlayed,
        wins: r.wins,
        losses: r.losses,
        draws: r.draws,
      );
      analysis.positionStats[key] = stats;
    }

    stats.evalCp = r.evalCp;
    stats.evalMate = r.evalMate;
    stats.evalDepth = r.depth;
    return true;
  }

  Future<void> _saveEngineEvals() async {
    final player = _currentPlayer;
    if (player == null || _engineEvals.isEmpty) return;
    try {
      await _gamesService.saveEngineEvals(
        player.platform,
        player.username,
        _engineEvals.map((e) => e.toJson()).toList(),
      );
    } catch (e) {
      debugPrint('[AnalysisScreen] Failed to persist/load analysis: $e');
    }
  }

  Future<void> _loadEngineEvals() async {
    final player = _currentPlayer;
    if (player == null) return;
    try {
      final data = await _gamesService.loadEngineEvals(
        player.platform,
        player.username,
      );
      if (data != null && mounted) {
        _engineEvals = data
            .map(
              (e) => EngineWeaknessResult.fromJson(e as Map<String, dynamic>),
            )
            .toList();
        _mergeEvalsIntoAnalysis();
      }
    } catch (e) {
      debugPrint('[AnalysisScreen] Failed to persist/load analysis: $e');
    }
  }
}
