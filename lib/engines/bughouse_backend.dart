import '../chess/bughouse/expectimax.dart';
import 'crazyara_engine.dart';
import 'engine.dart';
import 'hivemind_engine.dart';

/// The two native engines for one search; callbacks also allow deterministic
/// algorithm and UI checks without loading either neural network.
final class BughouseBackend {
  const BughouseBackend({
    required this.policy,
    required this.evaluate,
    required this.close,
  });
  final BughousePolicy policy;
  final BughouseValue evaluate;
  final Future<void> Function() close;

  static Future<BughouseBackend> start({
    required Future<CrazyaraProcess> Function() crazyara,
    required Future<HivemindStart> Function() hivemind,
  }) async {
    final policy = await crazyara();
    try {
      final started = await hivemind();
      if (started is HivemindStartFailed) throw EngineFailure(started.reason);
      final engine = (started as HivemindStarted).engine;
      if (engine is! HivemindValue) {
        await engine.quit();
        throw const EngineFailure('This Hivemind cannot evaluate positions.');
      }
      return BughouseBackend(
        policy: policy.policy,
        evaluate: (engine as HivemindValue).evaluate,
        close: () async {
          await Future.wait([policy.quit(), engine.quit()]);
        },
      );
    } on Object {
      await policy.quit();
      rethrow;
    }
  }
}
