import 'package:chess_auto_prep/models/tactics_position.dart';
import 'package:chess_auto_prep/services/tactics_database.dart';
import 'package:flutter_test/flutter_test.dart';

TacticsPosition _pos(String fen) {
  return TacticsPosition(
    fen: fen,
    gameWhite: 'A',
    gameBlack: 'B',
    gameResult: '1-0',
    gameDate: '2024.01.01',
    gameId: fen,
    positionContext: 'Move 1 — White to play',
    userMove: 'd4',
    correctLine: const ['e4'],
    mistakeType: '??',
    mistakeAnalysis: 'test',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TacticsDatabase is a reactive source of truth', () {
    test('addPosition notifies listeners and updates the list', () async {
      final db = TacticsDatabase();
      var notifications = 0;
      db.addListener(() => notifications++);

      await db.addPosition(_pos('a'));

      expect(db.positions.length, 1);
      expect(notifications, greaterThan(0));
    });

    test('addPosition does not notify for a duplicate FEN', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos('a'));

      var notifications = 0;
      db.addListener(() => notifications++);
      await db.addPosition(_pos('a')); // duplicate

      expect(db.positions.length, 1);
      expect(notifications, 0);
    });

    test('deletePositionAt notifies and removes the entry', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos('a'));
      await db.addPosition(_pos('b'));

      var notifications = 0;
      db.addListener(() => notifications++);
      await db.deletePositionAt(0);

      expect(db.positions.map((p) => p.fen), ['b']);
      expect(notifications, greaterThan(0));
    });

    test('deletePositionAt ignores an out-of-range index without notifying',
        () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos('a'));

      var notifications = 0;
      db.addListener(() => notifications++);
      await db.deletePositionAt(5);

      expect(db.positions.length, 1);
      expect(notifications, 0);
    });

    test('updatePositionAt replaces the entry and notifies', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos('a'));

      var notifications = 0;
      db.addListener(() => notifications++);
      await db.updatePositionAt(0, _pos('a').copyWith(rating: 3));

      expect(db.positions.first.rating, 3);
      expect(notifications, greaterThan(0));
    });

    test('clearPositions empties the list and notifies', () async {
      final db = TacticsDatabase();
      await db.addPosition(_pos('a'));

      var notifications = 0;
      db.addListener(() => notifications++);
      await db.clearPositions();

      expect(db.positions, isEmpty);
      expect(notifications, greaterThan(0));
    });
  });
}
