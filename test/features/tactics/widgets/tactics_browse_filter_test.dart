import 'package:chess_auto_prep/features/tactics/models/tactics_position.dart';
import 'package:chess_auto_prep/features/tactics/widgets/tactics_browse_filter.dart';
import 'package:flutter_test/flutter_test.dart';

TacticsPosition _pos({
  String fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1',
  String type = '??',
  int rating = 0,
  int reviewCount = 0,
  int successCount = 0,
  List<String> tags = const [],
  String white = 'alice',
  String black = 'bob',
  String date = '2026.01.01',
  String userMove = 'h5',
}) => TacticsPosition(
  fen: fen,
  userMove: userMove,
  correctLine: const ['e4'],
  mistakeType: type,
  mistakeAnalysis: '',
  gameWhite: white,
  gameBlack: black,
  gameResult: '1-0',
  gameDate: date,
  gameId: 'g1',
  rating: rating,
  reviewCount: reviewCount,
  successCount: successCount,
  flawTags: tags,
);

void main() {
  const unfiltered = TacticsBrowseFilter();

  group('accepts', () {
    test('mistake types are opt-out', () {
      expect(unfiltered.accepts(_pos(type: '??')), isTrue);
      expect(unfiltered.toggleType('??').accepts(_pos(type: '??')), isFalse);
      expect(unfiltered.toggleType('??').accepts(_pos(type: '?')), isTrue);
    });

    test('toggling a type twice returns to showing it', () {
      final off = unfiltered.toggleType('?!');
      expect(off.toggleType('?!').types, unfiltered.types);
    });

    test('minRating 0 keeps unrated puzzles', () {
      expect(unfiltered.accepts(_pos(rating: 0)), isTrue);
      final threePlus = unfiltered.copyWith(minRating: 3);
      expect(threePlus.accepts(_pos(rating: 0)), isFalse);
      expect(threePlus.accepts(_pos(rating: 3)), isTrue);
    });

    test('tags narrow with AND', () {
      final f = unfiltered.toggleTag('endgame').toggleTag('low-clock');
      expect(f.accepts(_pos(tags: const ['endgame'])), isFalse);
      expect(
        f.accepts(_pos(tags: const ['endgame', 'low-clock', 'miss'])),
        isTrue,
      );
    });

    test('an empty tag clears the whole tag filter', () {
      final f = unfiltered.toggleTag('endgame').toggleTag('');
      expect(f.tags, isEmpty);
      expect(f.accepts(_pos()), isTrue);
    });

    test('status: new means never reviewed, struggling means below half', () {
      final newOnly = unfiltered.copyWith(status: TacticsStatusFilter.newOnly);
      expect(newOnly.accepts(_pos(reviewCount: 0)), isTrue);
      expect(newOnly.accepts(_pos(reviewCount: 1)), isFalse);

      final struggling = unfiltered.copyWith(
        status: TacticsStatusFilter.struggling,
      );
      // Never attempted is not "struggling" — it is untried.
      expect(struggling.accepts(_pos(reviewCount: 0)), isFalse);
      expect(
        struggling.accepts(_pos(reviewCount: 4, successCount: 1)),
        isTrue,
        reason: '25% success',
      );
      expect(
        struggling.accepts(_pos(reviewCount: 4, successCount: 2)),
        isFalse,
        reason: 'exactly half is not struggling',
      );
    });

    test('search matches players, date and the move played', () {
      expect(unfiltered.copyWith(search: 'alice').accepts(_pos()), isTrue);
      expect(unfiltered.copyWith(search: 'bob').accepts(_pos()), isTrue);
      expect(unfiltered.copyWith(search: '2026.01').accepts(_pos()), isTrue);
      expect(unfiltered.copyWith(search: 'h5').accepts(_pos()), isTrue);
      expect(unfiltered.copyWith(search: 'carol').accepts(_pos()), isFalse);
    });
  });

  group('apply', () {
    // Positions are stored oldest-first, so display order is a property of
    // the sort, not of the file.
    final positions = [
      _pos(userMove: 'Ra1', reviewCount: 3, successCount: 3), // 100%
      _pos(userMove: 'Rb1', reviewCount: 1, successCount: 0), // 0%
      _pos(userMove: 'Rc1', reviewCount: 9, successCount: 5), // 55%
    ];

    test('newest first reverses file order; oldest first keeps it', () {
      expect(unfiltered.apply(positions), [2, 1, 0]);
      expect(
        unfiltered.copyWith(sort: TacticsBrowseSort.oldest).apply(positions),
        [0, 1, 2],
      );
    });

    test('worst success and least reviewed sort by their stat', () {
      expect(
        unfiltered
            .copyWith(sort: TacticsBrowseSort.worstSuccess)
            .apply(positions),
        [1, 2, 0],
      );
      expect(
        unfiltered
            .copyWith(sort: TacticsBrowseSort.leastReviewed)
            .apply(positions),
        [1, 0, 2],
      );
    });

    test('indices point back into the unfiltered list', () {
      final filtered = unfiltered
          .copyWith(search: 'Rc1', sort: TacticsBrowseSort.oldest)
          .apply(positions);
      expect(filtered, [2]);
      expect(positions[filtered.single].userMove, 'Rc1');
    });
  });
}
