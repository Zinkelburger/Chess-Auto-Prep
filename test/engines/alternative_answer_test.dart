import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/engines/alternative_answer.dart';
import 'package:chess_auto_prep/engines/engine_line.dart';
import 'package:chess_auto_prep/engines/engine_supervisor.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/audit_fixture.dart';
import '../support/scripted_engine.dart';

void main() {
  // Both positions follow the solver's move: the engine scores them for the
  // opponent, so smaller is better for the solver.
  final expected = after('e2e4');
  final played = after('d2d4');

  Future<AlternativeVerdict> compare(int expectedCp, int playedCp) {
    final engine = TableEngine({
      expected.position: [('e7e5', expectedCp)],
      played.position: [('d7d5', playedCp)],
    });
    return AlternativeAnswer(
      () async => Started(engine),
    ).compare(expected: expected, played: played);
  }

  test('another move is accepted when it gives the opponent at most half a '
      'pawn more', () async {
    expect((await compare(30, 80) as AlternativeScored).accepted, isTrue);
    expect((await compare(30, 81) as AlternativeScored).accepted, isFalse);
    expect((await compare(30, -200) as AlternativeScored).accepted, isTrue);
  });

  test('the engine is let go once the check is over', () async {
    final engine = TableEngine({
      expected.position: [('e7e5', 0)],
      played.position: [('d7d5', 0)],
    });
    await AlternativeAnswer(
      () async => Started(engine),
    ).compare(expected: expected, played: played);
    expect(engine.quitCalled, isTrue);
  });

  test('a position that cannot be read, an engine that does not start and a '
      'check already cancelled each say so', () async {
    var launches = 0;
    final unread = await AlternativeAnswer(() async {
      launches++;
      return const StartFailed('unused');
    }).compare(expected: const Fen('not a position'), played: played);
    expect(
      (unread as AlternativeUnavailable).reason,
      'The position could not be read.',
    );
    expect(launches, 0);
    final failed = await AlternativeAnswer(
      () async => const StartFailed('Stockfish is not installed'),
    ).compare(expected: expected, played: played);
    expect(
      (failed as AlternativeUnavailable).reason,
      'Stockfish is not installed',
    );
    final cancelled = AlternativeAnswer(() async {
      launches++;
      return Started(TableEngine({}));
    });
    await cancelled.cancel();
    final verdict = await cancelled.compare(expected: expected, played: played);
    expect((verdict as AlternativeUnavailable).reason, 'Check cancelled.');
    expect(launches, 0);
  });

  test('each position is searched fourteen plies deep', () async {
    final engine = ScriptedEngine();
    final checking = AlternativeAnswer(
      () async => Started(engine),
    ).compare(expected: expected, played: played);
    for (final cp in [30, 60]) {
      await pumpEventQueue();
      expect(engine.current.depth, 14);
      engine.current.emit(line(depth: 14, score: Centipawns(cp)));
      engine.current.end();
    }
    expect((await checking as AlternativeScored).accepted, isTrue);
  });
}
