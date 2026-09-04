part of 'analysis_screen.dart';

/// Hole-hunt (adversarial attack on the displayed colour's tree) support for
/// [AnalysisScreen] — running, cancelling, persisting and restoring reports.
mixin _HoleHuntMixin on _AnalysisScreenStateBase {
  // ── Hole hunt (adversarial attack on the displayed colour's tree) ──

  Future<void> _showHoleHuntConfig() async {
    final player = _currentPlayer;
    if (player == null || _openingTree == null || _isHunting) return;
    if (!EngineGate.ensureAvailable(context)) return;
    if (GenerationLease.isBusy) {
      _showError(
        'Another engine job is running — '
        'wait for it to finish first.',
      );
      return;
    }

    final config = await showDialog<HoleHuntConfig>(
      context: context,
      builder: (_) => HoleHuntConfigDialog(
        playerName: player.username,
        treeIsWhite: _playerIsWhite,
        initialConfig: _holesConfigs[_playerIsWhite],
      ),
    );
    if (config == null || !mounted) return;

    unawaited(_runHoleHunt(config));
  }

  Future<void> _runHoleHunt(HoleHuntConfig config) async {
    final player = _currentPlayer;
    final tree = _openingTree;
    if (player == null || tree == null) return;
    final isWhite = _playerIsWhite;

    setState(() {
      _isHunting = true;
      _huntIsWhite = isWhite;
      _huntCancelled = false;
      _holesLive = [];
      _holesProgress = null;
      _holesResults[isWhite] = null;
      _holesConfigs[isWhite] = config;
      _trapPassSkipped = false;
    });

    // Snapshot the games file's mtime: a re-download during the hunt clears
    // the (now stale) holes reports, and a report computed from the old tree
    // must not resurrect them.
    final pgnPath = await _gamesService.analysisPgnPath(
      player.platform,
      player.username,
    );
    final pgnModifiedAtStart = await fileModifiedOrNull(pgnPath);

    try {
      final result = await GenerationLease.run(() {
        return _holeService.hunt(
          tree: tree,
          isWhiteRepertoire: isWhite,
          config: config,
          onProgress: (p) {
            if (mounted && _currentPlayer == player) {
              setState(() => _holesProgress = p);
            }
          },
          onFinding: (f) {
            if (mounted && _currentPlayer == player) {
              setState(() => _holesLive = [..._holesLive, f]);
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
        await holeHuntStore.save(
          await _gamesService.holesReportPath(
            player.platform,
            player.username,
            isWhite,
          ),
          result,
          config,
          isComplete: !_huntCancelled,
        );
      } else {
        debugPrint('Hole hunt: games changed mid-hunt, report not saved.');
      }

      if (mounted && _currentPlayer == player) {
        setState(() {
          _holesResults[isWhite] = gamesUnchanged ? result : null;
          _holesLive = [];
          _trapPassSkipped = _holeService.trapPassSkipped;
        });
      }
    } catch (e) {
      if (mounted) _showError('Hole hunt failed: $e');
    } finally {
      _isHunting = false;
      _huntCancelled = false;
      _holesProgress = null;
      if (mounted) setState(() {});
    }
  }

  /// Flags the hunt to stop; the run's cleanup handles the rest, and the
  /// partial report is saved.
  void _cancelHoleHunt() {
    if (!_isHunting) return;
    _holeService.cancel();
    if (mounted) setState(() => _huntCancelled = true);
  }

  /// Re-persist after dismissal edits from the report panel.
  Future<void> _onHolesResultChanged(AuditResult result) async {
    final player = _currentPlayer;
    if (player == null) return;
    final isWhite = _playerIsWhite;
    setState(() => _holesResults[isWhite] = result);
    await holeHuntStore.saveResult(
      await _gamesService.holesReportPath(
        player.platform,
        player.username,
        isWhite,
      ),
      result,
      config: _holesConfigs[isWhite],
    );
  }

  /// Restore saved hole reports for both colours of the current player.
  Future<void> _loadHolesReports() async {
    final player = _currentPlayer;
    if (player == null) return;
    for (final isWhite in [true, false]) {
      final snapshot = await holeHuntStore.load(
        await _gamesService.holesReportPath(
          player.platform,
          player.username,
          isWhite,
        ),
      );
      // Guard: the user may have switched players during the async load.
      if (!mounted || _currentPlayer != player) return;
      if (snapshot != null) {
        setState(() {
          _holesResults[isWhite] = snapshot.result;
          _holesConfigs[isWhite] = snapshot.config;
        });
      }
    }
  }
}
