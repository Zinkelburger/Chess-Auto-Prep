/// Exclusive generation-engine lease for long analysis jobs (hole/trick hunts).
///
/// Entering generation while another job holds it is a hard error — callers
/// should refuse in the UI before showing a config dialog.
library;

import 'engine_lifecycle.dart';

class GenerationLease {
  GenerationLease({required this.lifecycle});
  final EngineLifecycle lifecycle;

  bool _held = false;
  bool get isBusy => _held || lifecycle.state == EngineState.generating;

  /// Claim the generation engine, run [body], always release.
  Future<T> run<T>(Future<T> Function() body, {int threads = 1}) async {
    if (isBusy) {
      throw StateError(
        'Another engine job is running — wait for it to finish first.',
      );
    }
    _held = true;
    var entered = false;
    try {
      await lifecycle.enterGeneration(threads);
      entered = true;
      return await body();
    } finally {
      try {
        if (entered && !lifecycle.isDisposed) await lifecycle.exitGeneration();
      } finally {
        _held = false;
      }
    }
  }
}
