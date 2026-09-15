import 'package:chess_auto_prep/features/engine_tournament/models/time_control.dart';
import 'package:chess_auto_prep/features/engine_tournament/services/game_clock.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('per-move control', () {
    final clock = GameClock(const TimeControl.perMove(1000));

    test('sends movetime and no clocks', () {
      final limits = clock.limitsFor(Side.white);
      expect(limits.movetimeMs, 1000);
      expect(limits.whiteTimeMs, isNull);
      expect(clock.displayMs(Side.white), isNull);
    });

    test('forfeits past 175% plus the margin, not before', () {
      expect(clock.charge(Side.white, 1750 + kTimeMarginMs), isFalse);
      expect(clock.charge(Side.white, 1751 + kTimeMarginMs), isTrue);
    });
  });

  group('untimed controls', () {
    test('fixed depth never forfeits, however slow', () {
      final clock = GameClock(const TimeControl.fixedDepth(8));
      expect(clock.limitsFor(Side.black).depth, 8);
      expect(clock.charge(Side.black, 1 << 30), isFalse);
    });

    test('fixed nodes send the node budget', () {
      final clock = GameClock(const TimeControl.fixedNodes(5000));
      expect(clock.limitsFor(Side.white).nodes, 5000);
      expect(clock.charge(Side.white, 1 << 30), isFalse);
    });
  });

  group('a real clock', () {
    test('charges the mover and adds the increment', () {
      final clock = GameClock(
        const TimeControl.clock(baseMs: 10000, incrementMs: 500),
      );
      expect(clock.charge(Side.white, 3000), isFalse);
      expect(clock.remainingMs(Side.white), 7500);
      expect(clock.remainingMs(Side.black), 10000);
      expect(clock.displayMs(Side.white), 7500);

      final limits = clock.limitsFor(Side.black);
      expect(limits.whiteTimeMs, 7500);
      expect(limits.blackTimeMs, 10000);
      expect(limits.whiteIncrementMs, 500);
      expect(limits.blackIncrementMs, 500);
      expect(limits.movesToGo, isNull);
    });

    test(
      'a flag falls only past the margin, and leaves the clock as it was',
      () {
        final clock = GameClock(const TimeControl.clock(baseMs: 1000));
        expect(clock.charge(Side.white, 1000 + kTimeMarginMs), isFalse);
        expect(clock.remainingMs(Side.white), 0);
        expect(clock.charge(Side.white, kTimeMarginMs + 1), isTrue);
        expect(clock.remainingMs(Side.white), 0);
      },
    );

    test('a clock that has hit zero is still sent as 1 ms, never 0', () {
      final clock = GameClock(const TimeControl.clock(baseMs: 100));
      clock.charge(Side.white, 100);
      expect(clock.limitsFor(Side.white).whiteTimeMs, 1);
    });

    test('movestogo counts down per side and the session refills', () {
      final clock = GameClock(
        const TimeControl.clock(baseMs: 6000, movesPerSession: 3),
      );
      expect(clock.limitsFor(Side.white).movesToGo, 3);
      clock.charge(Side.white, 1000);
      expect(clock.limitsFor(Side.white).movesToGo, 2);
      expect(clock.limitsFor(Side.black).movesToGo, 3);
      clock.charge(Side.white, 1000);
      clock.charge(Side.white, 1000);
      expect(clock.remainingMs(Side.white), 3000 + 6000);
      expect(clock.limitsFor(Side.white).movesToGo, 3);
    });

    test('the hang guard follows the remaining time', () {
      final clock = GameClock(
        const TimeControl.clock(baseMs: 60000, incrementMs: 0),
      );
      clock.charge(Side.white, 50000);
      expect(
        clock.hardLimitFor(Side.white),
        const TimeControl.clock(
          baseMs: 60000,
          incrementMs: 0,
        ).hardLimitFor(remainingMs: 10000),
      );
    });
  });
}
