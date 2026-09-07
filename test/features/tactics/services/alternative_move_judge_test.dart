import 'package:chess_auto_prep/features/tactics/services/alternative_move_judge.dart';
import 'package:chess_auto_prep/services/engine/eval_worker.dart';
import 'package:chess_auto_prep/utils/eval_constants.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const start = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  group('isAcceptableAlternative', () {
    test('a move within half a pawn of the answer counts', () {
      expect(isAcceptableAlternative(playedCp: 120, bestCp: 120), isTrue);
      expect(isAcceptableAlternative(playedCp: 80, bestCp: 120), isTrue);
      expect(isAcceptableAlternative(playedCp: 150, bestCp: 120), isTrue);
    });

    test('a move that gives more than that back does not', () {
      expect(isAcceptableAlternative(playedCp: 60, bestCp: 120), isFalse);
      expect(isAcceptableAlternative(playedCp: -50, bestCp: 300), isFalse);
    });

    test('a slower mate is still the mate; a won endgame is not', () {
      expect(
        isAcceptableAlternative(playedCp: mateToCp(5), bestCp: mateToCp(3)),
        isTrue,
      );
      expect(
        isAcceptableAlternative(playedCp: 800, bestCp: mateToCp(3)),
        isFalse,
      );
    });
  });

  group('EngineAlternativeJudge', () {
    // Scores as the engine gives them: for the side to move after the move,
    // which is the opponent. −20 after 1.d4 means White stands +20.
    EngineAlternativeJudge judge(
      Map<String, int> scoreByFen, {
      bool ready = true,
      List<String>? evaluated,
    }) => EngineAlternativeJudge(
      engineReady: () async => ready,
      evaluate: (fen, depth) async {
        evaluated?.add(fen);
        return EvalResult(scoreCp: scoreByFen[fen], depth: depth);
      },
    );

    const afterD4 =
        'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq - 0 1';
    const afterE4 =
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1';
    const query = AlternativeMoveQuery(
      fen: start,
      playedUci: 'd2d4',
      bestToken: 'e4',
    );

    test('accepts a move the engine scores level with the answer', () async {
      final evaluated = <String>[];
      final j = judge({afterD4: -20, afterE4: -30}, evaluated: evaluated);
      expect(await j.judge(query), isTrue);
      expect(evaluated, containsAll([afterD4, afterE4]));
    });

    test('rejects a move that scores clearly worse', () async {
      final j = judge({afterD4: 200, afterE4: -30});
      expect(await j.judge(query), isFalse);
    });

    test('reads a UCI answer token too', () async {
      final j = judge({afterD4: -20, afterE4: -30});
      expect(
        await j.judge(
          const AlternativeMoveQuery(
            fen: start,
            playedUci: 'd2d4',
            bestToken: 'e2e4',
          ),
        ),
        isTrue,
      );
    });

    test('says no without asking when the engine is not there', () async {
      final evaluated = <String>[];
      final j = judge({}, ready: false, evaluated: evaluated);
      expect(await j.judge(query), isFalse);
      expect(evaluated, isEmpty);
    });

    test('an illegal move or an unparseable answer is a no', () async {
      final j = judge({afterD4: 0, afterE4: 0});
      expect(
        await j.judge(
          const AlternativeMoveQuery(
            fen: start,
            playedUci: 'e2e5',
            bestToken: 'e4',
          ),
        ),
        isFalse,
      );
      expect(
        await j.judge(
          const AlternativeMoveQuery(
            fen: start,
            playedUci: 'd2d4',
            bestToken: 'Zz9',
          ),
        ),
        isFalse,
      );
    });
  });
}
