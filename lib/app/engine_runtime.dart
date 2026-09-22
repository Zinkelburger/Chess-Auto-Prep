import '../features/settings/controllers/engine_settings.dart';
import '../services/engine/board_engine.dart';
import '../services/engine/engine_connection.dart';
import '../services/engine/engine_lifecycle.dart';
import '../services/engine/engine_search_budget.dart';
import '../services/engine/generation_lease.dart';
import '../services/engine/stockfish_pool.dart';

/// Application lifetime of native engine resources and their shared CPU budget.
/// Operational APIs remain on the components; this owner only composes/disposes.
class EngineRuntime {
  EngineRuntime({
    required EngineSettings settings,
    Future<EngineConnection?> Function()? createConnection,
  }) {
    budget = EngineSearchBudget(capacity: () => settings.committed.cores);
    pool = StockfishPool(
      settings: () => settings.committed,
      budget: budget,
      createConnection: createConnection,
    );
    board = BoardEngine(
      settings: () => settings.committed,
      budget: budget,
      createConnection: createConnection,
    );
    lifecycle = EngineLifecycle(
      pool: pool,
      board: board,
      loadEnabled: () async {
        await settings.ensureLoaded();
        return settings.committed.enabled;
      },
      saveEnabled: (enabled) =>
          settings.edit({'engine_lifecycle.toggle_on': enabled}),
    );
    lease = GenerationLease(lifecycle: lifecycle);
  }
  late final EngineSearchBudget budget;
  late final StockfishPool pool;
  late final BoardEngine board;
  late final EngineLifecycle lifecycle;
  late final GenerationLease lease;
  bool _disposed = false;
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    lifecycle.dispose();
    board.dispose();
    pool.dispose();
    budget.dispose();
  }
}
