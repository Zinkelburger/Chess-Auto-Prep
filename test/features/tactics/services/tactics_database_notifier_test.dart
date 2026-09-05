import 'package:chess_auto_prep/features/tactics/models/tactics_position.dart';
import '../../../helpers/memory_tactics_database.dart';
import 'package:flutter_test/flutter_test.dart';

TacticsPosition _pos(String fen) {
  return TacticsPosition(
    fen: fen,
    gameWhite: 'A',
    gameBlack: 'B',
    gameResult: '1-0',
    gameDate: '2024.01.01',
    gameId: fen,
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
      final db = MemoryTacticsDatabase();
      var notifications = 0;
      db.addListener(() => notifications++);

      await db.addPosition(_pos('a'));

      expect(db.positions.length, 1);
      expect(notifications, greaterThan(0));
    });

    test('addPosition does not notify for a duplicate FEN', () async {
      final db = MemoryTacticsDatabase();
      await db.addPosition(_pos('a'));

      var notifications = 0;
      db.addListener(() => notifications++);
      await db.addPosition(_pos('a')); // duplicate

      expect(db.positions.length, 1);
      expect(notifications, 0);
    });

    test('deletePositionAt notifies and removes the entry', () async {
      final db = MemoryTacticsDatabase();
      await db.addPosition(_pos('a'));
      await db.addPosition(_pos('b'));

      var notifications = 0;
      db.addListener(() => notifications++);
      await db.deletePositionAt(0);

      expect(db.positions.map((p) => p.fen), ['b']);
      expect(notifications, greaterThan(0));
    });

    test(
      'deletePositionAt ignores an out-of-range index without notifying',
      () async {
        final db = MemoryTacticsDatabase();
        await db.addPosition(_pos('a'));

        var notifications = 0;
        db.addListener(() => notifications++);
        await db.deletePositionAt(5);

        expect(db.positions.length, 1);
        expect(notifications, 0);
      },
    );

    test('updatePositionAt replaces the entry and notifies', () async {
      final db = MemoryTacticsDatabase();
      await db.addPosition(_pos('a'));

      var notifications = 0;
      db.addListener(() => notifications++);
      await db.updatePositionAt(0, _pos('a').copyWith(rating: 3));

      expect(db.positions.first.rating, 3);
      expect(notifications, greaterThan(0));
    });

    /// Batch delete is irreversible — its own dialog says so — and used to
    /// trust the caller to hand over descending, duplicate-free indices.
    /// Any other order deleted puzzles the user never selected.
    group('deletePositionsAt survives any index order', () {
      Future<MemoryTacticsDatabase> seeded() async {
        final db = MemoryTacticsDatabase();
        for (final fen in const ['a', 'b', 'c', 'd', 'e']) {
          await db.addPosition(_pos(fen));
        }
        return db;
      }

      test('descending indices remove exactly those entries', () async {
        final db = await seeded();
        await db.deletePositionsAt([3, 1]);
        expect(db.positions.map((p) => p.fen), ['a', 'c', 'e']);
      });

      test('ascending indices remove the same entries', () async {
        final db = await seeded();
        await db.deletePositionsAt([1, 3]);
        expect(db.positions.map((p) => p.fen), ['a', 'c', 'e']);
      });

      test('unsorted indices remove the same entries', () async {
        final db = await seeded();
        await db.deletePositionsAt([3, 0, 1]);
        expect(db.positions.map((p) => p.fen), ['c', 'e']);
      });

      test('a repeated index deletes one entry, not two', () async {
        final db = await seeded();
        await db.deletePositionsAt([1, 1]);
        expect(db.positions.map((p) => p.fen), ['a', 'c', 'd', 'e']);
      });

      test(
        'out-of-range indices are skipped, valid ones still apply',
        () async {
          final db = await seeded();
          await db.deletePositionsAt([-1, 99, 2]);
          expect(db.positions.map((p) => p.fen), ['a', 'b', 'd', 'e']);
        },
      );

      test('an all-invalid batch does not notify', () async {
        final db = await seeded();
        var notifications = 0;
        db.addListener(() => notifications++);
        await db.deletePositionsAt([-1, 99]);
        expect(db.positions.length, 5);
        expect(notifications, 0);
      });
    });

    test('clearPositions empties the list and notifies', () async {
      final db = MemoryTacticsDatabase();
      await db.addPosition(_pos('a'));

      var notifications = 0;
      db.addListener(() => notifications++);
      await db.clearPositions();

      expect(db.positions, isEmpty);
      expect(notifications, greaterThan(0));
    });
  });
}
