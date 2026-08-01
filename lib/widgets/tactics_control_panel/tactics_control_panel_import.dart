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
    }
  }

  // "Resume analysis" used to live here, behind its own banner on this side of
  // the screen. It is the review strip's play button now: pressing it when
  // games are already downloaded skips straight to analysing the ones that have
  // no counts yet, which is the same work by a name the user already knows.
}
