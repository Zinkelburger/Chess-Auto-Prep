import 'package:chess_auto_prep/features/documents/controllers/viewer_collection_controller.dart';
import 'package:chess_auto_prep/models/pgn_filter_models.dart';
import 'package:chess_auto_prep/models/pgn_game_entry.dart';
import 'package:flutter_test/flutter_test.dart';

PgnGameEntry game(String name, {String date = '', int rating = 0}) =>
    PgnGameEntry(
      headers: {'White': name, 'Date': date},
      pgnText: '[White "$name"]\n\n*',
      studyRating: rating,
    );

void main() {
  test('adoption captures membership and publishes only fixed lists', () {
    final source = [game('A'), game('B')];
    final owner = ViewerCollectionController()..adopt(source);
    final all = owner.games;
    final visible = owner.visibleGames;
    source.clear();
    expect(owner.games.map((g) => g.headers['White']), ['A', 'B']);
    expect(() => all.clear(), throwsUnsupportedError);
    expect(() => visible[0] = game('C'), throwsUnsupportedError);
    expect(() => owner.visibleIndices.add(4), throwsUnsupportedError);
    owner.adopt([game('C')]);
    expect(all, hasLength(2));
    expect(visible, hasLength(2));
    expect(owner.games.single.headers['White'], 'C');
  });

  test(
    'filter input is captured, rejects invalid indices atomically and permits no matches',
    () {
      final owner = ViewerCollectionController()
        ..adopt([game('A'), game('B'), game('C')]);
      final indices = [2, 0];
      owner.applyFilter(indices);
      owner.select(1);
      final visible = owner.visibleGames;
      final revision = owner.viewRevision;
      indices.clear();
      expect(owner.visibleIndices, [2, 0]);
      for (final invalid in [
        [-1],
        [3],
        [1, 1],
      ]) {
        expect(() => owner.applyFilter(invalid), throwsArgumentError);
        expect(owner.visibleGames, same(visible));
        expect(owner.selectedIndex, 1);
        expect(owner.viewRevision, revision);
      }
      owner.applyFilter([]);
      expect(owner.visibleGames, isEmpty);
      expect(owner.selectedIndex, 0);
      expect(owner.select(0), isFalse);
    },
  );

  test('selection validates bounds and does not copy membership', () {
    final owner = ViewerCollectionController()..adopt([game('A'), game('B')]);
    final all = owner.games;
    final visible = owner.visibleGames;
    final indices = owner.visibleIndices;
    final revision = owner.viewRevision;
    expect(owner.select(-1), isFalse);
    expect(owner.select(2), isFalse);
    expect(owner.viewRevision, revision);
    expect(owner.select(1), isTrue);
    expect(owner.selectedIndex, 1);
    expect(owner.viewRevision, greaterThan(revision));
    expect(owner.games, same(all));
    expect(owner.visibleGames, same(visible));
    expect(owner.visibleIndices, same(indices));
    final after = owner.viewRevision;
    final request = owner.selectionRevision;
    owner.select(1);
    expect(owner.viewRevision, after);
    expect(owner.selectionRevision, greaterThan(request));
  });

  test('sorting preserves previous published order and file membership', () {
    final a = game('A', date: '2020.01.01', rating: 5);
    final b = game('B', date: '2025.01.01', rating: 1);
    final c = game('C', date: '2025.01.01', rating: 5);
    final owner = ViewerCollectionController()..adopt([a, b, c]);
    owner.applyFilter([2, 0]);
    final before = owner.visibleGames;
    owner.select(1);
    owner.sort(GameSortMode.dateDesc);
    expect(owner.visibleIndices, [2, 0]);
    expect(owner.selectedIndex, 1);
    owner.sort(GameSortMode.ratingDesc, resetSelection: true);
    expect(owner.visibleIndices, [0, 2], reason: 'Equal keys keep file order');
    expect(owner.selectedIndex, 0);
    expect(before, [c, a]);
    expect(owner.games, [a, b, c]);
    owner.sort(GameSortMode.fileOrder);
    expect(owner.visibleGames, [a, c]);
    owner.resetFilter();
    owner.sort(GameSortMode.dateDesc);
    expect(owner.visibleGames, [b, c, a]);
  });

  test('identical views retain their published lists and revision', () {
    final owner = ViewerCollectionController()..adopt([game('A'), game('B')]);
    final visible = owner.visibleGames;
    final revision = owner.viewRevision;
    owner.sort(GameSortMode.fileOrder);
    owner.applyFilter([0, 1]);
    owner.resetFilter();
    expect(owner.visibleGames, same(visible));
    expect(owner.viewRevision, revision);
    owner.sort(GameSortMode.dateDesc);
    expect(owner.visibleGames, same(visible));
    expect(
      owner.viewRevision,
      greaterThan(revision),
      reason: 'The sort preference changed',
    );
  });

  test(
    'large-collection selection shares membership without rebuilding it',
    () {
      final owner = ViewerCollectionController()
        ..adopt(List.generate(20000, (i) => game('$i')));
      final all = owner.games;
      final visible = owner.visibleGames;
      final indices = owner.visibleIndices;
      for (var i = 0; i < 20000; i += 7) {
        owner.select(i);
        expect(owner.games, same(all));
        expect(owner.visibleGames, same(visible));
        expect(owner.visibleIndices, same(indices));
      }
    },
  );

  test('membership belongs only to the adopted collection', () {
    final a = game('A');
    final b = game('B');
    final owner = ViewerCollectionController()..adopt([a, b]);
    owner.applyFilter([1]);
    expect(
      owner.containsGame(a),
      isTrue,
      reason: 'Filtering does not remove file membership',
    );
    owner.adopt([game('A')]);
    expect(
      owner.containsGame(a),
      isFalse,
      reason: 'Equal headers are not the same owned game',
    );
    expect(owner.containsGame(b), isFalse);
  });

  test('duplicate entry objects still have separate file positions', () {
    final same = game('A');
    final owner = ViewerCollectionController()..adopt([same, same, game('B')]);
    owner.applyFilter([1]);
    owner.sort(GameSortMode.fileOrder);
    expect(owner.visibleGames, hasLength(1));
    expect(owner.visibleIndices, [1]);
  });

  test(
    'navigation restores captured ordering and validates the entire view before mutation',
    () {
      final source = [game('A'), game('B'), game('C')];
      final owner = ViewerCollectionController()..adopt(source);
      owner.applyFilter([2, 1]);
      owner.select(1);
      final indices = owner.visibleIndices;
      owner.adopt([game('Other')]);
      owner.adopt(source);
      owner.restoreView(
        indices: indices,
        selectedIndex: 1,
        sortMode: GameSortMode.dateDesc,
      );
      expect(owner.visibleGames, [source[2], source[1]]);
      expect(owner.selectedIndex, 1);
      expect(owner.sortMode, GameSortMode.dateDesc);
      final current = owner.visibleGames;
      expect(
        () => owner.restoreView(
          indices: [0],
          selectedIndex: 2,
          sortMode: GameSortMode.fileOrder,
        ),
        throwsRangeError,
      );
      expect(owner.visibleGames, same(current));
      expect(owner.sortMode, GameSortMode.dateDesc);
      expect(
        () => owner.restoreView(
          indices: [],
          selectedIndex: 1,
          sortMode: GameSortMode.fileOrder,
        ),
        throwsRangeError,
      );
      owner.restoreView(
        indices: [],
        selectedIndex: 0,
        sortMode: GameSortMode.fileOrder,
      );
      expect(owner.visibleGames, isEmpty);
    },
  );
}
