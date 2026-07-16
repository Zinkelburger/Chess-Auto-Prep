part of 'unified_engine_pane.dart';

mixin _EnginePaneAnalysis on _UnifiedEnginePaneStateBase {
  void _scheduleAnalysis() {
    if (_analysisScheduled) return;
    _analysisScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _analysisScheduled = false;
      if (!mounted || !_isActive) return;
      _runAnalysis();
    });
  }

  void _scheduleSetState() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _onLifecycleChanged() {
    if (!mounted) return;
    final state = EngineLifecycle.instance.state;
    final prev = _lastLifecycleState;
    _lastLifecycleState = state;

    if (!_isActive) {
      if (prev != state) _analysis.cancel();
      _scheduleSetState();
      return;
    }

    // Restart only when engine becomes usable again (toggle on / exit generation),
    // not when analysis finishes (analyzing → idle) or we enter analyzing.
    final becameUsable =
        (prev == null ||
            prev == EngineState.off ||
            prev == EngineState.generating) &&
        (state == EngineState.idle || state == EngineState.analyzing) &&
        !(prev == null && state == EngineState.analyzing);
    if (becameUsable) {
      _scheduleAnalysis();
    }
    _scheduleSetState();
  }

  void _onSettingsChanged() {
    final revision = _settings.analysisConfigRevision;
    final configChanged = revision != _analysisConfigRevision;
    if (configChanged) {
      _analysisConfigRevision = revision;
      _analysisCache.remove(widget.fen);
      if (_isActive) {
        _scheduleAnalysis();
      }
    }
    _scheduleSetState();
  }

  void _runAnalysis() {
    if (kDebugMode) {
      final shortFen = widget.fen.split(' ').take(2).join(' ');
      log.i('[Engine] ── _runAnalysis() for $shortFen ──');
    }

    EngineLifecycle.instance.onPositionChanged(widget.fen);
    _trySaveCurrentToCache();
    _analysis.beginEnginePaneAnalysis(widget.fen);
    _initialAnalysisStarted = false;
    _startInitialAnalysis();
  }

  // ── Analysis Pipeline ─────────────────────────────────────────────────

  Future<void> _startInitialAnalysis() async {
    if (!mounted || _initialAnalysisStarted) return;
    _initialAnalysisStarted = true;
    _selectedMoveUcis = [];
    _maiaProbs = null;

    final myGen = ++_analysisGeneration;
    final shortFen = widget.fen.split(' ').take(2).join(' ');

    _perfReset();
    _perfLog('_startInitialAnalysis BEGIN for $shortFen');
    _currentAnalysisFen = widget.fen;

    // ── Check cache ──
    final cached = _analysisCache[widget.fen];
    if (cached != null) {
      _perfLog('Cache HIT — restoring snapshot');
      _restoreFromCache(cached);
      return;
    }

    final useStockfish = _settings.showStockfish;
    final useMaia =
        _settings.showMaia &&
        _settings.fetchMaiaForOpponent &&
        MaiaFactory.isAvailable &&
        MaiaFactory.instance != null;

    _perfLog(
      'Pipeline START — SF=${useStockfish ? "ON" : "OFF"}, '
      'Maia=${useMaia ? "ON" : "OFF"}, DB=OFF',
    );

    try {
      // ── Fire all sources in parallel ──
      final discoveryFuture = useStockfish
          ? _analysis.runDiscovery(
              fen: widget.fen,
              depth: _settings.depth,
              multiPv: _settings.multiPv,
            )
          : Future.value(const DiscoveryResult());

      final maiaFuture = useMaia
          ? _runMaiaAnalysis()
          : Future.value(<String, double>{});

      // ── Await all ──
      final results = await Future.wait<Object?>([discoveryFuture, maiaFuture]);

      if (!mounted || _analysisGeneration != myGen) {
        _analysis.endEnginePaneAnalysis(widget.fen);
        return;
      }

      final discovery = results[0] as DiscoveryResult;
      _maiaProbs = results[1] as Map<String, double>;
      final dbData = _probabilityService.currentPosition.value;

      _perfLog('All sources complete');

      // ── Filter candidates ──
      final sfUcis = discovery.lines
          .map((l) => l.moveUci)
          .where((u) => u.isNotEmpty)
          .toList();

      final candidates = _filterCandidates(sfUcis, _maiaProbs!, dbData);
      _selectedMoveUcis = candidates;

      _perfLog(
        'Filtered ${candidates.length} candidates '
        '(${sfUcis.length} SF + '
        '${candidates.length - sfUcis.length} Maia/DB)',
      );

      // ── Start evaluation phase ──
      _analysis.startEvaluation(
        baseFen: widget.fen,
        moveUcis: candidates,
        evalDepth: _settings.depth,
      );

      _scheduleSetState();
    } catch (e) {
      _analysis.endEnginePaneAnalysis(widget.fen);
      if (kDebugMode) log.e('[Engine] Pipeline FAILED — $e');
      rethrow;
    }
  }

  /// Filter candidates: SF moves always included.
  /// Non-SF moves: include only if Maia >= 2% OR DB >= 2%.
  /// Capped at maxAnalysisMoves.
  List<String> _filterCandidates(
    List<String> sfUcis,
    Map<String, double> maiaProbs,
    ExplorerResponse? dbData,
  ) {
    final sfSet = sfUcis.toSet();
    final candidates = <String>[...sfUcis];
    final seen = Set<String>.from(sfUcis);

    final nonSfCandidates = <String>{};
    for (final uci in maiaProbs.keys) {
      if (!sfSet.contains(uci)) nonSfCandidates.add(uci);
    }
    if (dbData != null) {
      for (final m in dbData.moves) {
        if (m.uci.isNotEmpty && !sfSet.contains(m.uci)) {
          nonSfCandidates.add(m.uci);
        }
      }
    }

    final scored = <MapEntry<String, double>>[];
    for (final uci in nonSfCandidates) {
      if (seen.contains(uci)) continue;
      final maiaP = maiaProbs[uci] ?? 0.0;
      double dbP = 0.0;
      if (dbData != null) {
        for (final m in dbData.moves) {
          if (m.uci == uci) {
            dbP = m.playRate;
            break;
          }
        }
      }

      if (maiaP < 0.02 && dbP < 2.0) continue;

      final score = math.max(maiaP * 100, dbP);
      scored.add(MapEntry(uci, score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));

    final extraSlots = _settings.maxAnalysisMoves - candidates.length;
    for (int i = 0; i < scored.length && i < extraSlots; i++) {
      candidates.add(scored[i].key);
    }

    return candidates;
  }

  // ── Source helpers ──────────────────────────────────────────────────────

  Future<Map<String, double>> _runMaiaAnalysis() async {
    if (!MaiaFactory.isAvailable || MaiaFactory.instance == null) {
      return {};
    }
    _perfLog('Maia inference START');
    try {
      final result = await MaiaFactory.instance!.evaluate(
        widget.fen,
        _settings.maiaElo,
      );
      _perfLog('Maia inference DONE — ${result.policy.length} moves');
      return result.policy;
    } catch (e) {
      _perfLog('Maia FAILED — $e');
      return {};
    }
  }

  // ── Cache ──────────────────────────────────────────────────────────────

  void _restoreFromCache(_PositionSnapshot cached) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _selectedMoveUcis = List.from(cached.selectedMoveUcis);
      _maiaProbs = Map.from(cached.maiaProbs);
      _analysis.results.value = Map.from(cached.poolResults);
      _analysis.discoveryResult.value = cached.discoveryResult;

      // Restore DB data so the merge table shows correct play rates.
      _probabilityService.currentPosition.value = cached.dbResponse;

      _analysis.poolStatus.value = PoolStatus(
        phase: 'complete',
        totalMoves: cached.selectedMoveUcis.length,
        completedMoves: cached.poolResults.length,
      );

      _scheduleSetState();
    });
  }

  void _trySaveCurrentToCache() {
    if (_selectedMoveUcis.isEmpty || _maiaProbs == null) return;
    if (!_analysis.poolStatus.value.isComplete) return;

    final fen = _currentAnalysisFen;
    if (fen == null) return;
    _analysisCache[fen] = _PositionSnapshot(
      selectedMoveUcis: List.from(_selectedMoveUcis),
      maiaProbs: Map.from(_maiaProbs!),
      poolResults: Map.from(_analysis.results.value),
      discoveryResult: _analysis.discoveryResult.value,
      dbResponse: _probabilityService.currentPosition.value,
    );

    while (_analysisCache.length > _maxCacheSize) {
      _analysisCache.remove(_analysisCache.keys.first);
    }

    _persistBestEvalToCache(fen);
  }

  void _persistBestEvalToCache(String fen) {
    final discovery = _analysis.discoveryResult.value;
    if (discovery.lines.isEmpty) return;
    final best = discovery.lines.first;
    final cp = best.scoreCp;
    if (cp == null) return;
    EvalCache.instance.putEvalCpWhite(fen, cp, best.depth);
  }

  void _onPoolStatusChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ps = _analysis.poolStatus.value;
      if (ps.isComplete) {
        EngineLifecycle.instance.onAnalysisComplete();
        _analysis.endEnginePaneAnalysis(_currentAnalysisFen);
        _perfLog(
          'Evaluation COMPLETE — ${_analysis.results.value.length} evals',
        );
        _trySaveCurrentToCache();
      }
    });
  }
}
