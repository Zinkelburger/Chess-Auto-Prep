import 'package:chess_auto_prep/features/engine_tournament/services/uci_engine.dart';
import 'package:flutter_test/flutter_test.dart';

EngineSearch _search({int? cp, int? mate}) => EngineSearch(
  bestMoveUci: 'e2e4',
  elapsedMs: 10,
  scoreCp: cp,
  scoreMate: mate,
);

void main() {
  group('comparableCp collapses mates onto the centipawn axis', () {
    test('a centipawn score passes through', () {
      expect(_search(cp: 42).comparableCp, 42);
      expect(_search().comparableCp, isNull);
    });

    test('a mate outranks any finite advantage', () {
      expect(_search(mate: 5).comparableCp!, greaterThan(10000));
      expect(_search(mate: -5).comparableCp!, lessThan(-10000));
    });

    test('a shorter mate outranks a longer one', () {
      expect(
        _search(mate: 1).comparableCp!,
        greaterThan(_search(mate: 9).comparableCp!),
      );
    });

    test('"mate 0" is a loss, not a level position', () {
      // Read as zero it would satisfy a draw adjudication, which is the
      // opposite of what the engine is saying.
      expect(_search(mate: 0).comparableCp!, lessThan(-10000));
    });
  });

  group('bestmove sanity', () {
    test('the no-move answers are recognised as such', () {
      for (final answer in ['(none)', '0000', 'null', '']) {
        expect(
          EngineSearch(bestMoveUci: answer, elapsedMs: 0).hasMove,
          isFalse,
          reason: answer,
        );
      }
      expect(_search(cp: 0).hasMove, isTrue);
    });
  });

  group('GoLimits', () {
    test('a clock is written the way UCI expects', () {
      const limits = GoLimits(
        whiteTimeMs: 60000,
        blackTimeMs: 59000,
        whiteIncrementMs: 600,
        blackIncrementMs: 600,
        movesToGo: 40,
      );
      expect(
        limits.toCommand(),
        'go wtime 60000 btime 59000 winc 600 binc 600 movestogo 40',
      );
    });

    test('a fixed think time and a fixed depth each stand alone', () {
      expect(const GoLimits(movetimeMs: 2000).toCommand(), 'go movetime 2000');
      expect(const GoLimits(depth: 12).toCommand(), 'go depth 12');
    });

    test('no limits at all means an infinite search, never a bare "go"', () {
      expect(const GoLimits().toCommand(), 'go infinite');
    });
  });
}
