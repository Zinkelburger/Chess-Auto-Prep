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
    _evalService?.dispose();
    _evalService = EngineWeaknessService();

    setState(() {
      _evalRunning = true;
      _evalCompleted = 0;
      _evalTotal = 0;
    });

    try {
      final results = await _evalService!.analyze(
        whiteTree: _whiteTree,
        blackTree: _blackTree,
        minOccurrences: config.minGames,
        depth: config.depth,
        onProgress: (c, t) {
          if (mounted) {
            setState(() {
              _evalCompleted = c;
              _evalTotal = t;
            });
          }
        },
      );

      if (!mounted) return;

      setState(() {
        _engineEvals = results;
        _evalRunning = false;
      });

      _mergeEvalsIntoAnalysis();
      _saveEngineEvals();
    } catch (e) {
      if (mounted) {
        setState(() => _evalRunning = false);
        _showError('Engine analysis failed: $e');
      }
    } finally {
      _evalService?.dispose();
      _evalService = null;
    }
  }

  void _cancelEvalAnalysis() {
    _evalService?.dispose();
    _evalService = null;
    if (mounted) setState(() => _evalRunning = false);
  }

  /// Merge stored engine eval results into the current [_positionAnalysis].
  void _mergeEvalsIntoAnalysis() {
    final analysis = _positionAnalysis;
    if (analysis == null || _engineEvals.isEmpty) return;

    int matched = 0;
    int created = 0;

    for (final r in _engineEvals) {
      if (r.playerIsWhite != _playerIsWhite) continue;

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
        created++;
      } else {
        matched++;
      }

      stats.evalCp = r.evalCp;
      stats.evalMate = r.evalMate;
      stats.evalDepth = r.depth;

      if (kDebugMode && (matched + created) <= 5) {
        debugPrint(
          '[EvalMerge] ${r.evalDisplay} '
          '(${r.gamesPlayed}g, ${(r.winRate * 100).toStringAsFixed(0)}%) '
          'FEN=$key',
        );
      }
    }

    if (kDebugMode) {
      final forColor = _playerIsWhite ? 'white' : 'black';
      debugPrint(
        '[EvalMerge] $forColor: $matched matched, '
        '$created created, ${_engineEvals.length} total evals',
      );
    }

    setState(() {});
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
