/// Exclusive generation-engine lease for long analysis jobs (hole/trick hunts).
///
/// Entering generation while another job holds it is a hard error — callers
/// should refuse in the UI before showing a config dialog.
library;

import '../engine/engine_lifecycle.dart';
import '../engine/stockfish_pool.dart';

class GenerationLease {
  GenerationLease._();

  static bool get isBusy =>
      EngineLifecycle.instance.state == EngineState.generating;

  /// Claim the generation engine, run [body], always release.
  static Future<T> run<T>(Future<T> Function() body, {int threads = 1}) async {
    if (isBusy) {
      throw StateError(
        'Another engine job is running — wait for it to finish first.',
      );
    }
    await EngineLifecycle.instance.enterGeneration(threads);
    try {
      await StockfishPool.instance.ensureWorkers(threads);
      return await body();
    } finally {
      await EngineLifecycle.instance.exitGeneration();
    }
  }
}
