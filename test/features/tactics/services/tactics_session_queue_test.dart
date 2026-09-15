import 'package:chess_auto_prep/features/tactics/models/tactics_position.dart';
import 'package:chess_auto_prep/features/tactics/models/tactics_session_settings.dart';
import 'package:chess_auto_prep/features/tactics/services/tactics_session_queue.dart';
import 'package:flutter_test/flutter_test.dart';

/// Distinct valid FENs: the standard start with a varying fullmove counter,
/// which also makes [TacticsPosition.moveNumber] equal to [n].
String _fen(int n) =>
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 $n';

TacticsPosition _pos(
  int n, {
  String gameId = 'g',
  String gameDate = '2024.01.01',
  int reviewCount = 0,
  int successCount = 0,
  int rating = 0,
}) => TacticsPosition(
  fen: _fen(n),
  userMove: 'd4',
  correctLine: const ['e4'],
  mistakeType: '??',
  mistakeAnalysis: '',
  gameWhite: 'A',
  gameBlack: 'B',
  gameResult: '1-0',
  gameDate: gameDate,
  gameId: gameId,
  reviewCount: reviewCount,
  successCount: successCount,
  rating: rating,
);

const _allTime = TacticsSessionSettings(maxAgeDays: null, groupByGame: false);

void main() {
  group('start', () {
    test('queues only accepted positions, newest first by default', () {
      final positions = [
        _pos(1, gameDate: '2024.01.01'),
        _pos(2, gameDate: '2024.03.01', rating: 1),
        _pos(3, gameDate: '2024.02.01'),
      ];
      final queue = TacticsSessionQueue()..start(positions, _allTime);

      expect(queue.length, 2, reason: '1-star excluded by default');
      expect(queue.currentPositionIndex, 2);
      expect(queue.next(), 0);
      expect(queue.next(), isNull);
    });

    test('least reviewed and worst success rate orderings', () {
      final positions = [
        _pos(1, reviewCount: 4, successCount: 4),
        _pos(2, reviewCount: 2, successCount: 0),
        _pos(3, reviewCount: 3, successCount: 1),
      ];
      final least = TacticsSessionQueue()
        ..start(
          positions,
          _allTime.copyWith(order: TacticsSessionOrder.leastReviewed),
        );
      expect(least.currentPositionIndex, 1);
      expect(least.next(), 2);
      expect(least.next(), 0);

      final worst = TacticsSessionQueue()
        ..start(
          positions,
          _allTime.copyWith(order: TacticsSessionOrder.worstSuccessRate),
        );
      expect(worst.currentPositionIndex, 1);
      expect(worst.next(), 2);
      expect(worst.next(), 0);
    });

    test('groupByGame keeps a game together in move order', () {
      final positions = [
        _pos(9, gameId: 'g1', gameDate: '2024.01.01'),
        _pos(5, gameId: 'g2', gameDate: '2024.02.01'),
        _pos(3, gameId: 'g1', gameDate: '2024.01.01'),
        _pos(7, gameId: 'g2', gameDate: '2024.02.01'),
      ];
      final queue = TacticsSessionQueue()
        ..start(positions, _allTime.copyWith(groupByGame: true));

      // g2 is newer, so it leads; within each game, by move number.
      expect(queue.currentPositionIndex, 1);
      expect(queue.next(), 3);
      expect(queue.next(), 2);
      expect(queue.next(), 0);
      expect(queue.next(), isNull);
    });

    test('an empty queue reports 0 and navigates nowhere', () {
      final queue = TacticsSessionQueue()..start(const [], _allTime);
      expect(queue.isEmpty, isTrue);
      expect(queue.currentPositionIndex, 0);
      expect(queue.next(), isNull);
      expect(queue.previous(), isNull);
      expect(queue.isViewingPast, isFalse);
    });
  });

  group('startWith', () {
    test(
      'queues exactly the subset in order, skipping unknown and repeats',
      () {
        final positions = [_pos(1), _pos(2), _pos(3)];
        final queue = TacticsSessionQueue()
          ..startWith(positions, [
            positions[2],
            positions[0],
            _pos(99),
            positions[2],
          ]);
        expect(queue.length, 2);
        expect(queue.currentPositionIndex, 2);
        expect(queue.next(), 0);
        expect(queue.next(), isNull);
      },
    );
  });

  group('navigation', () {
    test('does not wrap, and previous tracks the head', () {
      final queue = TacticsSessionQueue()
        ..start([_pos(1), _pos(2), _pos(3)], _allTime);
      final first = queue.currentPositionIndex;
      expect(queue.isViewingPast, isFalse);

      expect(queue.next(), isNotNull);
      expect(queue.cursor, 1);
      expect(queue.previous(), first);
      expect(queue.isViewingPast, isTrue, reason: 'behind the head');
      expect(queue.previous(), first, reason: 'stops at the first');

      expect(queue.next(), isNotNull);
      expect(queue.isViewingPast, isFalse, reason: 'back at the head');
      expect(queue.next(), isNotNull);
      expect(queue.next(), isNull, reason: 'past the last — exhausted');
      expect(queue.cursor, 2);
    });

    test('remove keeps the cursor on the same puzzle when possible', () {
      final positions = [_pos(1), _pos(2), _pos(3), _pos(4)];
      final queue = TacticsSessionQueue()..start(positions, _allTime);
      // newest-first with equal dates keeps list order: 0,1,2,3.
      queue.next();
      queue.next(); // cursor on slot 2 (position 2), head 2

      queue.remove(0); // a slot before the cursor
      expect(queue.cursor, 1);
      expect(queue.length, 3);
      expect(queue.isViewingPast, isFalse, reason: 'head moved with it');

      queue.remove(3); // the last slot, after the cursor
      expect(queue.cursor, 1);
      expect(queue.next(), isNull, reason: 'nothing left after the cursor');

      queue.remove(2); // the current slot, now last
      expect(queue.cursor, 0, reason: 'clamped to the new end');
      expect(
        queue.isViewingPast,
        isTrue,
        reason: 'the slot it fell back to was completed earlier',
      );

      queue.remove(42); // not queued: no-op
      expect(queue.length, 1);
    });

    test('clear empties the queue', () {
      final queue = TacticsSessionQueue()..start([_pos(1)], _allTime);
      queue.clear();
      expect(queue.isEmpty, isTrue);
      expect(queue.cursor, 0);
    });
  });
}
