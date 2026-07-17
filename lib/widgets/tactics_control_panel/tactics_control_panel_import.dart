// Import / fetch actions for the tactics control panel: engine warm-up,
// position loading, auto-fetch, resume-analysis, and per-source imports.
// Split out of tactics_control_panel.dart (pure code motion).
part of '../tactics_control_panel.dart';

mixin _TacticsImportActions on _TacticsControlPanelStateBase {
  /// Fire-and-forget: spawn Stockfish workers and load the Maia ONNX model
  /// while the user is still looking at the import form.
  Future<void> _warmUpEngines() async {
    final pool = StockfishPool.instance;
    final targetWorkers = EngineSettings.instance.workers;
    await pool.ensureWorkers(targetWorkers);
    // Maia init is cheap after the first call (singleton).
    if (MaiaFactory.isAvailable) {
      try {
        await MaiaFactory.instance?.initialize();
      } catch (_) {
        // Best-effort; failure here is non-fatal and intentionally ignored.
      }
    }
  }

  Future<void> _loadPositions() async {
    await _database.loadPositions();
    if (mounted) {
      setState(() {});
      final appState = context.read<AppState>();
      unawaited(
        _import.refreshPendingCount(
          lichessUsername: appState.lichessUsername,
          chesscomUsername: appState.chesscomUsername,
        ),
      );
      _maybeAutoFetch();
    }
  }

  /// Static flag to prevent auto-fetch from firing multiple times across
  /// widget recreations (e.g. layout breakpoint switches).
  static bool _autoFetchAttempted = false;

  Future<void> _maybeAutoFetch() async {
    if (_autoFetchAttempted) return;
    _autoFetchAttempted = true;

    final appState = context.read<AppState>();

    // Ensure preferences are loaded before checking auto-fetch setting.
    // loadUsernames() may still be in flight if called from main().
    if (!appState.tacticsAutoFetch) {
      await appState.loadUsernames();
      if (!mounted) return;
      if (!appState.tacticsAutoFetch) return;
    }

    if (_import.isImporting) return;

    await _import.autoFetch(
      lichessUsername: appState.lichessUsername,
      chesscomUsername: appState.chesscomUsername,
      lichessLastFetch: appState.lichessLastFetch,
      chesscomLastFetch: appState.chesscomLastFetch,
      depth: _form.depth,
      cores: _form.cores,
      onFetched: (source, fetchedAt) {
        if (!mounted) return;
        if (source == TacticsImportSource.lichess) {
          appState.setLichessLastFetch(fetchedAt);
        } else {
          appState.setChesscomLastFetch(fetchedAt);
        }
      },
    );

    // Same automatic pass: finish games fetched earlier but never analyzed
    // (a stopped or interrupted run), within the same recency window.
    if (!mounted) return;
    await _import.refreshPendingCount(
      lichessUsername: appState.lichessUsername,
      chesscomUsername: appState.chesscomUsername,
    );
    if (!mounted || _import.pendingGameCount == 0) return;
    await _resumeAnalysis();
  }

  Future<void> _importLichess() =>
      _runImport(TacticsImportSource.lichess, 'Lichess');

  Future<void> _importChessCom() =>
      _runImport(TacticsImportSource.chessCom, 'Chess.com');

  /// Sync-row refresh: import from every source that has a username, one
  /// after the other (the coordinator rejects concurrent imports).
  Future<void> _fetchNewGames() async {
    if (_form.lichessUser.text.trim().isNotEmpty) {
      await _importLichess();
    }
    if (!mounted) return;
    if (_form.chessComUser.text.trim().isNotEmpty) {
      await _importChessCom();
    }
  }

  Future<void> _runImport(TacticsImportSource source, String platform) async {
    // Imports analyze every game with Stockfish — refuse while generation
    // holds the engine.
    if (!EngineGate.ensureAvailable(context)) return;
    _form.savePrefs();

    try {
      await _import.import(source: source, params: _form.paramsFor(source));
      // Only update last-fetch on non-cancelled completion.
      // cancelImport() clears importStatus; success leaves it non-null.
      if (mounted && _import.importStatus != null) {
        final appState = context.read<AppState>();
        final now = DateTime.now();
        if (source == TacticsImportSource.lichess) {
          appState.setLichessLastFetch(now);
        } else {
          appState.setChesscomLastFetch(now);
        }
      }
    } on TacticsImportUsernameRequired {
      _showUsernameRequired(platform);
    } catch (e) {
      debugPrint('$platform import failed: $e');
      if (mounted) {
        _import.dismissImportStatus();
        showAppSnackBar(context, AppMessages.importFailed, isError: true);
      }
    }
  }

  Future<void> _resumeAnalysis() async {
    final appState = context.read<AppState>();
    try {
      await _import.resumeAnalysis(
        lichessUsername: appState.lichessUsername,
        chesscomUsername: appState.chesscomUsername,
        depth: _form.depth,
        cores: _form.cores,
        since: _form.sinceCutoff,
      );
    } catch (e) {
      debugPrint('Resume analysis failed: $e');
      if (mounted) {
        _import.dismissImportStatus();
        showAppSnackBar(context, AppMessages.importFailed, isError: true);
      }
    }
  }

  void _showUsernameRequired(String platform) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Username Required'),
        content: Text('Please set your $platform username in Settings first.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}
