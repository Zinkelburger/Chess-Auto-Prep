import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/generation/eval.dart';
import 'package:chess_auto_prep/v2/engines/engine_line.dart';
import 'package:chess_auto_prep/v2/engines/maia/move_policy.dart';
import 'package:chess_auto_prep/v2/features/players/practical_probe.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_engine.dart';

class Policy implements MovePolicy {
  Policy(this.answer);
  final MaiaAnswer answer;
  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) async => answer;
}

void main() {
  test(
    'model shares weight opponent errors from attacker perspective',
    () async {
      final score = await practicalScore(
        start: Fen.initial,
        candidate: line(score: const Centipawns(0), pv: ['e2e4']),
        model: Policy(const MaiaPolicy({'e7e5': .5, 'd7d5': .5})),
        rating: 1800,
        evaluate: (fen) async =>
            line(score: Centipawns(fen.value.contains('3p4') ? 200 : 0)),
        cancelled: () => false,
      );
      expect(
        score,
        closeTo(
          .5 * expectedScore(const Eval(0)) +
              .5 * expectedScore(const Eval(200)),
          .00001,
        ),
      );
    },
  );
  test(
    'unavailable model reports failure; cancellation publishes no estimate',
    () async {
      Future<double?> run(MaiaAnswer answer, bool cancelled) => practicalScore(
        start: Fen.initial,
        candidate: line(pv: ['e2e4']),
        model: Policy(answer),
        rating: 1800,
        evaluate: (_) async => line(),
        cancelled: () => cancelled,
      );
      await expectLater(
        run(const MaiaFailed('No model'), false),
        throwsStateError,
      );
      expect(await run(const MaiaPolicy({'e7e5': 1}), true), isNull);
    },
  );
}
