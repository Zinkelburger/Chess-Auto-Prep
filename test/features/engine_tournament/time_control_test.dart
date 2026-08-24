import 'package:chess_auto_prep/features/engine_tournament/models/time_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('labels and PGN tags', () {
    test('per-move controls use the PGN sudden-death-per-move spelling', () {
      const tc = TimeControl.perMove(2000);
      expect(tc.label, '2s/move');
      expect(tc.pgnTag, '*2');
      expect(tc.isTimed, isFalse);
    });

    test('a clock reads as base+increment', () {
      const tc = TimeControl.clock(baseMs: 60000, incrementMs: 600);
      expect(tc.label, '60s+0.6s');
      expect(tc.pgnTag, '60+0.6');
      expect(tc.isTimed, isTrue);
    });

    test('a moves-per-session period is written as N/base+inc', () {
      const tc = TimeControl.clock(
        baseMs: 600000,
        incrementMs: 10000,
        movesPerSession: 40,
      );
      expect(tc.pgnTag, '40/600+10');
    });

    test('untimed searches report the time control as unknown', () {
      expect(const TimeControl.fixedDepth(12).pgnTag, '?');
      expect(const TimeControl.fixedNodes(1000).pgnTag, '?');
      expect(const TimeControl.fixedDepth(12).label, 'depth 12');
    });
  });

  group('hard limits', () {
    test('a per-move budget allows the Scid-style 175% overshoot', () {
      final limit = const TimeControl.perMove(2000).hardLimitFor();
      expect(limit.inMilliseconds, 2000 * 1.75 + 2000);
    });

    test('a clock is bounded by what is left on it', () {
      final limit = const TimeControl.clock(
        baseMs: 60000,
        incrementMs: 600,
      ).hardLimitFor(remainingMs: 10000);
      expect(limit.inMilliseconds, 10000 + 600 + 5000);
    });

    test('an untimed search still has a hang guard', () {
      expect(
        const TimeControl.fixedDepth(30).hardLimitFor().inMinutes,
        greaterThan(0),
      );
    });
  });

  test('survives a JSON round trip', () {
    const original = TimeControl.clock(
      baseMs: 300000,
      incrementMs: 3000,
      movesPerSession: 40,
    );
    final restored = TimeControl.fromJson(original.toJson());
    expect(restored.kind, original.kind);
    expect(restored.baseMs, original.baseMs);
    expect(restored.incrementMs, original.incrementMs);
    expect(restored.movesPerSession, 40);
    expect(restored.label, original.label);
  });

  test('every offered preset has a distinct label', () {
    final labels = kTimeControlPresets.map((p) => p.tc.label).toList();
    expect(labels.toSet().length, labels.length);
  });
}
