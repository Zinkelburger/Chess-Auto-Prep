part of 'analysis_screen.dart';

/// Trick-hunt (tricky near-best moves and novelties against the displayed
/// colour's tree) support for [AnalysisScreen] — running, cancelling,
/// persisting and restoring reports.
mixin _TrickHuntMixin on _AnalysisScreenStateBase {
  Future<void> _showTrickHuntConfig() async {
    final player = _currentPlayer;
    if (player == null || _openingTree == null || _isTrickHunting) return;
    if (!EngineGate.ensureAvailable(context)) return;
    // The whole hunt is Maia expectimax probes — without the model there is
    // nothing to run, so refuse before showing the dialog.
    if (!MaiaFactory.isAvailable) {
      _showError(
        'Find Tricks needs the Maia human model, which is not available '
        'on this machine.',
      );
      return;
    }
    if (GenerationLease.isBusy) {
      _showError(
        'Another engine job is running — '
        'wait for it to finish first.',
      );
      return;
    }

    final config = await showDialog<TrickHuntConfig>(
      context: context,
      builder: (_) => TrickHuntConfigDialog(
        playerName: player.username,
        treeIsWhite: _playerIsWhite,
        initialConfig: _tricksConfigs[_playerIsWhite],
      ),
    );
    if (config == null || !mounted) return;

    unawaited(_runTrickHunt(config));
  }

  Future<void> _runTrickHunt(TrickHuntConfig config) async {
    final player = _currentPlayer;
    final tree = _openingTree;
    if (player == null || tree == null) return;
    final isWhite = _playerIsWhite;

    setState(() {
      _isTrickHunting = true;
      _trickHuntIsWhite = isWhite;
      _trickHuntCancelled = false;
      _tricksLive = [];
      _tricksProgress = null;
      _tricksResults[isWhite] = null;
      _tricksConfigs[isWhite] = config;
      _trickProbesSkipped = false;
    });

    // Snapshot the games file's mtime: a re-download during the hunt clears
    // the (now stale) trick reports, and a report computed from the old
    // tree must not resurrect them.
    final pgnPath = await _gamesService.analysisPgnPath(
      player.platform,
      player.username,
    );
    final pgnModifiedAtStart = await fileModifiedOrNull(pgnPath);

    try {
      final result = await GenerationLease.run(() {
        return _trickService.hunt(
          tree: tree,
          playerIsWhite: isWhite,
          config: config,
          onProgress: (p) {
            if (mounted && _currentPlayer == player) {
              setState(() => _tricksProgress = p);
            }
          },
          onFinding: (f) {
            if (mounted && _currentPlayer == player) {
              setState(() => _tricksLive = [..._tricksLive, f]);
            }
          },
        );
      });

      // Persist to the player the hunt was started for, even if the user
      // switched players meanwhile (partial reports included) — but not if
      // the games were replaced mid-hunt.
      final pgnModifiedNow = await fileModifiedOrNull(pgnPath);
      final gamesUnchanged = sameMtime(pgnModifiedAtStart, pgnModifiedNow);
      if (gamesUnchanged) {
        await trickHuntStore.save(
          await _gamesService.tricksReportPath(
            player.platform,
            player.username,
            isWhite,
          ),
          result,
          config,
          isComplete: !_trickHuntCancelled,
        );
      } else {
        debugPrint('Trick hunt: games changed mid-hunt, report not saved.');
      }

      if (mounted && _currentPlayer == player) {
        setState(() {
          _tricksResults[isWhite] = gamesUnchanged ? result : null;
          _tricksLive = [];
          _trickProbesSkipped = _trickService.probesSkipped;
        });
      }
    } catch (e) {
      if (mounted) _showError('Trick hunt failed: $e');
    } finally {
      _isTrickHunting = false;
      _trickHuntCancelled = false;
      _tricksProgress = null;
      if (mounted) setState(() {});
    }
  }

  /// Flags the hunt to stop; the run's cleanup handles the rest, and the
  /// partial report is saved.
  void _cancelTrickHunt() {
    if (!_isTrickHunting) return;
    _trickService.cancel();
    if (mounted) setState(() => _trickHuntCancelled = true);
  }

  /// Re-persist after dismissal edits from the report panel.
  Future<void> _onTricksResultChanged(AuditResult result) async {
    final player = _currentPlayer;
    if (player == null) return;
    final isWhite = _playerIsWhite;
    setState(() => _tricksResults[isWhite] = result);
    await trickHuntStore.saveResult(
      await _gamesService.tricksReportPath(
        player.platform,
        player.username,
        isWhite,
      ),
      result,
      config: _tricksConfigs[isWhite],
    );
  }

  /// Restore saved trick reports for both colours of the current player.
  Future<void> _loadTricksReports() async {
    final player = _currentPlayer;
    if (player == null) return;
    for (final isWhite in [true, false]) {
      final snapshot = await trickHuntStore.load(
        await _gamesService.tricksReportPath(
          player.platform,
          player.username,
          isWhite,
        ),
      );
      // Guard: the user may have switched players during the async load.
      if (!mounted || _currentPlayer != player) return;
      if (snapshot != null) {
        setState(() {
          _tricksResults[isWhite] = snapshot.result;
          _tricksConfigs[isWhite] = snapshot.config;
        });
      }
    }
  }
}
