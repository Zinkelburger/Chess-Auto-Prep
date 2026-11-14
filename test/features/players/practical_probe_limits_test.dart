// The practical estimate's bounds: only the five likeliest replies are
// probed, and a reply the model gives no chance is not asked about.
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/engines/maia/move_policy.dart';
import 'package:chess_auto_prep/features/players/practical_probe.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_engine.dart';

class _Policy implements MovePolicy {
  _Policy(this.answer);
  final MaiaAnswer answer;
  @override
  Future<MaiaAnswer> policy(Fen fen, int elo) async => answer;
}

void main() {
  test('only the five likeliest replies are probed', () async {
    final asked = <Fen>[];
    await practicalScore(
      start: Fen.initial,
      candidate: line(pv: ['e2e4']),
      model: _Policy(
        const MaiaPolicy({
          'e7e5': .3,
          'c7c5': .2,
          'e7e6': .15,
          'c7c6': .15,
          'd7d5': .1,
          'g8f6': .1,
        }),
      ),
      rating: 1800,
      evaluate: (fen) async {
        asked.add(fen);
        return line();
      },
      cancelled: () => false,
    );
    expect(asked, hasLength(5));
  });

  test('a reply given no chance is not asked about', () async {
    final asked = <Fen>[];
    await practicalScore(
      start: Fen.initial,
      candidate: line(pv: ['e2e4']),
      model: _Policy(const MaiaPolicy({'e7e5': 1, 'd7d5': 0})),
      rating: 1800,
      evaluate: (fen) async {
        asked.add(fen);
        return line();
      },
      cancelled: () => false,
    );
    expect(asked, hasLength(1));
  });
}
